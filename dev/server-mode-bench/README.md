# Benchmarks behind server-mode.md

Run in a graphical Emacs, for example through `emacsclient --eval`; each
measurement blocks Emacs while it runs. Neither file sets a global option,
but both empty Emacs's image cache (`clear-image-cache`), so the images on
screen are rasterized again. Add this directory to `load-path` first:
`l2s-ratex-server.el` requires `l2s-bench`.

- `l2s-bench.el`: the corpus and measurements of markdown-ts-appear's
  `test/benchmark-math.el` (45d0c74), for `mathjax`, `latex`, `texres` and
  `ratex` through `latex-to-svg-backend`: `(l2s-bench-run 'texres)`. The cache
  directory and the backend's in-memory tables are let-bound; LaTeX and
  texres find their `.fmt` on disk. Emacs's image cache is emptied before
  every row, so no image is rasterized twice. For `mathjax`, load
  `mathjax.el` (with its built `math2svg.js`, as in the GNU ELPA package)
  first.

  `(l2s-bench-all-standard-preamble '(mathjax latex texres ratex) 3 FILE)`
  runs every engine three times with the backend's standard preamble and
  nothing appended, and writes the results to FILE: this is the table posted
  on markdown-ts-appear#7 on 2026-10-13, after latex-to-svg#5 was fixed.
- `l2s-ratex-server.el`: RaTeX's `render-svg --stdout` as a server, without
  the backend: `(l2s-rs-run)`. Set `l2s-rs--program` to your `render-svg`,
  and call `(clear-image-cache)` before each run.
