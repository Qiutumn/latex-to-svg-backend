;;; l2s-bench.el --- Math preview benchmark for a running Emacs -*- lexical-binding: t; -*-

;; Adapted from markdown-ts-appear's test/benchmark-math.el (45d0c74), same
;; corpus and same measurements, for use through emacsclient: it sets no
;; global option (the cache directory and the backend's in-memory tables are
;; let-bound) and does not kill Emacs.  Scenarios added: an Emacs restart with
;; the disk cache populated, and MathJax's 60 s idle shutdown.

(require 'cl-lib)
(require 'seq)
(require 'latex-to-svg-backend)

(defvar l2s-bench--engine nil)
(defvar l2s-bench--color "#000000")

(defun l2s-bench--formula (n)
  "Return (BODY DISPLAY-P) for corpus item N (as in benchmark-math.el)."
  (list (pcase (% n 5)
          (0 (format "x_{%d}^2+y_{%d}^2=z_{%d}^2" n n n))
          (1 (format "\\frac{a_{%d}+b}{1+\\sqrt{x}}" n))
          (2 (format "\\int_0^{%d} e^{-x^2}\\,dx" n))
          (3 (format "\\begin{pmatrix}%d&1\\\\0&%d\\end{pmatrix}" n n))
          (_ (format "\\sum_{k=1}^{%d}\\frac{1}{k^2}" n)))
        (cl-oddp n)))

(defun l2s-bench--source (formula)
  (if (cadr formula) (concat "\\[" (car formula) "\\]")
    (concat "$" (car formula) "$")))

(defun l2s-bench--request (formula done)
  "Request FORMULA and call DONE with its image (as in benchmark-math.el)."
  (if (eq l2s-bench--engine 'mathjax)
      (let ((buffer (generate-new-buffer " *l2s-bench-staging*")))
        (with-current-buffer buffer
          (insert (l2s-bench--source formula))
          (mathjax-display
           (point-min) (point-max) (car formula)
           :options (list :display (cadr formula))
           :after (lambda (ov)
                    (unwind-protect
                        (if-let* ((image (overlay-get ov 'display)))
                            (funcall done image)
                          (error "MathJax failed: %S" (overlay-get ov 'mathjax-error)))
                      (kill-buffer buffer))))))
    (let ((source (l2s-bench--source formula)))
      (cl-labels ((request ()
                    (when-let* ((image
                                 (latex-to-svg-backend
                                  source :engine l2s-bench--engine :fallback nil
                                  :color l2s-bench--color :x-height 10
                                  :callback #'request)))
                      (funcall done image))))
        (request)))))

(defun l2s-bench--wait (predicate)
  (let ((deadline (+ (float-time) 90)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.001))
    (unless (funcall predicate) (error "Render timed out"))))

(defun l2s-bench--one (formula)
  "Return (TOTAL-MS . BLOCKED-MS) for FORMULA, rasterizing the image."
  (let ((start (float-time)) finished elapsed blocked)
    (l2s-bench--request
     formula (lambda (image)
               (unless (> (car (image-size image t)) 0) (error "Empty image"))
               (setq elapsed (* 1000 (- (float-time) start)) finished t)))
    (setq blocked (* 1000 (- (float-time) start)))
    (l2s-bench--wait (lambda () finished))
    (cons elapsed blocked)))

(defun l2s-bench--burst (from)
  "Return the ms to get the 30 images of corpus items FROM..FROM+29."
  (let ((start (float-time)) (remaining 30))
    (dotimes (n 30)
      (l2s-bench--request (l2s-bench--formula (+ from n))
                          (lambda (image) (image-size image t) (cl-decf remaining))))
    (l2s-bench--wait (lambda () (zerop remaining)))
    (* 1000 (- (float-time) start))))

(defun l2s-bench--stop-mathjax ()
  "Stop the MathJax process, as its 60 s idle timer does."
  (when-let* ((proc (car-safe mathjax--state)))
    (delete-process proc))
  (setq mathjax--state nil))

(defun l2s-bench--median (xs)
  (let* ((s (sort (copy-sequence xs) #'<)) (n (length s)))
    (if (cl-oddp n) (nth (/ n 2) s)
      (/ (+ (nth (1- (/ n 2)) s) (nth (/ n 2) s)) 2.0))))

(defun l2s-bench-run (engine)
  "Measure ENGINE (mathjax, latex, texres or ratex) from a cold state."
  (let* ((l2s-bench--engine engine)
         (l2s-bench--color "#000000")
         (latex-to-svg-backend-cache-directory (make-temp-file "l2s-bench-cache-" t))
         (latex-to-svg-backend-gc-interval nil)
         (latex-to-svg-backend--image-cache (make-hash-table :test 'equal))
         (latex-to-svg-backend--pending (make-hash-table :test 'equal))
         (latex-to-svg-backend--format-checked (make-hash-table :test 'equal))
         (latex-to-svg-backend--format-blocklist (make-hash-table :test 'equal))
         result)
    ;; As in daily use, LaTeX and texres find their `.fmt' on disk: dump it
    ;; with an unrelated formula, then empty the tables of the session, as
    ;; when Emacs starts.
    (when (memq engine '(latex texres))
      (l2s-bench--one '("a+b=c" nil))
      (clrhash latex-to-svg-backend--image-cache)
      (clrhash latex-to-svg-backend--format-checked)
      (clrhash latex-to-svg-backend--format-blocklist))
    (when (eq engine 'mathjax) (l2s-bench--stop-mathjax))
    ;; First formula after Emacs starts: MathJax starts Node.
    (let ((first (l2s-bench--one (l2s-bench--formula 100))))
      (push (cons 'cold_first_ms (car first)) result)
      (push (cons 'cold_blocked_ms (cdr first)) result))
    ;; Warm: 20 new formulas one after the other, then the same 20 again.
    (let (new again)
      (dotimes (n 20) (push (car (l2s-bench--one (l2s-bench--formula (+ 200 n)))) new))
      (dotimes (n 20) (push (car (l2s-bench--one (l2s-bench--formula (+ 200 n)))) again))
      (push (cons 'new_formula_ms (l2s-bench--median new)) result)
      (push (cons 'repeat_formula_ms (l2s-bench--median again)) result))
    ;; Burst of 30 new formulas.
    (push (cons 'burst_30_new_ms (l2s-bench--burst 300)) result)
    ;; One new formula after more than 60 s of no math: MathJax has stopped
    ;; its process; the other engines have no process to stop.
    (when (eq engine 'mathjax) (l2s-bench--stop-mathjax))
    (push (cons 'new_after_idle_ms (car (l2s-bench--one (l2s-bench--formula 150))))
          result)
    ;; Emacs restarted, the same 30 formulas: the disk cache is all that is
    ;; left (a new color makes new image specs); MathJax starts again.
    (let ((latex-to-svg-backend--image-cache (make-hash-table :test 'equal))
          (latex-to-svg-backend--format-checked (make-hash-table :test 'equal))
          (l2s-bench--color "#000001"))
      (when (eq engine 'mathjax) (l2s-bench--stop-mathjax))
      (push (cons 'restart_30_same_ms (l2s-bench--burst 300)) result))
    (delete-directory latex-to-svg-backend-cache-directory t)
    (nreverse result)))

(defun l2s-bench-all (engines rounds file)
  "Run ENGINES ROUNDS times, rotating their order; write results to FILE."
  (let (runs)
    (dotimes (r rounds)
      (let ((order (append (nthcdr (% r (length engines)) engines)
                           (seq-take engines (% r (length engines))))))
        (dolist (engine order)
          (push (cons engine (l2s-bench-run engine)) runs))))
    (with-temp-file file (prin1 (nreverse runs) (current-buffer)))
    file))

(provide 'l2s-bench)
;;; l2s-bench.el ends here
