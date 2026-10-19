;;; latex-to-svg-backend-latex.el --- LaTeX engine of latex-to-svg-backend -*- lexical-binding: t -*-

;; Copyright (C) 2026 Andrea Alberti

;; Author: Andrea Alberti <a.alberti82@gmail.com>
;; Maintainer: Andrea Alberti <a.alberti82@gmail.com>
;; Assisted-by: Claude:claude-opus-5-5
;; URL: https://github.com/alberti42/latex-to-svg-backend

;; This file is not part of GNU Emacs.

;; This package is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This package is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; The LaTeX engine of `latex-to-svg-backend': it compiles an equation
;; with `latex' + `dvisvgm' and precompiles the preamble to a LaTeX `.fmt'
;; file.  Load `latex-to-svg-backend', not this file.

;;; Code:

(require 'latex-to-svg-backend-core)
(require 'project)

(defgroup latex-to-svg-backend-latex nil
  "The LaTeX engine of `latex-to-svg-backend': `latex' + `dvisvgm'."
  :group 'latex-to-svg-backend
  :prefix "latex-to-svg-backend-")

;;;; Customization

(defcustom latex-to-svg-backend-latex-program "latex"
  "Program that compiles a LaTeX document to DVI."
  :type 'string
  :group 'latex-to-svg-backend-latex)

(defcustom latex-to-svg-backend-dvisvgm-program "dvisvgm"
  "Program that converts DVI to SVG."
  :type 'string
  :group 'latex-to-svg-backend-latex)

(defcustom latex-to-svg-backend-preamble
  "\\documentclass[varwidth,border=2pt]{standalone}
\\usepackage{amsmath}
\\usepackage{amssymb}
\\usepackage{xcolor}"
  "LaTeX preamble (everything before `\\begin{document}') for equations.
The `standalone' class crops the page tightly to the equation, so
no `preview' package is required.  The `varwidth' option is what lets
the verbatim body use *display* math — `\\=\\[...\\=\\]' and display
environments like `equation'/`align' — not just inline `$...$'
\(plain `standalone' typesets its body as a single horizontal box and
errors with \"Missing $ inserted\" on display math).  dvisvgm's
`--exact-bbox' then crops to the actual ink.

See also `latex-to-svg-backend-preamble-packages' for adding packages
without replacing this base."
  :type 'string
  :group 'latex-to-svg-backend-latex)

(define-obsolete-variable-alias 'latex-to-svg-backend-appended-preamble
  'latex-to-svg-backend-preamble-packages "0.16.0")

(defcustom latex-to-svg-backend-preamble-packages ""
  "LaTeX code for packages, appended to `latex-to-svg-backend-preamble'.
For LaTeX packages, including your own `.sty' files, which rarely
change: `\\usepackage{physics}', say.  They are dumped into the `.fmt'
file (see `latex-to-svg-backend-precompile') and read once.  Changing
this text dumps the whole `.fmt' file again.  For a few macros of your
own that you change often, see `latex-to-svg-backend-preamble-macros'.

The value is folded into the cache key, so changing it re-renders.
Set in a project's `.dir-locals.el', it is dumped into a `.fmt' file of
that project, and `\\input' looks for its files in the project root, as
for `latex-to-svg-backend-preamble-macros'.  After editing a file it
loads, `latex-to-svg-backend-invalidate-format' makes the next compile
dump the `.fmt' file again."
  :type 'string
  :group 'latex-to-svg-backend-latex)

(define-obsolete-variable-alias 'latex-to-svg-backend-preamble-not-precompiled
  'latex-to-svg-backend-preamble-macros "0.16.0")

(defcustom latex-to-svg-backend-preamble-macros ""
  "LaTeX code for a few macros of your own, written after the preamble.
For macros you change often, typically `\\input{macros.tex}', set per
project in `.dir-locals.el'.  They are read at every compile and are
not dumped into the `.fmt' file (see `latex-to-svg-backend-precompile'),
so an edit dumps nothing again.  Packages belong in
`latex-to-svg-backend-preamble-packages', where they are dumped once.

`\\input' looks for the file in the project root (`project-root'), or
in `default-directory' outside a project, so `\\input{paper/macros.tex}'
names a file below the root.  The value and the directory are folded
into the cache key; the contents of `macros.tex' are not, so after
editing it the equations have to be compiled again
\(`latex-to-svg-backend-invalidate').  The RaTeX engine ignores this
option."
  :type 'string
  :group 'latex-to-svg-backend-latex)

(defcustom latex-to-svg-backend-line-width nil
  "Maximum typeset width of an equation, as a LaTeX dimension string.
This caps the width of the `varwidth' box the body is set in (the
`standalone' class's `\\sa@width').  When nil (the default) the class's
default is used (`\\linewidth', ~345pt).

A *numbered* display sets its number flush right at this width, and TeX
drops it onto a second line when the equation is wider, so the number
stays on the line only while the equation fits within it.  Raise it,
say to \"20cm\", when wide numbered equations wrap their number; lower
it, say to \"6cm\", to tuck the number closer to the equation when every
equation is short.  Either way this just moves the right margin; the
one rule is not to set it below your widest numbered equation (which
would wrap).  Unnumbered content is unaffected (cropped to its ink).

The value is folded into the cache key, so changing it re-renders."
  :type '(choice (const :tag "Class default (~345pt)" nil)
                 (string :tag "LaTeX dimension"))
  ;; This string is interpolated verbatim into the preamble
  ;; (`\def\sa@width{...}'), so a file-local value is LaTeX code unless it is
  ;; validated.  Accept only a bare signed decimal plus a TeX unit: no brace,
  ;; backslash or space can get through, so nothing can escape the `\def'.
  :safe (lambda (v)
          (or (null v)
              (and (stringp v)
                   (string-match-p
                    (concat "\\`[+-]?\\(?:[0-9]+\\(?:\\.[0-9]*\\)?\\|\\.[0-9]+\\)"
                            "\\(?:pt\\|pc\\|in\\|bp\\|cm\\|mm\\|dd\\|cc\\|sp\\|ex\\|em\\)\\'")
                    v))))
  :group 'latex-to-svg-backend-latex)

(defcustom latex-to-svg-backend-precompile t
  "When non-nil, precompile the preamble to a LaTeX `.fmt' file.

The class and packages in `latex-to-svg-backend-preamble' /
`latex-to-svg-backend-preamble-packages' are dumped once, with TeX's
`\\dump', to a `.fmt' file keyed by the preamble text; every equation
compile then loads it with a `%&' first line instead of re-reading the
preamble, which speeds each compile up noticeably.

When the dump fails, the backend embeds the full preamble in each
equation for the rest of the session.  A `.fmt' file dumped by
another LaTeX binary (after a TeX toolchain upgrade, or with another TeX
on the variable `exec-path') is detected and dumped again;
`latex-to-svg-backend-flush-format' is the manual escape hatch."
  :type 'boolean
  :safe #'booleanp
  :group 'latex-to-svg-backend-latex)

(defcustom latex-to-svg-backend-metadata-prefix nil
  "Line prefix marking compile metadata to capture, or nil to disable.
When a string, after each successful compile the first integer on a LaTeX
log line beginning with it (the FINAL value) is paired with the caller's
`:metadata' value (the INITIAL value) and stored as the plist
`(:nums (INITIAL . FINAL))' in the equation's `.eld' sidecar next to
its SVG, exposed by `latex-to-svg-backend-metadata' (on cache hit or miss).

So the caller supplies INITIAL directly (a value it already knows, in
Elisp), and only FINAL — the thing the compile computes — travels through
LaTeX, emitted with `\\typeout{PREFIX \\arabic{COUNTER}}'.  Keep that line
short: TeX wraps log lines near column 80."
  :type '(choice (const :tag "Disabled" nil) string)
  ;; Inert: only ever matched against compile-log lines
  ;; (`string-prefix-p'), never written into the document.
  :safe (lambda (v) (or (null v) (stringp v)))
  :group 'latex-to-svg-backend-latex)

;;;; State

;; Bookkeeping of the precompiled `.fmt' files, keyed by
;; `latex-to-svg-backend--format-key' (a hash of the preamble text + LaTeX
;; program).  `--format-stamps' holds the stamp of each `.fmt' file, read
;; from disk once per session, so each compile checks the files it names
;; without reading it; `--format-blocklist' records keys whose dump
;; failed, so precompilation is abandoned for them for the rest of the
;; session and the backend falls back to full compiles.
(defvar latex-to-svg-backend--format-stamps (make-hash-table :test 'equal)
  "Map of `.fmt' key to its stamp, read once per session.
See `latex-to-svg-backend--format-stamp'.")

(defvar latex-to-svg-backend--format-blocklist (make-hash-table :test 'equal)
  "Keys of the `.fmt' files whose dump failed; precompilation skipped.")

(defvar latex-to-svg-backend--format-programs
  (list (lambda () latex-to-svg-backend-latex-program))
  "Functions returning the TeX programs that dump a `.fmt' file.
Each `.fmt' file is keyed by its program (see
`latex-to-svg-backend--format-key'), so
`latex-to-svg-backend-invalidate-format' deletes one per program.  An
engine that dumps with another program adds a function here; one that
returns nil stands for `latex-to-svg-backend-latex-program'.")

;;;; Capability

(defun latex-to-svg-backend--latex-tools-available-p ()
  "Return non-nil when the LaTeX-to-SVG toolchain is on the variable `exec-path'."
  (and (executable-find latex-to-svg-backend-latex-program)
       (executable-find latex-to-svg-backend-dvisvgm-program)))

;;;; Preamble

(defun latex-to-svg-backend--preamble ()
  "Return the current buffer's LaTeX preamble: the base plus its packages.
This is the exact text embedded before `\\begin{document}' in a full
compile, and the text dumped into the precompiled `.fmt' file.  When
`latex-to-svg-backend-line-width' is set, a `\\sa@width' override is
appended so the `varwidth' box uses that width (see that variable).

When `latex-to-svg-backend-preamble' or
`latex-to-svg-backend-preamble-packages' has a buffer-local value, the
text starts with the line of `latex-to-svg-backend--input-path', so a
relative `\\input' in it finds its file: the dump runs in the cache.
The directory is then part of the text, so two projects with the same
`\\input{macros.tex}' get two `.fmt' files; without a buffer-local value
everyone shares one."
  (concat
   (when (or (local-variable-p 'latex-to-svg-backend-preamble)
             (local-variable-p 'latex-to-svg-backend-preamble-packages))
     (latex-to-svg-backend--input-path))
   latex-to-svg-backend-preamble
   (unless (string-empty-p latex-to-svg-backend-preamble-packages)
     (concat "\n" latex-to-svg-backend-preamble-packages))
   ;; Override `standalone's varwidth width (`\sa@width', default
   ;; `\linewidth').  Placed last so it wins over the class default.
   (when latex-to-svg-backend-line-width
     (format "\n\\makeatletter\\def\\sa@width{%s}\\makeatother"
             latex-to-svg-backend-line-width))))

(defun latex-to-svg-backend--input-directory ()
  "Return the directory `\\input' searches for the current buffer, or nil.
That is the project root (`project-root'), else `default-directory'.
The directory is written into TeX code (see
`latex-to-svg-backend--input-path'), so a directory whose name
holds a character TeX reads as code is refused, as is a remote one
\(the compile runs locally): the refusal is reported once per buffer
\(see `latex-to-svg-backend--warn') and nil returned, and no
`\\input@path' is written."
  (let ((dir (file-name-as-directory
              (expand-file-name
               (if-let* ((project (project-current)))
                   (project-root project)
                 default-directory)))))
    (cond
     ;; LaTeX runs on this machine and cannot open a file on another.
     ((file-remote-p dir)
      (latex-to-svg-backend--warn
       "remote input directory"
       (format "The project directory %s is remote, but LaTeX runs on this \
machine, so `\\input' does not search it.
To use the files of the project, open it from a local directory." dir))
      nil)
     ;; The OS allows characters in a path that TeX reads as code: `%'
     ;; starts a comment, `#' a parameter, `\' a command, braces a group,
     ;; and `~' is a space.
     ((string-match-p "[\\{}%#~]" dir)
      (latex-to-svg-backend--warn
       "input directory holds TeX code"
       (format "The project directory %s holds one of \\ { } %% # ~, \
which TeX reads as code, so `\\input' does not search it.
To use the files of the project, rename the directory." dir))
      nil)
     (t dir))))

(defun latex-to-svg-backend--input-path ()
  "Return the line pointing `\\input@path' at the current buffer's project.
The directory is `latex-to-svg-backend--input-directory'; the line is
nil when that refuses it."
  (when-let* ((dir (latex-to-svg-backend--input-directory)))
    (format "\\makeatletter\\def\\input@path{{%s}}\\makeatother\n" dir)))

(defun latex-to-svg-backend--macros ()
  "Return the current buffer's text for after the preamble, or \"\".
That is `latex-to-svg-backend-preamble-macros', preceded by
the line of `latex-to-svg-backend--input-path', or \"\" when the option
is empty."
  (if (string-empty-p latex-to-svg-backend-preamble-macros)
      ""
    (concat (latex-to-svg-backend--input-path)
            latex-to-svg-backend-preamble-macros)))

(defun latex-to-svg-backend--latex-inputs ()
  "Return what the LaTeX engine reads from the current buffer, as a plist.
That is `(:preamble PREAMBLE :macros TEXT)', the texts of
`latex-to-svg-backend--preamble' and
`latex-to-svg-backend--macros'.  A request reads them once,
in the buffer that makes it, and passes them on: a compile may start
from another compile's sentinel, and a fallback from its own, where the
current buffer is another."
  (list :preamble (latex-to-svg-backend--preamble)
        :macros (latex-to-svg-backend--macros)))

(defun latex-to-svg-backend--latex-cache-salt (inputs)
  "Return what `latex-to-svg-backend--cache-key' folds in for LaTeX.
INPUTS is as for `latex-to-svg-backend--latex-inputs'.  That is the
preamble, then the macros text when it is not empty, so an
empty one leaves the key as it was before that option existed."
  (let ((preamble (plist-get inputs :preamble))
        (macros (plist-get inputs :macros)))
    (if (string-empty-p macros)
        preamble
      (concat preamble "\n" macros))))

;;;; Preamble precompilation (.fmt)

;; Speedup: dump the preamble (class + packages) to a LaTeX `.fmt' file once,
;; with TeX's `\dump', then load it from every equation compile with a `%&'
;; first line instead of re-reading and re-loading amsmath/xcolor/... each
;; time.  Entirely optional: when the dump fails, the backend falls back
;; to embedding the full preamble in each equation, so a `.fmt' file is a
;; pure performance optimization, never a correctness dependency.

(defun latex-to-svg-backend--latex-binary (&optional program)
  "Return the path to the LaTeX executable, or nil.
PROGRAM is the TeX program, by default `latex-to-svg-backend-latex-program'.
Honours an absolute PROGRAM, else resolves the command name on variable
`exec-path'.  Used for the freshness check of the `.fmt' file."
  (let ((prog (car (split-string (or program latex-to-svg-backend-latex-program)))))
    (if (file-name-absolute-p prog)
        (and (file-executable-p prog) prog)
      (executable-find prog))))

(defun latex-to-svg-backend--latex-format-name (&optional program)
  "Return the name of the LaTeX `.fmt' file the dump starts from.
That is the `&NAME' of the `-ini' run, e.g. \"latex\" for `latex.fmt':
the name of PROGRAM, by default `latex-to-svg-backend-latex-program'."
  (file-name-nondirectory
   (car (split-string (or program latex-to-svg-backend-latex-program)))))

(defun latex-to-svg-backend--format-key (preamble &optional program)
  "Return the cache key naming the precompiled `.fmt' file of PREAMBLE.
PREAMBLE is the text of `latex-to-svg-backend--preamble'.  Folds in
PREAMBLE and the TeX PROGRAM that dumps it, by default
`latex-to-svg-backend-latex-program', so any change to either yields a
distinct `.fmt' file (and a dump on the next render)."
  (secure-hash 'sha1 (format "%s\0%s"
                             preamble
                             (or program latex-to-svg-backend-latex-program))))

(defun latex-to-svg-backend--fmt-dir ()
  "Return the subdirectory holding precompiled `.fmt' files, creating it."
  (latex-to-svg-backend--subdir "fmt"))

(defun latex-to-svg-backend--format-file (fkey)
  "Return the path of the precompiled `.fmt' file for FKEY."
  (expand-file-name (concat fkey ".fmt") (latex-to-svg-backend--fmt-dir)))

(defun latex-to-svg-backend--format-stamp-file (format-file)
  "Return the path of the stamp (`.eld') of FORMAT-FILE.
The stamp names the files FORMAT-FILE was dumped from (see
`latex-to-svg-backend--format-stamp')."
  (concat (file-name-sans-extension format-file) ".eld"))

(defun latex-to-svg-backend--file-stamp (file)
  "Return (NAME . MTIME) for FILE, or nil when it does not exist.
NAME is FILE with the symbolic links of its last component followed
\(`file-chase-links'), and MTIME the modification time of the file it
names.  `file-attributes' follows the links of the directories, so
the pair describes the file itself: the `ls-R' that Debian links into
the tree, or the binary behind `/Library/TeX/texbin/latex'.  It costs
a fraction of `file-truename', which resolves every component in Lisp
and takes most of a millisecond for a TeX binary."
  (let ((name (file-chase-links file)))
    (when-let* ((mtime (file-attribute-modification-time
                        (file-attributes name))))
      (cons name mtime))))

(defun latex-to-svg-backend--file-unchanged-p (entry)
  "Return non-nil when ENTRY, a (FILE . MTIME) pair, still holds.
That is when FILE exists and its modification time is MTIME."
  (and (consp entry)
       (when-let* ((mtime (file-attribute-modification-time
                           (file-attributes (car entry)))))
         (time-equal-p mtime (cdr entry)))))

(defun latex-to-svg-backend--recorded-inputs (fls)
  "Return the absolute names of the files TeX read, from FLS.
FLS is the file list `-recorder' makes TeX write; nil when it is
missing, as from a TeX that does not write one."
  (when (file-readable-p fls)
    (with-temp-buffer
      (insert-file-contents fls)
      (let ((files nil))
        (while (re-search-forward "^INPUT \\(.+\\)$" nil t)
          (let ((file (match-string 1)))
            (when (file-name-absolute-p file)
              (push file files))))
        (delete-dups (nreverse files))))))

(defun latex-to-svg-backend--tree-indexes (files)
  "Return the `ls-R' files of the TeX trees holding FILES.
kpathsea finds a tree's files through the `ls-R' at its root, so
whatever installs or updates files in the tree regenerates it with
`mktexlsr': `tlmgr', and the package managers of the Linux
distributions.  A file in no such tree adds nothing."
  (let ((seen (make-hash-table :test 'equal))
        (indexes nil))
    (dolist (file files)
      (let ((dir (file-name-directory file))
            (found nil))
        (while (and dir (not found) (not (gethash dir seen)))
          (puthash dir t seen)
          (let ((index (expand-file-name "ls-R" dir))
                (parent (file-name-directory (directory-file-name dir))))
            (if (file-exists-p index)
                (setq found index)
              (setq dir (unless (equal parent dir) parent)))))
        (when found
          (push found indexes))))
    (nreverse indexes)))

(defun latex-to-svg-backend--format-stamp (binary &optional inputs)
  "Return the stamp of a `.fmt' file dumped by the LaTeX BINARY.
INPUTS are the files the dump read (see
`latex-to-svg-backend--recorded-inputs').  The stamp is a plist whose
values are (NAME . MTIME) pairs (see
`latex-to-svg-backend--file-stamp'):

  :binary     BINARY.  An upgrade of TeX replaces the binary, which
              changes its modification time; another TeX first on
              variable `exec-path' changes either.
  :latex-fmt  the distribution's `.fmt' file the dump started from,
              such as `latex.fmt', which the distribution dumps again
              when its kernel or its binary is updated.
  :ls-r       a list, the `ls-R' file of each TeX tree the dump read
              from (see `latex-to-svg-backend--tree-indexes'), which
              changes when a package is updated.

The last two are missing without INPUTS."
  (let ((base (seq-find (lambda (file) (string-suffix-p ".fmt" file))
                        inputs))
        (indexes (delq nil (mapcar #'latex-to-svg-backend--file-stamp
                                   (latex-to-svg-backend--tree-indexes
                                    inputs)))))
    (append (list :binary (latex-to-svg-backend--file-stamp binary))
            (when-let* ((entry (and base (latex-to-svg-backend--file-stamp
                                          base))))
              (list :latex-fmt entry))
            (when indexes
              (list :ls-r indexes)))))

(defun latex-to-svg-backend--read-format-stamp (format-file)
  "Return the stamp of FORMAT-FILE, or nil when it cannot be read.
An unreadable stamp is nil with no warning: the `.fmt' file is then
stale, and the dump writes a new stamp, and warns when it cannot (see
`latex-to-svg-backend--write-format-stamp')."
  (let ((file (latex-to-svg-backend--format-stamp-file format-file)))
    (when (file-readable-p file)
      (condition-case nil
          (with-temp-buffer
            (insert-file-contents file)
            (read (current-buffer)))
        ((end-of-file invalid-read-syntax file-error) nil)))))

(defun latex-to-svg-backend--format-fresh-p (stamp binary)
  "Return non-nil when the `.fmt' file of STAMP is fresh for BINARY.
STAMP is a plist of `latex-to-svg-backend--format-stamp'.  It is fresh
when its binary is BINARY and every file it names exists with the
modification time it records.  A stamp written before 0.16.0 names
the binary by a string, and is stale, so its `.fmt' file is dumped
again once; so is a `.fmt' file with no stamp."
  (let ((entry (and (consp stamp) (plist-get stamp :binary))))
    (and (consp entry)
         (equal (car entry) (file-chase-links binary))
         (latex-to-svg-backend--file-unchanged-p entry)
         (seq-every-p #'latex-to-svg-backend--file-unchanged-p
                      (append (when-let* ((base (plist-get stamp :latex-fmt)))
                                (list base))
                              (plist-get stamp :ls-r))))))

(defun latex-to-svg-backend--write-format-stamp (format-file binary
                                                             &optional inputs)
  "Write the stamp of FORMAT-FILE, dumped by BINARY, and return it.
INPUTS are the files the dump read (see
`latex-to-svg-backend--format-stamp').  A stamp that cannot be written
is reported once per buffer (see `latex-to-svg-backend--warn'); the
`.fmt' file still serves this session and is dumped again in the
next."
  (let ((file (latex-to-svg-backend--format-stamp-file format-file))
        (stamp (latex-to-svg-backend--format-stamp binary inputs)))
    (condition-case err
        (with-temp-file file
          (prin1 stamp (current-buffer)))
      (file-error
       (latex-to-svg-backend--warn
        "writing a .fmt stamp"
        (format "Cannot write %s: %s.
The preamble is precompiled again in each session.  %s"
                file (error-message-string err)
                (latex-to-svg-backend--cache-fix)))))
    stamp))

(defun latex-to-svg-backend--touch-format (format-file)
  "Bump FORMAT-FILE's modification time and return FORMAT-FILE, or nil.
`latex-to-svg-backend-gc' deletes a `.fmt' file whose mtime is older
than `latex-to-svg-backend-cache-max-age', so this runs on every compile
that loads it: a session that runs for longer must not lose the `.fmt'
file it uses.  Nil means another session collected FORMAT-FILE a
moment ago; the caller then compiles with the full preamble.  Any other
refusal by the filesystem is reported once per buffer (see
`latex-to-svg-backend--warn') and FORMAT-FILE returned: the `.fmt' file
works, it only ages out."
  (condition-case err
      (progn (set-file-times format-file) format-file)
    (file-missing nil)
    (file-error
     (latex-to-svg-backend--warn
      "recording .fmt use"
      (format "Cannot record the use of %s: %s.
The garbage collector deletes a .fmt file unused for \
`latex-to-svg-backend-cache-max-age' days, and cannot tell that this \
one is in use.  %s"
              format-file (error-message-string err)
              (latex-to-svg-backend--cache-fix)))
     format-file)))

(defun latex-to-svg-backend--build-format (fkey preamble &optional program)
  "Dump PREAMBLE to the `.fmt' file for FKEY, synchronously.
Return the `.fmt' path on success, nil on failure.  Writes PREAMBLE
followed by TeX's `\\dump' to a scratch `.tex' in the `fmt/'
subdirectory and runs the TeX PROGRAM on it in `-ini' mode (by default
`latex-to-svg-backend-latex-program'), which writes
`<cache>/fmt/FKEY.fmt'.  The build log is in
the `*latex-to-svg-backend-precompile-log*' buffer for inspection.
TeX's `-recorder' lists the files the dump read, from which the stamp
is written (see `latex-to-svg-backend--write-format-stamp') and kept
in `latex-to-svg-backend--format-stamps'.

A preamble that will not dump exits non-zero and yields nil (the caller
falls back to a full compile, which reports the real LaTeX error).  A
TeX program that is not found signals `file-missing', which
`latex-to-svg-backend--ensure-format' handles; one that is found but
cannot be started is reported once per buffer (see
`latex-to-svg-backend--warn')."
  (let* ((dir (latex-to-svg-backend--fmt-dir))
         (base (expand-file-name fkey dir))
         (fmt (concat base ".fmt"))
         (pre-tex (concat base ".tex"))
         (log (concat base ".log"))
         (fls (concat base ".fls"))
         (buffer (get-buffer-create "*latex-to-svg-backend-precompile-log*")))
    (with-current-buffer buffer (erase-buffer))
    ;; Pin UTF-8: see `latex-to-svg-backend--compile' on why the encoding is
    ;; fixed on write rather than declared with `inputenc'.
    (let ((coding-system-for-write 'utf-8-unix))
      (with-temp-file pre-tex
        (insert preamble "\n\\dump\n")))
    (message "latex-to-svg-backend: precompiling LaTeX preamble...")
    (let* ((tex (or program latex-to-svg-backend-latex-program))
           (rv (unwind-protect
                   (condition-case err
                       (call-process tex
                                     nil buffer nil
                                     (concat "-output-directory=" dir)
                                     "-ini"
                                     "-recorder"
                                     (concat "-jobname=" fkey)
                                     (concat "&" (latex-to-svg-backend--latex-format-name
                                                  program))
                                     pre-tex)
                     (file-missing (signal (car err) (cdr err)))
                     ;; Found but cannot be started.  Report it; the
                     ;; caller falls back to a full compile, which reports
                     ;; its own failure.
                     (file-error
                      (latex-to-svg-backend--warn
                       "dumping the LaTeX preamble"
                       (format "Cannot run %s to precompile the LaTeX \
preamble: %s.
Make %s executable, or set the engine's program in \
M-x customize-group RET latex-to-svg-backend."
                               tex (error-message-string err) tex))
                      nil))
                 (delete-file pre-tex))))
      (unwind-protect
          (if (and (eql rv 0) (file-exists-p fmt))
              (progn
                (delete-file log)
                (when-let* ((binary (latex-to-svg-backend--latex-binary
                                     program)))
                  (puthash fkey
                           (latex-to-svg-backend--write-format-stamp
                            fmt binary
                            (latex-to-svg-backend--recorded-inputs fls))
                           latex-to-svg-backend--format-stamps))
                fmt)
            (delete-file fmt)
            nil)
        (delete-file fls)))))

(defun latex-to-svg-backend--ensure-format (preamble &optional program)
  "Return the path of a fresh precompiled `.fmt' file of PREAMBLE, or nil.
PREAMBLE is the text of `latex-to-svg-backend--preamble'; PROGRAM is
the TeX program that dumps and loads it, by default
`latex-to-svg-backend-latex-program'.  Dumps the `.fmt' file on first
use (synchronously) and caches it on disk.  Before each use it checks
the stamp, read once per session (see
`latex-to-svg-backend--format-stamps'), and dumps the `.fmt' file
again when a file the stamp names has changed (see
`latex-to-svg-backend--format-fresh-p'): another LaTeX binary, as
after a TeX toolchain upgrade, where `latex' would otherwise refuse the
`.fmt' file on every compile, or an update of the distribution.  Bumps
the mtime of the `.fmt' file it returns (see
`latex-to-svg-backend--touch-format').  Returns nil — so the caller
uses a full compile — when precompilation is off, the dump fails, or
the `.fmt' file has been blocklisted after an earlier failure.  When
PROGRAM is not found, it returns nil without blocklisting, so the
compile reports the missing program and the dump runs once PROGRAM is
installed.  A blocklisted `.fmt' file is reported once per buffer
\(see `latex-to-svg-backend--report-blocked-format')."
  (when latex-to-svg-backend-precompile
    (let ((fkey (latex-to-svg-backend--format-key preamble program)))
      (if (gethash fkey latex-to-svg-backend--format-blocklist)
          (progn (latex-to-svg-backend--report-blocked-format fkey) nil)
        (let* ((fmt (latex-to-svg-backend--format-file fkey))
               (latex-bin (latex-to-svg-backend--latex-binary program))
               (exists (file-exists-p fmt)))
          (if (and exists
                   (or (null latex-bin)
                       (latex-to-svg-backend--format-fresh-p
                        (or (gethash fkey latex-to-svg-backend--format-stamps)
                            (puthash fkey
                                     (latex-to-svg-backend--read-format-stamp fmt)
                                     latex-to-svg-backend--format-stamps))
                        latex-bin)))
              (latex-to-svg-backend--touch-format fmt)
            ;; Missing or stale -> (re)build.
            (remhash fkey latex-to-svg-backend--format-stamps)
            (delete-file fmt)
            (delete-file (latex-to-svg-backend--format-stamp-file fmt))
            (condition-case nil
                (or (latex-to-svg-backend--build-format fkey preamble program)
                    ;; The dump failed.  Give up on this preamble for the
                    ;; session: retrying would run a synchronous `latex
                    ;; -ini' for every equation, and a preamble that will
                    ;; not dump does not start dumping on the next attempt.
                    (progn (latex-to-svg-backend--block-format fmt) nil))
              (file-missing nil))))))))

(defun latex-to-svg-backend--block-format (format-file)
  "Abandon FORMAT-FILE, whose dump failed, for the rest of the session.
Deletes the `.fmt' file (if any) and blocklists its key, so
`--ensure-format' returns nil for this preamble for the rest of the
session and the backend falls back to full compiles: a preamble that
will not dump fails again at every attempt, and each attempt is a
synchronous `latex -ini' run (see `latex-to-svg-backend--build-format';
the log stays in the `*latex-to-svg-backend-precompile-log*' buffer).
The failure is reported in the current buffer (see
`latex-to-svg-backend--report-blocked-format')."
  (let ((fkey (file-name-base format-file)))
    (puthash fkey t latex-to-svg-backend--format-blocklist)
    (remhash fkey latex-to-svg-backend--format-stamps)
    (delete-file format-file)
    (delete-file (latex-to-svg-backend--format-stamp-file format-file))
    (latex-to-svg-backend--report-blocked-format fkey)))

(defun latex-to-svg-backend--report-blocked-format (fkey)
  "Warn that the `.fmt' file of FKEY is blocklisted, once per buffer.
FKEY is a key of `latex-to-svg-backend--format-blocklist'.  The warning
is shown in the current buffer (see `latex-to-svg-backend--warn')."
  (latex-to-svg-backend--warn
   (concat "precompiled preamble failed/" fkey)
   "Precompiling the LaTeX preamble into a .fmt file failed; \
see the buffer *latex-to-svg-backend-precompile-log*.
Until the session ends, each equation is compiled with the full \
preamble, which is slower.  Once the preamble is fixed, \
M-x latex-to-svg-backend-invalidate-format precompiles it again."))

;;;###autoload
(defun latex-to-svg-backend-flush-format ()
  "Delete all precompiled `.fmt' files and forget them.

Removes every `.fmt' file in the cache `fmt/' subdirectory, with its
stamp, and forgets this session's stamps and blocklist, so the next
render dumps a fresh `.fmt' file from the current preamble.  An escape
hatch for a stale `.fmt' file the stamp missed — a TeX toolchain
upgrade or an update of the distribution is handled on its own (see
`latex-to-svg-backend--format-stamp'), so this is rarely needed."
  (interactive)
  (clrhash latex-to-svg-backend--format-stamps)
  (clrhash latex-to-svg-backend--format-blocklist)
  (let ((dir (expand-file-name "fmt" (latex-to-svg-backend--cache-dir))))
    (when (file-directory-p dir)
      (dolist (f (directory-files dir t "\\.\\(?:fmt\\|eld\\)\\'"))
        (delete-file f)))))

;;;###autoload
(defun latex-to-svg-backend-invalidate-format ()
  "Delete the precompiled `.fmt' file of the current buffer's preamble.

A `.fmt' file holds the files its preamble loads as they were when it
was dumped, and nothing detects an edit to them, so after editing one
\(say the `macros.tex' of an `\\input{macros.tex}') call this, then
compile the equations again.  Deletes the `.fmt' file with its stamp
and forgets this session's stamp and blocklist entry for it,
so the next compile dumps it again: that also retries a preamble whose
dump failed, after the missing package is installed.  Other preambles'
`.fmt' files stay (see `latex-to-svg-backend-flush-format')."
  (interactive)
  (let ((preamble (latex-to-svg-backend--preamble)))
    (dolist (program (delete-dups
                      (mapcar #'funcall latex-to-svg-backend--format-programs)))
      (let* ((fkey (latex-to-svg-backend--format-key preamble program))
             (fmt (latex-to-svg-backend--format-file fkey)))
        (remhash fkey latex-to-svg-backend--format-stamps)
        (remhash fkey latex-to-svg-backend--format-blocklist)
        (delete-file fmt)
        (delete-file (latex-to-svg-backend--format-stamp-file fmt))))))

;;;; Compile

(defun latex-to-svg-backend--write-metadata (key dir initial)
  "Write KEY's `.eld' sidecar pairing INITIAL with the compile's FINAL.
Scans the just-finished compile's `equation.log' in scratch DIR for the
first integer on a line beginning with `latex-to-svg-backend-metadata-prefix'
\(FINAL), and writes `(:nums (INITIAL . FINAL))' to `<KEY>.eld'.
INITIAL is the caller's value (from `latex-to-svg-backend's `:metadata'), stored
verbatim.  Writes nothing when the prefix is nil or no FINAL was found.
Called on a successful compile, before DIR is cleaned up."
  (when latex-to-svg-backend-metadata-prefix
    (let ((log (expand-file-name "equation.log" dir))
          (final nil))
      (when (file-readable-p log)
        (with-temp-buffer
          (let ((coding-system-for-read 'raw-text))
            (insert-file-contents log))
          (goto-char (point-min))
          (while (and (not final) (not (eobp)))
            (let ((line (buffer-substring-no-properties
                         (line-beginning-position) (line-end-position))))
              (when (string-prefix-p latex-to-svg-backend-metadata-prefix line)
                (let ((rest (substring line (length latex-to-svg-backend-metadata-prefix))))
                  (when (string-match "-?[0-9]+" rest)
                    (setq final (string-to-number (match-string 0 rest)))))))
            (forward-line 1))))
      (when final
        (condition-case err
            (with-temp-file (latex-to-svg-backend--meta-file key)
              (prin1 (list :nums (cons initial final)) (current-buffer)))
          ;; This runs in the compile sentinel, *before* the pending callbacks
          ;; fire: signalling here would leave a successfully compiled equation
          ;; unplaced.  The sidecar is a cache, so report the failure and
          ;; let the equation through.
          (file-error
           (latex-to-svg-backend--warn-waiters
            key "writing compile metadata"
            (format "Cannot write %s: %s.
The equation's number is lost.  %s"
                    (latex-to-svg-backend--meta-file key)
                    (error-message-string err)
                    (latex-to-svg-backend--cache-fix)))))))))

(defconst latex-to-svg-backend--latex-environment
  '("error_line=254" "half_error_line=238" "max_print_line=1000")
  "Environment variables for the TeX program of a compile.
TeX Live's `latex' reads them from the environment.  They let the log
show the whole line of an error, which is cut to about 50 characters
otherwise, so `latex-to-svg-backend--latex-formula-error' finds its
column.  They change only the log's formatting, so they are not part of
the cache key.  texres ignores them.")

(defun latex-to-svg-backend--latex-formula-error (dir latex offset)
  "Return the error LaTeX stopped on in the input, as a plist, or nil.
Nil when the log in scratch DIR shows no rejected input.  The input is
rejected when `equation.log' has a `! ' error line, such as \"! Undefined
control sequence.\" or \"! LaTeX Error: File `siunitx.sty' not found.\":
compiling the same document again fails the same way.  \"! I can't
write on file\" is a disk problem, not the input's, and does not count.

The plist is (:message MESSAGE :line LINE :column COLUMN).  MESSAGE is
the text after `! ', with the indented lines LaTeX breaks a long message
onto joined to it.  LINE is the 1-based line in LATEX of the `l.N' line
TeX prints after the error, where OFFSET is the number of lines
`equation.tex' holds before LATEX; nil when TeX names no line, or one
outside LATEX (`Missing $ inserted' at `\\end{document}', say).  COLUMN
is the 0-based column in that line where TeX stopped: TeX splits the
line there, and prints the text before it after `l.N '.  Nil when TeX
cut that text short, starting it with `...' (see
`latex-to-svg-backend--latex-environment').  pdfTeX prints the bytes of
a non-ASCII character, so the text is decoded as UTF-8 before it is
counted."
  (let ((log (expand-file-name "equation.log" dir)))
    (when (file-readable-p log)
      (with-temp-buffer
        (let ((coding-system-for-read 'raw-text))
          (insert-file-contents log))
        (goto-char (point-min))
        (when (and (re-search-forward "^! \\(.*\\)$" nil t)
                   (not (string-prefix-p "I can't write on file"
                                         (match-string 1))))
          (let ((message (match-string 1))
                ;; With `-halt-on-error' the next `! ' line is TeX's
                ;; "==> Fatal error occurred".
                (end (save-excursion
                       (if (re-search-forward "^! " nil t)
                           (match-beginning 0)
                         (point-max))))
                (line nil)
                (column nil))
            (forward-line 1)
            (while (looking-at "[ \t]+\\([^ \t\n].*\\)$")
              (setq message (concat message " " (match-string 1)))
              (forward-line 1))
            (when (re-search-forward "^l\\.\\([0-9]+\\) \\(.*\\)$" end t)
              (let ((n (- (string-to-number (match-string 1)) offset))
                    (before (match-string 2)))
                (when (<= 1 n (1+ (seq-count (lambda (c) (eq c ?\n)) latex)))
                  (setq line n
                        column (unless (string-prefix-p "..." before)
                                 (length (decode-coding-string
                                          before 'utf-8)))))))
            (list :message (string-trim (decode-coding-string message 'utf-8))
                  :line line
                  :column column)))))))

(defconst latex-to-svg-backend--latex-baseline-mark
  (concat "\\ifhmode\\ifnum\\prevgraf=0 \\special{dvisvgm:raw "
          (format latex-to-svg-backend--baseline-comment "{?y}")
          "}\\fi\\fi\n")
  "Text after the equation that marks the baseline of its line.
dvisvgm writes the special's text into the SVG with `{?y}' replaced by
the current vertical position, in the SVG's coordinates: after inline
math that is the baseline of its line.  After a display TeX has resumed
the paragraph on a new line, below the equation, and counts the display
as three lines in `\\prevgraf', so the mark is written only while
`\\prevgraf' is 0, before any display.  A display equation therefore
has no baseline, and is centred on its line (see
`latex-to-svg-backend--ascent').  Inline math sits on the baseline of
the last line of its paragraph, as text does.")

(defconst latex-to-svg-backend--latex-x-height-tex
  (concat "\\dimen0=\\fontdimen5\\textfont1 "
          "\\ifdim\\dimen0=0pt \\dimen0=\\fontdimen5\\font\\fi "
          "\\dimen0=\\dimexpr\\dimen0*7200/7227\\relax ")
  "TeX that sets `\\dimen0' to the x-height of the equation's font, in bp.
That is `\\fontdimen5' of the math italic font at text size, the font
the variables of an equation are set in, or of the current font when
the body set no math.  It is converted to big points, the unit of
dvisvgm's and pdftocairo's SVGs.  Run inside a group.")

(defconst latex-to-svg-backend--latex-x-height-mark
  (concat "\\begingroup" latex-to-svg-backend--latex-x-height-tex
          "\\special{dvisvgm:raw "
          (format latex-to-svg-backend--x-height-comment "\\the\\dimen0")
          "}\\endgroup\n")
  "Text after the equation that writes its font's x-height into the SVG.
See `latex-to-svg-backend--x-height-comment'.  Unlike the baseline, it
is written for display equations too: every image is sized by it.")

(defun latex-to-svg-backend--latex-toolchain ()
  "Return the toolchain of the LaTeX engine: `latex', then `dvisvgm'.
A toolchain is the plist `latex-to-svg-backend--compile' runs:

  :engine   the engine, for the failure report (see
            `latex-to-svg-backend--compile-failed');
  :program  the TeX program, nil meaning `latex-to-svg-backend-latex-program';
  :output   the file the TeX program writes in the scratch directory;
  :prefix   text written after `\\begin{document}', before the equation;
  :suffix   text written after the equation, before `\\end{document}';
  :convert  a function of the scratch directory and the TeX output
            file, returning the stages that make an SVG in the scratch
            directory (see `latex-to-svg-backend--run-process-chain');
  :store    a function of the scratch directory and the cache SVG run
            after the stages, that returns non-nil once the cache SVG
            is written, by `latex-to-svg-backend--move-to-cache'.

The LaTeX engine's `dvisvgm' writes the SVG as it is cached, and the
store moves it to the cache.  It runs at
scale 1: the SVG is vector (glyphs are outline paths via --no-fonts),
so the scale doesn't affect quality, and the displayed size is set
later by `latex-to-svg-backend-display-scale'.  `--currentcolor'
rewrites the default ink to the `currentColor' token, so the file is
color-independent (tinted at display time).  The suffix has dvisvgm
write the baseline of an inline equation into the SVG
\(`latex-to-svg-backend--latex-baseline-mark') and the x-height of the
equation's font (`latex-to-svg-backend--latex-x-height-mark')."
  (list :engine 'latex
        :program nil
        :output "equation.dvi"
        :prefix ""
        :suffix (concat latex-to-svg-backend--latex-baseline-mark
                        latex-to-svg-backend--latex-x-height-mark)
        :convert (lambda (dir dvi)
                   (let ((svg (expand-file-name "equation.svg" dir)))
                     (list
                      (list 'dvisvgm
                            (list latex-to-svg-backend-dvisvgm-program
                                  "--no-fonts"
                                  "--exact-bbox"
                                  "--currentcolor"
                                  "--scale=1"
                                  "-o"
                                  svg
                                  dvi)
                            svg))))
        :store (lambda (dir svg)
                 (latex-to-svg-backend--move-to-cache
                  (expand-file-name "equation.svg" dir) svg))))

(defun latex-to-svg-backend--compile
    (key latex &optional metadata inputs toolchain)
  "Asynchronously compile LATEX to the color-independent cache SVG for KEY.
METADATA, when non-nil, is stored as the INITIAL value in KEY's `.eld'
sidecar alongside the FINAL captured from the log (see
`latex-to-svg-backend--write-metadata').  INPUTS is the plist of
`latex-to-svg-backend--latex-inputs', nil meaning the current buffer's.
TOOLCHAIN is the plist of
`latex-to-svg-backend--latex-toolchain', nil meaning that one; another
engine that compiles with LaTeX passes its own.

LATEX is placed verbatim in the document body (the caller supplies
valid body LaTeX and chooses inline vs display via delimiters).
Writes a standalone LaTeX document, runs the TeX program and then the
TOOLCHAIN's stages in a scratch directory (see
`latex-to-svg-backend--scratch-dir'), and on success caches the
SVG and notifies every callback queued for KEY (see
`latex-to-svg-backend--enqueue').  The scratch directory is removed
when the process exits.

The preamble is loaded from a precompiled `.fmt' file when one is
available (see `latex-to-svg-backend-precompile'), via a `%&' first line;
otherwise the full preamble is embedded in the document.  A failure is
handled by `latex-to-svg-backend--compile-failed': the log is saved,
and when the TeX program stopped on an error in the document (see
`latex-to-svg-backend--latex-formula-error') the failure is recorded.
The `.fmt' file stays: its stamp, checked before it is loaded, decides
whether it is stale (see `latex-to-svg-backend--format-fresh-p').

No color is baked in: the equation's default ink becomes the literal
`currentColor', so the SVG is color-independent and is tinted to the
caller's `:color' at display time (`latex-to-svg-backend--load-svg-image').
A theme change therefore re-tints from cache without recompiling."
  (let* ((toolchain (or toolchain (latex-to-svg-backend--latex-toolchain)))
         (program (or (plist-get toolchain :program)
                      latex-to-svg-backend-latex-program))
         (store (plist-get toolchain :store))
         (dir (latex-to-svg-backend--scratch-dir))
         (tex (expand-file-name "equation.tex" dir))
         (output (expand-file-name (plist-get toolchain :output) dir))
         (svg (latex-to-svg-backend--svg-file key))
         (inputs (or inputs (latex-to-svg-backend--latex-inputs)))
         (preamble (plist-get inputs :preamble))
         (macros (plist-get inputs :macros))
         (format-file (latex-to-svg-backend--ensure-format
                       preamble (plist-get toolchain :program)))
         ;; Everything before LATEX.  Its lines are counted, so that an
         ;; error's line in `equation.tex' becomes a line in LATEX.
         (head (concat (if format-file
                           ;; Load the precompiled preamble: the `%&' line
                           ;; must be first, and names the `.fmt' file by
                           ;; absolute path without its `.fmt' extension.
                           ;; The class + packages are already in the
                           ;; `.fmt' file, so they are not written here.
                           (concat "%& " (file-name-sans-extension format-file)
                                   "\n")
                         (concat preamble "\n"))
                       (if (string-empty-p macros)
                           ""
                         (concat macros "\n"))
                       "\\begin{document}\n"
                       (plist-get toolchain :prefix)))
         (offset (seq-count (lambda (c) (eq c ?\n)) head))
         (cleanup (lambda () (delete-directory dir t)))
         (output-buffer (generate-new-buffer
                         (format " *latex-to-svg-backend-%s*" key))))
    ;; Pin UTF-8 on write.  LaTeX has read UTF-8 by default since its
    ;; 2018-04-01 release, so the encoding belongs here and not in an
    ;; `inputenc' line: adding a package to the preamble would rehash
    ;; `--cache-key' and the `.fmt' key, discarding every cached SVG and
    ;; `.fmt' file for every user, to declare what the backend already writes.
    ;; Unpinned, an equation carrying a character the user's default coding
    ;; system cannot encode (an alpha under a Latin-1 language environment,
    ;; say) makes `write-region' *prompt* -- fatal in a background compile,
    ;; and no `.tex' is written at all.  Same hazard the log copy guards
    ;; (`--compile-failed'), but this file carries the user's own math.
    (let ((coding-system-for-write 'utf-8-unix))
      (with-temp-file tex
        (insert head
                ;; LATEX is inserted verbatim: it already carries its own
                ;; math delimiters / environment (chosen by the
                ;; front-end), which also decide inline vs display sizing.
                ;; A newline after it, so that a `%' comment at the end of
                ;; LATEX does not hide the suffix.
                latex "\n"
                (or (plist-get toolchain :suffix) "")
                "\\end{document}\n")))
    (latex-to-svg-backend--run-process-chain
     key dir output-buffer
     (cons (list 'latex
                 ;; TeX reads its command line as a line of input, and the
                 ;; name of the cache directory may hold characters TeX
                 ;; reads as code: name the file in DIR, where TeX runs.
                 (list program
                       "-interaction=nonstopmode"
                       "-halt-on-error"
                       "equation.tex")
                 output
                 latex-to-svg-backend--latex-environment)
           (funcall (plist-get toolchain :convert) dir output))
     (lambda (success &optional exit)
       (let* ((stored
               (and success
                    (condition-case err
                        (or (funcall store dir svg)
                            (progn
                              (latex-to-svg-backend--append-process-log
                               output-buffer
                               "[store] output has no <svg> element")
                              nil))
                      (file-error
                       (latex-to-svg-backend--append-process-log
                        output-buffer
                        (format "[store] storing the SVG failed: %s"
                                (error-message-string err)))
                       nil)))))
         (unwind-protect
             (if stored
                 (progn
                   ;; Capture compile metadata before DIR is cleaned up.
                   (latex-to-svg-backend--write-metadata key dir metadata)
                   (latex-to-svg-backend--notify-pending key))
               (latex-to-svg-backend--compile-failed
                key latex dir
                (latex-to-svg-backend--process-output output-buffer)
                (plist-get toolchain :engine)
                (and (eq (car exit) 'latex)
                     (latex-to-svg-backend--latex-formula-error
                      dir latex offset))
                exit))
           (latex-to-svg-backend--compile-done key)
           (when (buffer-live-p output-buffer)
             (kill-buffer output-buffer))
           (funcall cleanup)))))))

(provide 'latex-to-svg-backend-latex)

;;; latex-to-svg-backend-latex.el ends here
