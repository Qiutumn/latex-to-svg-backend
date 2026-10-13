;;; l2s-ratex-server.el --- Benchmark RaTeX's render-svg as a server -*- lexical-binding: t; -*-

;; Standalone: talks to `render-svg --stdout' directly, not through
;; latex-to-svg-backend.  Same corpus and rows as l2s-bench.el.

(require 'cl-lib)
(require 'l2s-bench)

(defvar l2s-rs--program "render-svg"
  "The render-svg program of RaTeX.")
(defvar l2s-rs--procs nil "Alist (INLINE . PROCESS).")

(defun l2s-rs--start (inline)
  "Start a render-svg server for INLINE or display formulas."
  (let* ((queue nil)
         (proc (make-process
                :name "l2s-ratex-server" :buffer nil :noquery t
                :connection-type 'pipe
                :command (append (list l2s-rs--program "--stdout"
                                       "--font-size" "40" "--dpr" "0.25"
                                       "--color" "#010203")
                                 (and inline '("--inline")))
                :stderr (get-buffer-create " *l2s-ratex-server-stderr*"))))
    (process-put proc 'queue queue)
    (process-put proc 'acc "")
    (set-process-filter
     proc
     (lambda (p string)
       (let ((acc (concat (process-get p 'acc) string)))
         (while (string-match "</svg>\n?" acc)
           (let ((svg (substring acc 0 (match-end 0))))
             (setq acc (substring acc (match-end 0)))
             (let ((callbacks (process-get p 'callbacks)))
               (process-put p 'callbacks (cdr callbacks))
               (when (car callbacks) (funcall (car callbacks) svg)))))
         (process-put p 'acc acc))))
    proc))

(defun l2s-rs--proc (inline)
  (let ((cell (assq inline l2s-rs--procs)))
    (unless (and cell (process-live-p (cdr cell)))
      (setq l2s-rs--procs (cons (cons inline (l2s-rs--start inline))
                                (assq-delete-all inline l2s-rs--procs)))
      (setq cell (assq inline l2s-rs--procs)))
    (cdr cell)))

(defun l2s-rs-stop ()
  (dolist (cell l2s-rs--procs) (when (process-live-p (cdr cell)) (delete-process (cdr cell))))
  (setq l2s-rs--procs nil))

(defun l2s-rs--request (formula done)
  "Send FORMULA (BODY DISPLAY-P) and call DONE with its image."
  (let* ((proc (l2s-rs--proc (not (cadr formula))))
         (callbacks (process-get proc 'callbacks)))
    (process-put proc 'callbacks
                 (append callbacks
                         (list (lambda (svg)
                                 (funcall done (create-image svg 'svg t :scale 1.0))))))
    (process-send-string proc (concat (car formula) "\n"))))

(defun l2s-rs--one (formula)
  (let ((start (float-time)) finished elapsed)
    (l2s-rs--request formula (lambda (image)
                               (unless (> (car (image-size image t)) 0) (error "Empty image"))
                               (setq elapsed (* 1000 (- (float-time) start)) finished t)))
    (l2s-bench--wait (lambda () finished))
    elapsed))

(defun l2s-rs--burst (from)
  (let ((start (float-time)) (remaining 30))
    (dotimes (n 30)
      (l2s-rs--request (l2s-bench--formula (+ from n))
                       (lambda (image) (image-size image t) (cl-decf remaining))))
    (l2s-bench--wait (lambda () (zerop remaining)))
    (* 1000 (- (float-time) start))))

(defun l2s-rs-run ()
  "Measure the rows of l2s-bench.el for RaTeX as a server."
  (let (result)
    (l2s-rs-stop)
    (push (cons 'cold_first_ms (l2s-rs--one (l2s-bench--formula 100))) result)
    (let (new)
      (dotimes (n 20) (push (l2s-rs--one (l2s-bench--formula (+ 200 n))) new))
      (push (cons 'new_formula_ms (l2s-bench--median new)) result))
    (push (cons 'burst_30_new_ms (l2s-rs--burst 300)) result)
    (l2s-rs-stop)
    (push (cons 'restart_30_ms (l2s-rs--burst 300)) result)
    (l2s-rs-stop)
    (nreverse result)))

(provide 'l2s-ratex-server)
