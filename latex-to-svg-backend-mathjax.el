;;; latex-to-svg-backend-mathjax.el --- Local MathJax SVG engine -*- lexical-binding: t -*-

;; Copyright (C) 2026
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Optional MathJax engine.  Run npm ci in this package's checkout once,
;; then select :engine mathjax.  Rendering uses local files only.
;; Load `latex-to-svg-backend', not this file.

;;; Code:

(require 'json)
(require 'latex-to-svg-backend-core)

(defgroup latex-to-svg-backend-mathjax nil
  "Local MathJax rendering through Node.js."
  :group 'latex-to-svg-backend
  :prefix "latex-to-svg-backend-mathjax-")

(defcustom latex-to-svg-backend-mathjax-program "node"
  "Node.js executable used to run MathJax."
  :type 'string
  :group 'latex-to-svg-backend-mathjax)

(defcustom latex-to-svg-backend-mathjax-script
  (expand-file-name "mathjax-render.cjs"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Absolute path to the bundled MathJax helper.
Install its dependencies with npm ci in the helper's directory.
For a package installation that omits JavaScript files, set this to
the helper in a full checkout of this fork."
  :type 'file
  :group 'latex-to-svg-backend-mathjax)

(defcustom latex-to-svg-backend-mathjax-macros ""
  "TeX macro definitions prepended to each MathJax equation.
MathJax reads no LaTeX preamble.  Define commands here with
`\\newcommand' or `\\def'.  Changing this text changes the cache key."
  :type 'string
  :group 'latex-to-svg-backend-mathjax)

(defun latex-to-svg-backend--mathjax-tools-available-p ()
  "Return non-nil when Node.js and the MathJax helper exist.
The helper reports a missing npm dependency asynchronously."
  (and (executable-find latex-to-svg-backend-mathjax-program)
       (file-readable-p latex-to-svg-backend-mathjax-script)))

(defun latex-to-svg-backend--mathjax-inputs ()
  "Return the MathJax inputs captured in the requesting buffer."
  (list :mathjax-macros latex-to-svg-backend-mathjax-macros))

(defun latex-to-svg-backend--mathjax-cache-salt (inputs)
  "Return the MathJax cache salt for INPUTS.
The protocol version separates future changes to the helper's SVG format."
  (concat "mathjax-4.1.3-v1\0" (plist-get inputs :mathjax-macros)))

(defun latex-to-svg-backend--mathjax-formula (latex macros)
  "Return (FORMULA . INLINE) from LATEX, with MACROS prepended.
Strip only the outer math delimiters; preserve newlines and TeX comments."
  (let* ((body (string-trim latex))
         (delimiter
          (seq-find (pcase-lambda (`(,open ,close ,_))
                      (and (>= (length body) (+ (length open) (length close)))
                           (string-prefix-p open body)
                           (string-suffix-p close body)))
                    '(("$$" "$$" nil) ("\\[" "\\]" nil)
                      ("\\(" "\\)" t) ("$" "$" t)))))
    (when delimiter
      (setq body (substring body (length (car delimiter))
                            (- (length (cadr delimiter))))))
    (cons (concat macros "\n" body) (nth 2 delimiter))))

(defun latex-to-svg-backend--mathjax-formula-error (exit output)
  "Return a formula failure plist from EXIT and OUTPUT, or nil.
Only exit 2 and the helper's explicit marker denote a TeX error.
Missing npm packages, I/O errors and crashes remain retryable setup errors."
  (when (and (equal exit '(mathjax . 2))
             (string-match "^MATHJAX_FORMULA_ERROR: \\(.*\\)$" output))
    (list :message (match-string 1 output) :line nil :column nil)))

(defun latex-to-svg-backend--mathjax-store (output svg)
  "Validate MathJax's OUTPUT and move it to cache file SVG.
Return nil if the helper did not supply geometry and font metrics."
  (let ((data (with-temp-buffer
                (insert-file-contents output)
                (buffer-string))))
    (when (and (latex-to-svg-backend--svg-geometry data)
               (latex-to-svg-backend--svg-x-height data))
      (latex-to-svg-backend--move-to-cache output svg))))

(defun latex-to-svg-backend--mathjax-compile (key latex &optional inputs)
  "Asynchronously render LATEX with MathJax to the cache SVG for KEY.
INPUTS holds the captured macros, or nil for the current buffer's.
Use the shared queue, failure reporting and callback machinery."
  (pcase-let* ((`(,formula . ,inline)
                (latex-to-svg-backend--mathjax-formula
                 latex (plist-get (or inputs (latex-to-svg-backend--mathjax-inputs))
                                  :mathjax-macros)))
               (dir (latex-to-svg-backend--scratch-dir))
               (input (expand-file-name "equation.json" dir))
               (output (expand-file-name "equation.svg" dir))
               (svg (latex-to-svg-backend--svg-file key))
               (output-buffer (generate-new-buffer
                               (format " *latex-to-svg-backend-%s*" key))))
    (let ((coding-system-for-write 'utf-8-unix))
      (with-temp-file input
        (insert (json-encode `((tex . ,formula)
                               (display . ,(if inline :json-false t)))))))
    (latex-to-svg-backend--run-process-chain
     key dir output-buffer
     (list (list 'mathjax
                 (list latex-to-svg-backend-mathjax-program
                       (expand-file-name latex-to-svg-backend-mathjax-script)
                       input output)
                 output))
     (lambda (success &optional exit)
       (unwind-protect
           (if (and success
                    (condition-case err
                        (or (latex-to-svg-backend--mathjax-store output svg)
                            (progn
                              (latex-to-svg-backend--append-process-log
                               output-buffer "[mathjax] invalid SVG or missing metrics")
                              nil))
                      (file-error
                       (latex-to-svg-backend--append-process-log
                        output-buffer (error-message-string err))
                       nil)))
               (latex-to-svg-backend--notify-pending key)
             (let ((log (latex-to-svg-backend--process-output output-buffer)))
               (latex-to-svg-backend--compile-failed
                key latex dir log 'mathjax
                (latex-to-svg-backend--mathjax-formula-error exit log) exit)))
         (latex-to-svg-backend--compile-done key)
         (when (buffer-live-p output-buffer)
           (kill-buffer output-buffer))
         (delete-directory dir t))))))

(provide 'latex-to-svg-backend-mathjax)
;;; latex-to-svg-backend-mathjax.el ends here
