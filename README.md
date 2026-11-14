# Jieba-rs.el

在 Emacs 中使用 [jieba-rs](https://github.com/messense/jieba-rs) 对中文文本进行分词，并据此实现「按词」移动与删除。

Rust 端通过 `emacs-module` 生态的 [`emacs`](https://crates.io/crates/emacs) crate 编译成动态模块，为 Emacs 提供分词接口；Emacs 端在分词结果之上实现 `forward-word` 等命令的替代版本，并提供一个全局 minor mode。该 mode 通过 advice 增强 Emacs 原有的命令：目标词是中文时按 jieba 分词处理，否则交还给原版命令。

## 功能

- `emacs-jieba-rs-mode`（全局 minor mode）：开启后，`forward-word`、`backward-word`、`backward-kill-word` 被 advice 增强。目标词是中文时按 jieba 的分词结果移动光标或删除文本；目标词不是中文时调用原版命令，行为与未开启时一致。
- 分词接口：
  - `(jieba-cut STRING)`：返回分词结果（字符串列表）。
  - `(jieba-tokenize STRING)`：返回 `(START END WORD-P)` 列表，`START` / `END` 是从 0 开始的字符偏移，`WORD-P` 表示该 token 是否为「词」（标点、空白为 nil）。

## 环境要求

- Emacs 27.1 或更新版本，且构建时启用了动态模块支持（主流发行版的 Emacs 默认启用）。
- Rust 工具链（含 cargo），建议 Rust 1.87 或更新版本。

## 构建

```sh
make
```

该命令会执行 `cargo build --release`，并把生成的动态库复制为包目录下的 `jieba-bridge.so`（macOS 上为 `jieba-bridge.dylib`，由 Emacs 的 `module-file-suffix` 决定）。Emacs 默认就从包目录加载它。

## 使用

```elisp
(add-to-list 'load-path "/path/to/emacs-jieba-rs")
(require 'emacs-jieba-rs)
(emacs-jieba-rs-mode 1)
```

该模式是全局的，开启一次即可。开启后，默认按键的效果为：

| 按键 | 原先的命令 | 中文目标词时的行为 |
| --- | --- | --- |
| `M-f` | `forward-word` | 移动到下一个 jieba 词的末尾 |
| `M-b` | `backward-word` | 移动到上一个 jieba 词的开头 |
| `M-DEL` | `backward-kill-word` | 向后删除一个 jieba 词 |

若目标词不含中文（如 `hello`、`abc-def`），则调用原版函数，保持 Emacs 的默认行为。因此在 `hello 你好世界` 这样的混合文本中，第一次 `M-f` 走到 `hello` 末尾，随后两次分别走到 `你好`、`世界` 的末尾。命令支持数字前缀参数（如 `M-3 M-f`），也支持反向参数（如 `M-- M-f`）。由于增强的是命令本身，自定义绑定、`M-x` 以及 Lisp 调用这些命令时同样生效。

注意：动态模块在 `require` 时加载，所以请先构建；若找不到模块，会收到包含模块路径和构建提示的错误。

## 自定义

- `emacs-jieba-rs-module-path`：动态模块的文件路径，默认是包目录下的 `jieba-bridge<module-file-suffix>`。

## 分词示例

```elisp
(jieba-cut "南京市长江大桥")
;; => ("南京市" "长江大桥")

(jieba-tokenize "你好，世界！")
;; => ((0 2 t) (2 3 nil) (3 5 t) (5 6 nil))
```

## 开发

```sh
make test      # Rust 单元测试 + ERT 测试
make compile   # 字节编译 emacs-jieba-rs.el
make clean
```

单独运行时：

```sh
cargo test
emacs -Q --batch -L . -l test/emacs-jieba-rs-tests.el -f ert-run-tests-batch-and-exit
```

## 实现说明

分词以当前行为单位进行，因为 jieba 需要上下文才能正确切分；光标移动会跳过标点与空白，连续的空行会被跳过。mode 开启时，`forward-word` 等命令通过 advice 分发：目标词含汉字才使用 jieba 分词，否则调用原版命令，因此 ASCII 复合词（如 `abc-def`）仍按 Emacs 的语法表处理。

更详细的设计见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## 许可证

GPL-3.0-or-later，见 [LICENSE](LICENSE)。
