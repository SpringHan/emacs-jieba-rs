# 项目背景

**以下内容为最初的实现需求。**

### Rust 端

给 Emacs 端提供 jieba-rs 的给中文进行分词的接口。

### Emacs 端

1. 通过 Rust 提供的 module 和函数，为中文文本实现 Emacs 中的 `backward-word`, `forward-word`, `backword-kill-word` 函数。
2. 新建一个 minor mode。将该 mode 开启时将新增的函数映射到原本的 `backward-word` 等函数上。
