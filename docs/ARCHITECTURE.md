# Architecture

## Overview

The package has two layers, and the dependency runs in one direction: the Emacs
Lisp layer depends on the Rust module, never the other way around.

- **Rust bridge** (`src/lib.rs`, crate `jieba-bridge`): a `cdylib` that Emacs
  loads as the dynamic module `jieba-bridge`. It owns the jieba-rs engine and
  exposes two pure functions that turn a string into tokens. It never reads or
  writes buffers, point, markers, or window state.
- **Emacs Lisp package** (`emacs-jieba-rs.el`): loads the module, converts
  buffer text into tokens, implements word motion and killing, and provides the
  global `emacs-jieba-rs-mode`, which advises the standard word commands.

The split exists for two reasons. The Rust layer stays small enough to reason
about because it has no Emacs state to manage, so it can be unit tested with
`cargo test` alone. All editing logic stays in Lisp, where point handling is
natural and the behavior can be tested against real buffers with ERT.

## Module boundary

The contract between the two layers is two function calls, both taking a string
and returning plain data:

- `(jieba-cut TEXT)` returns the token strings, in order.
- `(jieba-tokenize TEXT)` returns a list of `(START END WORD-P)` triples, where
  `START` and `END` are character offsets into `TEXT`.

At load time the module also `provide`s the feature `jieba-bridge`; that is the
only other thing the Lisp side observes. The Lisp layer never passes a buffer,
point, or marker to Rust, and Rust never invokes an Emacs command or touches a
buffer. The module's interface is therefore pure, and every piece of editing
behavior lives on the Lisp side.

## File layout

| Path | Role |
| --- | --- |
| `src/lib.rs` | Rust dynamic module: module metadata, lazy `Jieba` engine, `jieba-cut`, `jieba-tokenize`, unit tests. |
| `emacs-jieba-rs.el` | Emacs package: module loading, token-to-position conversion, motion commands, advice dispatch and `emacs-jieba-rs-mode`. |
| `test/emacs-jieba-rs-tests.el` | ERT tests for segmentation, motion, killing, advice dispatch and the minor mode. |
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

`START` and `END` are zero-based character offsets into `TEXT`, not byte
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
word/punctuation classification, and the invariant that `jieba-tokenize`
offsets are contiguous and cover the whole input.

## Emacs side

The Lisp side owns everything buffer-related. It loads the module once, converts
each line into tokens, moves or kills by those tokens, and decides whether to
take over a standard command. The subsections below follow that order; the
function map at the end of the section lists every Lisp symbol with its role.

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

`emacs-jieba-rs-forward-word` and `emacs-jieba-rs-backward-word` apply these
single steps `ARG` times (`dotimes`), and delegate to the opposite command for a
negative prefix argument.

### Killing

`emacs-jieba-rs-backward-kill-word` computes the target position with the same
motion inside `save-excursion`, then calls `kill-region` on the resulting
range. A negative argument moves forward first and kills forward, mirroring
`backward-kill-word`. `interactive "*p"` matches the standard command, so a
read-only buffer is rejected before anything is killed.

### Minor mode and advice

`emacs-jieba-rs-mode` is a global minor mode (`:global t`). It does not bind
keys; it changes the behavior of the standard word commands themselves.
Turning the mode on adds one `:around` advice to each command, and turning it
off removes the same advice:

```elisp
:global t
(dolist (entry emacs-jieba-rs--advised-commands)
  (if emacs-jieba-rs-mode
      (advice-add (car entry) :around (cdr entry))
    (advice-remove (car entry) (cdr entry))))
```

`emacs-jieba-rs--advised-commands` pairs `forward-word`, `backward-word` and
`backward-kill-word` with their advice functions. Advising the commands instead
of remapping keys means every caller is covered while the mode is on: the
standard keys, user key bindings, `M-x`, and Lisp code.

Each advice dispatches per invocation:

1. `emacs-jieba-rs--chinese-word-p` picks the direction the command would
   travel from the sign of its ARG (a negative `forward-word` moves backward, a
   negative `backward-kill-word` kills forward).
2. It runs the jieba motion in a `save-excursion` and matches the traversed
   region against `emacs-jieba-rs--han-regexp`. Because the punctuation and
   whitespace tokens the motion skips never contain Han characters, matching
   the region is equivalent to matching the target word itself.
3. If the target word is Chinese, the advice calls the corresponding
   `emacs-jieba-rs-*` command with the original ARGS. Otherwise it calls the
   original command (`orig`), so non-Chinese text keeps standard Emacs
   behavior.

Han detection uses an explicit range regexp (including the CJK extensions)
rather than the `\cc` category, because that category also matches CJK
punctuation and full-width Latin letters.

Delegating to the original command has one subtlety: `backward-kill-word` is a
C subr whose argument is required, so `(apply orig args)` fails when the
command is called with no argument. The advices therefore pass `(list 1)` when
ARGS is empty, matching the commands' default of one word.

Enabling the mode again re-adds the same named advice functions, which
`advice-add` treats as idempotent, and removing advice that is not present is
harmless. Toggling is therefore safe.

### Function map

The Lisp symbols involved, in the order a reader usually needs them:

| Symbol | Kind | Role |
| --- | --- | --- |
| `emacs-jieba-rs-module-path` | defcustom | File name of the dynamic module. |
| `emacs-jieba-rs--directory` | constant | Directory the package was loaded from. |
| `emacs-jieba-rs--load-module` | function | Idempotently load the dynamic module. |
| `emacs-jieba-rs-mode` | global minor mode | Add or remove the three advices. |
| `emacs-jieba-rs--advised-commands` | constant (alist) | Maps each advised command to its advice function. |
| `emacs-jieba-rs--forward-word-advice` | function | Dispatch `forward-word`. |
| `emacs-jieba-rs--backward-word-advice` | function | Dispatch `backward-word`. |
| `emacs-jieba-rs--backward-kill-word-advice` | function | Dispatch `backward-kill-word`. |
| `emacs-jieba-rs--chinese-word-p` | function | Decide whether the target word contains Han text. |
| `emacs-jieba-rs--han-regexp` | constant | Han character ranges used by the predicate. |
| `emacs-jieba-rs--line-tokens` | function | Tokens of the current line in absolute buffer positions. |
| `emacs-jieba-rs--forward`, `emacs-jieba-rs--backward` | functions | Single jieba-word motion steps. |
| `emacs-jieba-rs-forward-word`, `emacs-jieba-rs-backward-word` | commands | Apply `ARG` single steps; also usable directly. |
| `emacs-jieba-rs-backward-kill-word` | command | Kill `ARG` jieba words; also usable directly. |

## End-to-end walkthrough

This section follows one interactive command, `M-f` in a buffer containing
Chinese text, from key press to final point position.

1. `M-f` is still bound to `forward-word`; the mode does not change key
   bindings. Because `emacs-jieba-rs-mode` is enabled, the advised
   `forward-word` runs its `:around` advice first.
2. The advice asks `emacs-jieba-rs--chinese-word-p` which word `forward-word`
   would traverse. The predicate runs `emacs-jieba-rs--forward` inside
   `save-excursion`, so point is restored afterwards, and tests the traversed
   text against `emacs-jieba-rs--han-regexp`.
3. If the traversed text contains a Han character, the advice calls
   `emacs-jieba-rs-forward-word` with the original argument. Otherwise it calls
   the original `forward-word`, and no jieba code runs.
4. `emacs-jieba-rs-forward-word` moves one word at a time. Each single-word
   step asks `emacs-jieba-rs--line-tokens` for the current line: the line
   string is passed to `jieba-tokenize`, and `line-beginning-position` is
   added to each returned offset, turning character offsets into absolute
   buffer positions.
5. The step selects the first word token whose `END` is greater than point and
   returns that `END`. If the line has no such token, the step moves to the
   next line and repeats; if the buffer has no word left, it returns
   `point-max`.
6. `emacs-jieba-rs-forward-word` applies the step once per word and finally
   calls `goto-char`.

`backward-word` and `backward-kill-word` follow the same path in the opposite
direction. The kill command differs only at the last step: instead of moving
point, it turns the selected boundary into a region and calls `kill-region`.

## Build and test

```sh
make          # cargo build --release, then copy the module to the package root
make test     # cargo test + ERT suite
make compile  # byte-compile emacs-jieba-rs.el
make clean
```

`MODULE_SUFFIX` is obtained from Emacs at build time (`module-file-suffix`), so
the copied file has the platform's expected extension.

## Design notes and limitations

- **Line-based context.** Segmentation sees the current line only. This bounds
  the cost of each keypress and keeps words stable, at the price of ignoring
  context across newlines.
- **Non-Chinese words stay standard.** A word without Han characters is left to
  the original command, so `abc-def` keeps the standard Emacs behavior of splitting
  at the hyphen. Only tokens that contain Han are segmented by jieba.
- **Dispatch per command call.** With a prefix ARG, the decision is made from
  the first word; all ARG words of that call then use the same command.
  Repeating single steps (the usual M-f/M-DEL flow) dispatches independently
  for each word.
- **No custom dictionary yet.** The embedded jieba dictionary is used as-is;
  there is no user dictionary or per-buffer configuration.
- **Character offsets.** Positions assume one Unicode scalar value is one
  Emacs character, which holds for normal multibyte text. Raw-byte buffers are
  not handled specially.
- **No prebuilt binaries.** The dynamic module must be built for the running
  platform and Emacs ABI.
