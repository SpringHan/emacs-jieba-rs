# Architecture

## Overview

The package is split into two layers with a narrow interface between them:

1. **Rust bridge** (`src/lib.rs`, crate `jieba-bridge`): a `cdylib` loaded by
   Emacs as the dynamic module `jieba-bridge`. It owns the jieba-rs engine and
   exposes pure string-to-token functions. It knows nothing about buffers,
   point, or markers.
2. **Emacs Lisp package** (`emacs-jieba-rs.el`): loads the module, turns buffer
   text into tokens, implements word motion and killing on top of them, and
   provides the buffer-local `emacs-jieba-rs-mode`.

Keeping the Rust side free of buffer logic makes the bridge small and lets the
motion code be tested against real buffers with ERT.

```
+---------------------+        jieba-cut / jieba-tokenize        +------------------+
|  emacs-jieba-rs.el  |  -------------------------------------->  |  jieba-bridge.so |
|  motion / mode      |  <--------------------------------------  |  jieba-rs engine |
+---------------------+        lists of strings / (START END P)  +------------------+
```

## File layout

| Path | Role |
| --- | --- |
| `src/lib.rs` | Rust dynamic module: module metadata, lazy `Jieba` engine, `jieba-cut`, `jieba-tokenize`, unit tests. |
| `emacs-jieba-rs.el` | Emacs package: module loading, token-to-position conversion, motion commands, `emacs-jieba-rs-mode`. |
| `test/emacs-jieba-rs-tests.el` | ERT tests for segmentation, motion, killing and the minor mode. |
| `Makefile` | Builds/copies the module, runs Rust and ERT tests, byte-compiles the package. |
| `Cargo.toml` | Declares the `cdylib`, depends on `emacs` (the high-level bindings of the `emacs-module` project) and `jieba-rs`. |
| `docs/ARCHITECTURE.md` | This document. |
| `README.md` | Chinese user documentation. |

## Rust bridge

### Module metadata

```rust
#[emacs::module(name = "jieba-bridge", defun_prefix = "jieba")]
fn init(_: &Env) -> Result<()> { Ok(()) }
```

- `name = "jieba-bridge"` is the feature the module `provide`s, so the Lisp side
  can test `(featurep 'jieba-bridge)`.
- `defun_prefix = "jieba"` names the exported functions `jieba-cut` and
  `jieba-tokenize` instead of using the crate name as a prefix.
- `emacs::plugin_is_GPL_compatible!()` exports the symbol Emacs checks before
  loading a module with a GPL-incompatible license.

The crate is built as `cdylib`, producing `libjieba_bridge.so` on GNU/Linux
(`libjieba_bridge.dylib` on macOS). `make` copies it to
`jieba-bridge<module-file-suffix>` in the package root, which is where the Lisp
side looks for it.

### Engine lifetime

Constructing `Jieba` loads and compresses the embedded dictionary, which costs
noticeably more than a single call. The engine is therefore kept in a
`OnceLock<Jieba>` and built on the first segmentation request:

```rust
fn engine() -> &'static Jieba {
    static ENGINE: OnceLock<Jieba> = OnceLock::new();
    ENGINE.get_or_init(Jieba::new)
}
```

Loading the module itself stays cheap, so requiring the Emacs package at
startup does not pay the dictionary cost until the first word motion.

### Exported functions

| Function | Argument | Result |
| --- | --- | --- |
| `jieba-cut` | `TEXT` (string) | List of token strings, in order. |
| `jieba-tokenize` | `TEXT` (string) | List of `(START END WORD-P)`. |

`START` and `END` are **zero-based character offsets** into `TEXT`, not byte
offsets, because Emacs positions count characters. jieba-rs reports character
offsets on its tokens, so no conversion is needed.

`WORD-P` is non-nil when a token contains at least one alphanumeric character
(`char::is_alphanumeric`, which also covers CJK ideographs). Whitespace and
punctuation tokens are reported too, with `WORD-P` nil, so the Lisp side can
step over them instead of stopping on them.

Lists are built right-to-left with `Env::cons`, because the binding has no
`IntoLisp` implementation for `Vec<T>`; reversing the token vector first keeps
the Lisp list in the original order.

### Tests

`cargo test` covers the Rust half without a running Emacs: known segmentations,
word/punctuation classification, and the invariant that
`jieba-tokenize` offsets are contiguous and cover the whole input.

## Emacs side

### Loading the module

- `emacs-jieba-rs--directory` is derived from `load-file-name` (falling back to
  `buffer-file-name`).
- `emacs-jieba-rs-module-path` defaults to `jieba-bridge` plus
  `module-file-suffix` in that directory, and can be customized.
- `emacs-jieba-rs--load-module` is idempotent (`featurep`) and raises a clear
  error pointing at `make` when the module file is missing.
- The module is loaded at package load time so that `jieba-cut` and
  `jieba-tokenize` are available as soon as `(require 'emacs-jieba-rs)`
  returns. This is safe because the dictionary is still lazy inside Rust.

### Building the token list of a line

`emacs-jieba-rs--line-tokens` takes the current line with
`buffer-substring-no-properties`, calls `jieba-tokenize`, and adds
`line-beginning-position` to the relative offsets to obtain absolute buffer
positions.

The whole line is tokenized, not "the text right after point", because jieba
uses preceding context to decide where a word starts. Starting the
segmentation in the middle of a word would produce different, wrong tokens.
Line granularity also guarantees that the token list does not depend on where
point happens to be, which makes words stable while moving through a line.

### Word motion

`emacs-jieba-rs--forward` and `emacs-jieba-rs--backward` share one skeleton:

1. Run the search inside `save-excursion` and a `catch`.
2. Scan the tokens of the current line for a word token past (forward) or
   before (backward) point.
3. If there is none, move to the next/previous line and repeat.
4. Return the target position from the excursion; `goto-char` is applied
   outside it.

Step 4 matters: a `throw` out of `save-excursion` runs its unwind-protect
cleanup, which restores point. A `goto-char` performed inside the excursion and
then thrown past would be silently undone, so the throw only returns a
position.

Selection rules:

- Forward takes the first word token whose `END` is greater than point.
- Backward walks the line tokens in reverse and takes the last word token whose
  `START` is less than point.

Both rules make point inside a word go to that word's boundary, and point on a
boundary go to the neighbouring word, matching `forward-word` /
`backward-word`. Tokens with `WORD-P` nil are skipped, so punctuation and
whitespace are stepped over. When no word remains, forward goes to `point-max`
and backward to `point-min`, again matching the standard commands.

Line traversal:

- Forward uses `forward-line 1`, which always advances and terminates at
  `eobp`.
- Backward jumps to `(1- (line-beginning-position))`, the newline that
  terminates the previous line, clamped to `point-min`. Using the newline
  position instead of `forward-line -1` is what avoids re-scanning the line
  point started on when point sits in the middle of it.

`emacs-jieba-rs-forward-word` / `-backward-word` apply these single steps `ARG`
times (`dotimes`), and delegate to the opposite command for a negative prefix
argument.

### Killing

`emacs-jieba-rs-backward-kill-word` computes the target position with the same
motion inside `save-excursion`, then calls `kill-region` on the resulting
range. A negative argument moves forward first and kills forward, mirroring
`backward-kill-word`. `interactive "*p"` matches the standard command, so a
read-only buffer is rejected before anything is killed.

### Minor mode

`emacs-jieba-rs-mode-map` uses key remapping:

```elisp
(define-key map [remap forward-word] #'emacs-jieba-rs-forward-word)
(define-key map [remap backward-word] #'emacs-jieba-rs-backward-word)
(define-key map [remap backward-kill-word] #'emacs-jieba-rs-backward-kill-word)
```

Remapping redirects whatever key is bound to the standard command (M-f, M-b and
M-DEL by default, but also user bindings) without hard-coding any key.
`emacs-jieba-rs-mode` is buffer-local and only installs the keymap while
enabled, so the standard commands are restored when it is turned off.

## Data flow

```
buffer text (current line)
        |
        v  buffer-substring-no-properties
   jieba-tokenize  --->  ((START END WORD-P) ...)
        |
        v  + line-beginning-position
absolute (START END WORD-P) positions
        |
        v  scan for a word token past/before point
   goto-char  --->  point moves by one jieba word
```

## Build and test

```sh
make          # cargo build --release, then copy the module to the package root
make test     # cargo test + ERT suite
make compile  # byte-compile emacs-jieba-rs.el
make clean
```

`MODULE_SUFFIX` is obtained from Emacs at build time
(`module-file-suffix`), so the copied file has the platform's expected
extension.

## Design notes and limitations

- **Line-based context.** Segmentation sees the current line only. This bounds
  the cost of each keypress and keeps words stable, at the price of ignoring
  context across newlines.
- **ASCII compounds.** The mode follows jieba's tokens, so ASCII compounds such
  as `abc-def` count as one word even though the default Emacs syntax table
  would split them at the hyphen.
- **No custom dictionary yet.** The embedded jieba dictionary is used as-is;
  there is no user dictionary or per-buffer configuration.
- **Character offsets.** Positions assume one Unicode scalar value is one
  Emacs character, which holds for normal multibyte text. Raw-byte buffers are
  not handled specially.
- **No prebuilt binaries.** The dynamic module must be built for the running
  platform and Emacs ABI.
