# Jieba-rs.el

在 Emacs 中使用 [jieba-rs](https://github.com/messense/jieba-rs) 对中文文本进行分词，并据此实现「按词」移动与删除。

Rust 端通过 `emacs-module` 生态的 [`emacs`](https://crates.io/crates/emacs) crate 编译成动态模块，为 Emacs 提供分词接口；Emacs 端在分词结果之上实现 `forward-word` 等命令的替代版本，并提供一个 buffer-local 的 minor mode。

## 功能

- `emacs-jieba-rs-mode`：开启后，`M-f` / `M-b` / `M-DEL`（即 `forward-word`、`backward-word`、`backward-kill-word`）按 jieba 的分词结果移动光标与删除文本。
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
(add-hook 'text-mode-hook #'emacs-jieba-rs-mode)
```

开启后：

| 按键 | 原先的命令 | 现在的行为 |
| --- | --- | --- |
| `M-f` | `forward-word` | 移动到下一个 jieba 词的末尾 |
| `M-b` | `backward-word` | 移动到上一个 jieba 词的开头 |
| `M-DEL` | `backward-kill-word` | 向后删除一个 jieba 词 |

这些命令也支持数字前缀参数，例如 `M-3 M-f` 前进三个词、`M-- M-f` 反向移动。模式通过 keymap remapping 实现，因此你自定义的、绑定到上述命令的按键同样会生效。

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

分词以当前行为单位进行，因为 jieba 需要上下文才能正确切分；光标移动会跳过标点与空白，连续的空行会被跳过。由于遵循 jieba 的切分结果，ASCII 复合词（如 `abc-def`）也会被视为一个词。

更详细的设计见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## 许可证

GPL-3.0-or-later，见 [LICENSE](LICENSE)。
