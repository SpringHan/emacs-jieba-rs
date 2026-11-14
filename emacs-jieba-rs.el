;;; emacs-jieba-rs.el --- Chinese word segmentation with jieba-rs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 springhan

;; Author: springhan <springchohaku@qq.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: i18n, wp

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

;; This package uses jieba-rs, through a small dynamic module, to teach
;; Emacs that a Chinese "word" is a jieba token rather than a run of
;; characters.  Enabling the global `emacs-jieba-rs-mode' advises
;; `forward-word', `backward-word' and `backward-kill-word', so the
;; usual M-f, M-b and M-DEL keys move and kill by word.  Words that are
;; not Chinese are left to the original commands.
;;
;;     (require 'emacs-jieba-rs)
;;     (emacs-jieba-rs-mode 1)
;;
;; The dynamic module has to be built first; see the README.

;;; Code:

(declare-function jieba-cut "jieba-bridge" (text))
(declare-function jieba-tokenize "jieba-bridge" (text))

(defgroup emacs-jieba-rs nil
  "Chinese word segmentation powered by jieba-rs."
  :group 'i18n
  :prefix "emacs-jieba-rs-")

(defconst emacs-jieba-rs--directory
  (file-name-directory
   (or load-file-name buffer-file-name
       (expand-file-name "emacs-jieba-rs.el")))
  "Directory containing this package.")

(defcustom emacs-jieba-rs-module-path
  (expand-file-name (concat "jieba-bridge" module-file-suffix)
                    emacs-jieba-rs--directory)
  "File name of the jieba-bridge dynamic module.
The module is produced by running \"make\" in the package directory."
  :type 'file
  :group 'emacs-jieba-rs)

(defconst emacs-jieba-rs--han-regexp
  "[\u3007\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF\U00020000-\U0002FA1F]"
  "Regexp matching a Han character.
CJK punctuation, kana, Hangul and other scripts are not matched, so a
token is treated as Chinese only when it really contains Han text.")

(defun emacs-jieba-rs--load-module ()
  "Load the jieba-bridge dynamic module, unless it is already loaded."
  (unless (featurep 'jieba-bridge)
    (unless (file-exists-p emacs-jieba-rs-module-path)
      (error "Jieba dynamic module not found: %s; run \"make\" to build it"
             emacs-jieba-rs-module-path))
    (module-load emacs-jieba-rs-module-path)))

(defun emacs-jieba-rs--line-tokens ()
  "Return the tokens of the current line as (START END WORD-P) lists.
START and END are buffer positions and WORD-P is non-nil for words,
as opposed to whitespace and punctuation.

Tokenizing a whole line, instead of the text right after point, keeps
the segmentation consistent: jieba needs the preceding characters to
decide where a word starts."
  (let ((beg (line-beginning-position)))
    (mapcar (lambda (token)
              (list (+ beg (nth 0 token))
                    (+ beg (nth 1 token))
                    (nth 2 token)))
            (jieba-tokenize (buffer-substring-no-properties
                             beg (line-end-position))))))

(defun emacs-jieba-rs--forward ()
  "Move point to the end of the next jieba word.
Whitespace and punctuation are skipped, following `forward-word'.
The search runs inside `save-excursion' and only reports the target
position, because a `throw' would trigger the excursion cleanup and
restore point."
  (goto-char
   (or (save-excursion
         (catch 'found
           (while (not (eobp))
             (dolist (token (emacs-jieba-rs--line-tokens))
               (when (and (nth 2 token) (> (nth 1 token) (point)))
                 (throw 'found (nth 1 token))))
             (forward-line 1))))
       ;; No word is left ahead; go to the end of the accessible buffer, as
       ;; `forward-word' does.
       (point-max))))

(defun emacs-jieba-rs--backward ()
  "Move point to the start of the previous jieba word.
Whitespace and punctuation are skipped, following `backward-word'."
  (goto-char
   (or (save-excursion
         (catch 'found
           (while (not (bobp))
             (dolist (token (reverse (emacs-jieba-rs--line-tokens)))
               (when (and (nth 2 token) (< (nth 0 token) (point)))
                 (throw 'found (nth 0 token))))
             ;; This line has no word before point; continue at the end of
             ;; the previous line.  Going to the newline position, instead
             ;; of `forward-line -1', never re-scans the line point
             ;; started on.
             (goto-char (max (point-min)
                             (1- (line-beginning-position)))))))
       ;; No word is left behind; go to the start of the accessible
       ;; buffer, as `backward-word' does.
       (point-min))))

(defun emacs-jieba-rs-forward-word (&optional arg)
  "Move point forward to the end of the next ARG jieba words.
This is a drop-in replacement for `forward-word' that treats Chinese
words as segmented by jieba.  A negative ARG moves backward."
  (interactive "^p")
  (let ((count (or arg 1)))
    (if (< count 0)
        (emacs-jieba-rs-backward-word (- count))
      (dotimes (_ count)
        (emacs-jieba-rs--forward)))))

(defun emacs-jieba-rs-backward-word (&optional arg)
  "Move point backward to the start of the previous ARG jieba words.
This is a drop-in replacement for `backward-word' that treats Chinese
words as segmented by jieba.  A negative ARG moves forward."
  (interactive "^p")
  (let ((count (or arg 1)))
    (if (< count 0)
        (emacs-jieba-rs-forward-word (- count))
      (dotimes (_ count)
        (emacs-jieba-rs--backward)))))

(defun emacs-jieba-rs-backward-kill-word (&optional arg)
  "Kill characters backward until the start of the ARG-th jieba word.
This is a drop-in replacement for `backward-kill-word' that treats
Chinese words as segmented by jieba.  A negative ARG kills forward."
  (interactive "*p")
  (let ((count (or arg 1)))
    (if (< count 0)
        (let ((end (save-excursion
                     (emacs-jieba-rs-forward-word (- count))
                     (point))))
          (when (< (point) end)
            (kill-region (point) end)))
      (let ((beg (save-excursion
                   (emacs-jieba-rs-backward-word count)
                   (point))))
        (when (< beg (point))
          (kill-region beg (point)))))))

(defun emacs-jieba-rs--chinese-word-p (direction)
  "Return non-nil when the next jieba word in DIRECTION is Chinese.
DIRECTION is either `forward' or `backward'.  Point does not move.

The checked region is the text the motion command would traverse,
including the punctuation and whitespace it skips.  Those tokens
never contain Han characters, so matching the region is equivalent
to matching the target word itself."
  (let ((start (point)))
    (save-excursion
      (if (eq direction 'forward)
          (emacs-jieba-rs--forward)
        (emacs-jieba-rs--backward))
      (string-match-p emacs-jieba-rs--han-regexp
                      (buffer-substring-no-properties
                       (min start (point))
                       (max start (point)))))))

(defun emacs-jieba-rs--forward-word-advice (orig &rest args)
  "Call ORIG or the jieba command behind `forward-word'.
Use jieba when the next word in the direction of travel is Chinese,
and ORIG otherwise.  ARGS are forwarded; a missing ARG means one
word."
  (if (emacs-jieba-rs--chinese-word-p
       (if (< (or (car args) 1) 0) 'backward 'forward))
      (apply #'emacs-jieba-rs-forward-word args)
    (apply orig (or args (list 1)))))

(defun emacs-jieba-rs--backward-word-advice (orig &rest args)
  "Call ORIG or the jieba command behind `backward-word'.
Use jieba when the previous word in the direction of travel is
Chinese, and ORIG otherwise.  ARGS are forwarded; a missing ARG
means one word."
  (if (emacs-jieba-rs--chinese-word-p
       (if (< (or (car args) 1) 0) 'forward 'backward))
      (apply #'emacs-jieba-rs-backward-word args)
    (apply orig (or args (list 1)))))

(defun emacs-jieba-rs--backward-kill-word-advice (orig &rest args)
  "Call ORIG or the jieba command behind `backward-kill-word'.
Use jieba when the word about to be killed is Chinese, and ORIG
otherwise.  ARGS are forwarded; a missing ARG means one word."
  (if (emacs-jieba-rs--chinese-word-p
       (if (< (or (car args) 1) 0) 'forward 'backward))
      (apply #'emacs-jieba-rs-backward-kill-word args)
    (apply orig (or args (list 1)))))

(defconst emacs-jieba-rs--advised-commands
  '((forward-word . emacs-jieba-rs--forward-word-advice)
    (backward-word . emacs-jieba-rs--backward-word-advice)
    (backward-kill-word . emacs-jieba-rs--backward-kill-word-advice))
  "Commands advised while `emacs-jieba-rs-mode' is enabled.")

;;;###autoload
(define-minor-mode emacs-jieba-rs-mode
  "Toggle Chinese word motion based on jieba-rs.

This is a global minor mode.  While it is enabled, `forward-word',
`backward-word' and `backward-kill-word' are advised: when the word
a command would move over or kill is Chinese, jieba segmentation
decides its boundaries; otherwise the original command runs
unchanged."
  :lighter " jieba"
  :global t
  :group 'emacs-jieba-rs
  (dolist (entry emacs-jieba-rs--advised-commands)
    (if emacs-jieba-rs-mode
        (advice-add (car entry) :around (cdr entry))
      (advice-remove (car entry) (cdr entry)))))

;; Load the native module at load time: `jieba-cut' and `jieba-tokenize' are
;; part of the public interface and must be usable as soon as the package is
;; required.  The jieba dictionary itself is still loaded lazily, on the first
;; segmentation call inside the module.
(emacs-jieba-rs--load-module)

(provide 'emacs-jieba-rs)

;;; emacs-jieba-rs.el ends here
