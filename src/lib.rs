//! Dynamic module that exposes [jieba-rs] word segmentation to Emacs.
//!
//! [jieba-rs]: https://github.com/messense/jieba-rs
//!
//! The module deliberately contains no buffer logic: it turns a string into
//! tokens, and the Emacs Lisp side decides what to do with them. This keeps
//! the bridge small and lets the Lisp code be tested without a live buffer
//! position.

use std::sync::OnceLock;

use emacs::{Env, IntoLisp, Result, Value, defun};
use jieba_rs::Jieba;

emacs::plugin_is_GPL_compatible!();

#[emacs::module(name = "jieba-bridge", defun_prefix = "jieba")]
fn init(_: &Env) -> Result<()> {
    Ok(())
}

/// The segmentation engine.
///
/// Loading the dictionary is the expensive part of jieba, so the engine is
/// built once, on the first call, and shared by all later calls.
fn engine() -> &'static Jieba {
    static ENGINE: OnceLock<Jieba> = OnceLock::new();
    ENGINE.get_or_init(Jieba::new)
}

/// Whether a token should be treated as a word during cursor motion.
///
/// Punctuation and whitespace are tokens too, but Emacs word motion steps
/// over them; they are reported separately so the Lisp side can skip them.
fn is_word(word: &str) -> bool {
    word.chars().any(|ch| ch.is_alphanumeric())
}

/// Segment TEXT and return the words as a list of strings.
#[defun]
fn cut<'e>(env: &'e Env, text: String) -> Result<Value<'e>> {
    let mut list = env.intern("nil")?;
    for token in engine().cut(&text, true).iter().rev() {
        list = env.cons(token.word, list)?;
    }
    Ok(list)
}

/// Segment TEXT and return tokens as a list of (START END WORD-P).
///
/// START and END are zero-based character offsets into TEXT, as counted by
/// Emacs, and WORD-P is non-nil when the token is a word rather than
/// punctuation or whitespace. Character offsets (instead of byte offsets)
/// keep the Lisp side free of any encoding arithmetic.
#[defun]
fn tokenize<'e>(env: &'e Env, text: String) -> Result<Value<'e>> {
    let mut list = env.intern("nil")?;
    for token in engine().cut(&text, true).iter().rev() {
        let item = env.list([
            (token.start as i64).into_lisp(env)?,
            (token.end as i64).into_lisp(env)?,
            is_word(token.word).into_lisp(env)?,
        ])?;
        list = env.cons(item, list)?;
    }
    Ok(list)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Segment TEXT into words, dropping the punctuation tokens.
    fn words(text: &str) -> Vec<&str> {
        engine()
            .cut(text, true)
            .into_iter()
            .map(|token| token.word)
            .filter(|word| is_word(word))
            .collect()
    }

    #[test]
    fn segments_chinese_text() {
        assert_eq!(words("南京市长江大桥"), vec!["南京市", "长江大桥"]);
    }

    #[test]
    fn distinguishes_words_from_punctuation() {
        assert!(is_word("北京"));
        assert!(is_word("hello"));
        assert!(!is_word("，"));
        assert!(!is_word(" "));
        assert!(!is_word("！"));
    }

    #[test]
    fn char_offsets_cover_the_input() {
        let text = "你好，world！";
        let tokens = engine().cut(text, true);
        let mut cursor = 0;
        for token in &tokens {
            assert_eq!(token.start, cursor);
            cursor = token.end;
        }
        assert_eq!(cursor, text.chars().count());
    }
}
