;;; emacs-jieba-rs-tests.el --- Tests for emacs-jieba-rs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 springhan

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Run with "make test-el".

;;; Code:

(require 'ert)
(require 'emacs-jieba-rs)

(defmacro emacs-jieba-rs-test--with-text (text point &rest body)
  "Insert TEXT in a temp buffer and evaluate BODY with point at POINT.
POINT is a buffer position, or one of the symbols `beginning' and `end'."
  (declare (indent 2) (debug t))
  `(with-temp-buffer
     (insert ,text)
     (goto-char (pcase ,point
                  ('beginning (point-min))
                  ('end (point-max))
                  (_ ,point)))
     ,@body))

(defmacro emacs-jieba-rs-test--with-mode (&rest body)
  "Evaluate BODY with `emacs-jieba-rs-mode' enabled.
The mode is disabled again afterwards, even if BODY signals."
  (declare (indent 0) (debug t))
  `(unwind-protect
       (progn
         (emacs-jieba-rs-mode 1)
         ,@body)
     (emacs-jieba-rs-mode -1)))

(ert-deftest emacs-jieba-rs-test-cut ()
  "jieba-cut returns the jieba tokens of a string."
  (should (equal (jieba-cut "南京市长江大桥") '("南京市" "长江大桥")))
  (should (equal (jieba-cut "你好，世界！") '("你好" "，" "世界" "！")))
  (should (equal (jieba-cut "") '())))

(ert-deftest emacs-jieba-rs-test-tokenize-char-offsets ()
  "jieba-tokenize reports character offsets and word flags."
  (should (equal (jieba-tokenize "你好，world")
                 '((0 2 t) (2 3 nil) (3 8 t)))))

(ert-deftest emacs-jieba-rs-test-tokenize-matches-cut ()
  "The token slices reported by jieba-tokenize reconstruct jieba-cut."
  (let ((text "你好，world！"))
    (should (equal (mapcar (lambda (token)
                             (substring text (nth 0 token) (nth 1 token)))
                           (jieba-tokenize text))
                   (jieba-cut text)))))

(ert-deftest emacs-jieba-rs-test-forward-word-command ()
  "The jieba forward command moves to the end of the next word."
  (emacs-jieba-rs-test--with-text "南京市长江大桥" 'beginning
    (emacs-jieba-rs-forward-word)
    (should (= (point) 4))
    (emacs-jieba-rs-forward-word)
    (should (= (point) 8))
    ;; There is no word left ahead; point stays at the end of the buffer.
    (emacs-jieba-rs-forward-word)
    (should (= (point) 8))))

(ert-deftest emacs-jieba-rs-test-backward-word-command ()
  "The jieba backward command moves to the start of the previous word."
  (emacs-jieba-rs-test--with-text "南京市长江大桥" 'end
    (emacs-jieba-rs-backward-word)
    (should (= (point) 4))
    (emacs-jieba-rs-backward-word)
    (should (= (point) 1))
    (emacs-jieba-rs-backward-word)
    (should (= (point) 1))))

(ert-deftest emacs-jieba-rs-test-skips-punctuation ()
  "Motion steps over punctuation tokens."
  (emacs-jieba-rs-test--with-text "你好，世界！" 'beginning
    (emacs-jieba-rs-forward-word)
    (should (= (point) 3))
    (emacs-jieba-rs-forward-word)
    (should (= (point) 6)))
  (emacs-jieba-rs-test--with-text "你好，世界！" 'end
    (emacs-jieba-rs-backward-word)
    (should (= (point) 4))
    (emacs-jieba-rs-backward-word)
    (should (= (point) 1))))

(ert-deftest emacs-jieba-rs-test-moves-across-lines ()
  "Motion crosses empty lines to reach the next or previous word."
  (emacs-jieba-rs-test--with-text "南京市\n\n长江大桥" 'beginning
    (emacs-jieba-rs-forward-word)
    (should (= (point) 4))
    (emacs-jieba-rs-forward-word)
    (should (= (point) 10)))
  (emacs-jieba-rs-test--with-text "南京市\n\n长江大桥" 'end
    (emacs-jieba-rs-backward-word)
    (should (= (point) 6))
    (emacs-jieba-rs-backward-word)
    (should (= (point) 1))))

(ert-deftest emacs-jieba-rs-test-leading-whitespace ()
  "Backward motion over leading whitespace reaches the buffer start."
  (emacs-jieba-rs-test--with-text "   南京市" 2
    (emacs-jieba-rs-backward-word)
    (should (= (point) 1))))

(ert-deftest emacs-jieba-rs-test-prefix-arguments ()
  "Count arguments move several words at once."
  (emacs-jieba-rs-test--with-text "南京市长江大桥" 'beginning
    (emacs-jieba-rs-forward-word 2)
    (should (= (point) 8))
    (emacs-jieba-rs-backward-word 2)
    (should (= (point) 1))))

(ert-deftest emacs-jieba-rs-test-backward-kill-word-command ()
  "The jieba kill command kills exactly the words behind point."
  (emacs-jieba-rs-test--with-text "南京市长江大桥" 'end
    (emacs-jieba-rs-backward-kill-word)
    (should (equal (buffer-string) "南京市"))
    (should (= (point) 4))
    (emacs-jieba-rs-backward-kill-word 2)
    (should (equal (buffer-string) ""))
    (should (= (point) 1)))
  ;; A negative argument kills forward, like `backward-kill-word'.
  (emacs-jieba-rs-test--with-text "南京市长江大桥" 'beginning
    (emacs-jieba-rs-backward-kill-word -1)
    (should (equal (buffer-string) "长江大桥"))
    (should (= (point) 1))))

(ert-deftest emacs-jieba-rs-test-mode-is-global-and-optional ()
  "The mode is global and is off by default."
  (emacs-jieba-rs-mode -1)
  (should-not (default-value 'emacs-jieba-rs-mode))
  (emacs-jieba-rs-test--with-mode
    (should (default-value 'emacs-jieba-rs-mode))
    (with-temp-buffer
      (should emacs-jieba-rs-mode)))
  (should-not (default-value 'emacs-jieba-rs-mode)))

(ert-deftest emacs-jieba-rs-test-mode-advises-word-commands ()
  "The mode adds and removes the three advices."
  (emacs-jieba-rs-mode -1)
  (dolist (entry emacs-jieba-rs--advised-commands)
    (should-not (advice-member-p (cdr entry) (car entry))))
  (emacs-jieba-rs-test--with-mode
    (dolist (entry emacs-jieba-rs--advised-commands)
      (should (advice-member-p (cdr entry) (car entry)))))
  (dolist (entry emacs-jieba-rs--advised-commands)
    (should-not (advice-member-p (cdr entry) (car entry)))))

(ert-deftest emacs-jieba-rs-test-advice-uses-jieba-for-chinese ()
  "Advice moves and kills by jieba words in Chinese text."
  (emacs-jieba-rs-test--with-mode
    (emacs-jieba-rs-test--with-text "南京市长江大桥" 'beginning
      (forward-word)
      (should (= (point) 4))
      (forward-word)
      (should (= (point) 8)))
    (emacs-jieba-rs-test--with-text "南京市长江大桥" 'end
      (backward-word)
      (should (= (point) 4)))
    (emacs-jieba-rs-test--with-text "南京市长江大桥" 'end
      (backward-kill-word)
      (should (equal (buffer-string) "南京市")))
    ;; Prefix arguments are forwarded to the jieba commands.
    (emacs-jieba-rs-test--with-text "南京市长江大桥" 'beginning
      (forward-word 2)
      (should (= (point) 8)))))

(ert-deftest emacs-jieba-rs-test-advice-falls-back-to-original ()
  "Advice leaves non-Chinese words to the original commands."
  (emacs-jieba-rs-test--with-mode
    (emacs-jieba-rs-test--with-text "hello world" 'beginning
      (forward-word)
      (should (= (point) 6))
      (forward-word)
      (should (= (point) 12))
      (backward-word)
      (should (= (point) 7)))
    (emacs-jieba-rs-test--with-text "hello world" 'end
      (backward-kill-word)
      (should (equal (buffer-string) "hello ")))))

(ert-deftest emacs-jieba-rs-test-mode-works-through-keys ()
  "The advice is used when the commands are invoked interactively."
  (emacs-jieba-rs-test--with-mode
    (emacs-jieba-rs-test--with-text "南京市长江大桥" 'beginning
      (call-interactively #'forward-word)
      (should (= (point) 4))
      (let ((current-prefix-arg 2))
        (call-interactively #'backward-word))
      (should (= (point) 1)))
    (emacs-jieba-rs-test--with-text "南京市长江大桥" 'end
      (call-interactively #'backward-kill-word)
      (should (equal (buffer-string) "南京市")))))

(ert-deftest emacs-jieba-rs-test-advice-dispatches-per-word ()
  "Mixed text dispatches each word according to its own script."
  (emacs-jieba-rs-test--with-mode
    (emacs-jieba-rs-test--with-text "hello 你好世界" 'beginning
      ;; "hello" is ASCII: the original command moves to its end.
      (forward-word)
      (should (= (point) 6))
      ;; "你好" and "世界" are jieba words.
      (forward-word)
      (should (= (point) 9))
      (forward-word)
      (should (= (point) 11))
      (backward-word)
      (should (= (point) 9))
      (backward-word)
      (should (= (point) 7))
      (backward-word)
      (should (= (point) 1)))
    (emacs-jieba-rs-test--with-text "hello 你好" 'end
      (backward-kill-word)
      (should (equal (buffer-string) "hello "))
      (backward-kill-word)
      (should (equal (buffer-string) "")))))

(provide 'emacs-jieba-rs-tests)

;;; emacs-jieba-rs-tests.el ends here
