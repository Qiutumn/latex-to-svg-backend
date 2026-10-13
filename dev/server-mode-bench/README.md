# Benchmarks behind server-mode.md

Run in a graphical Emacs, for example through `emacsclient --eval`; each
measurement blocks Emacs while it runs. Neither file sets a global option.

- `l2s-bench.el`: the corpus and measurements of markdown-ts-appear's
  `test/benchmark-math.el` (45d0c74), for `mathjax`, `latex`, `texres` and
  `ratex` through `latex-to-svg-backend`: `(l2s-bench-run 'texres)`. The cache
  directory and the backend's in-memory tables are let-bound; LaTeX and
  texres find their `.fmt` on disk. For `mathjax`, load `mathjax.el` (with
  its built `math2svg.js`, as in the GNU ELPA package) first.
- `l2s-ratex-server.el`: RaTeX's `render-svg --stdout` as a server, without
  the backend: `(l2s-rs-run)`. Set `l2s-rs--program` to your `render-svg`.

Add this directory to `load-path` first: `l2s-ratex-server.el` requires
`l2s-bench`. Call `(clear-image-cache)` before each run, so no image is rasterized twice.
