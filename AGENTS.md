# Jieba-rs.el

## 项目介绍

该项目是一个 Emacs package，用于利用 jieba-rs 给 Emacs 提供中文文本分词的相关操作。

## 技术栈

1. 使用 Rust 作为 bridge 将 Emacs 和 `jieba-rs` crate 进行连接。
2. Rust 使用 `emacs-module` crate 作为依赖。

## 文档结构

1. `docs/ARCHITECTURE.md`: 项目架构
2. `docs/PROJECT_BRIEF.md`: 项目最初的需求，只在我要求的时候读取
3. `README.md`: 项目介绍的中文文档

## 必须遵守

1. 在修改了项目文件后，及时更新 `docs/ARCHITECTURE.md` 文档。
2. 在代码中和 `ARCHITECTURE.md` 中使用英文注释。
3. 在编写代码时，只在必要的情况下增加函数，以保证代码的可阅读性。
