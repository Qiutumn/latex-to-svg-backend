# Server mode (idea, not built)

Today every equation the backend typesets starts its own processes: `latex`
and `dvisvgm`, `texres` and `pdftocairo`, or `render-svg`. `mathjax.el` keeps
one Node process running and sends it each formula through a pipe. That, not
the language of the engine, is why MathJax wins a benchmark of new formulas
(markdown-ts-appear#7). A server mode would keep one process running per engine
and send it the equations, so that a new equation starts no process and writes
no file before its SVG reaches the cache.

## Measurements (2026-10-13, Apple M2, the user's running Emacs)

New formula, medians of three rounds (see the table posted on
markdown-ts-appear#7):

| | MathJax | LaTeX | texres | RaTeX |
|---|---:|---:|---:|---:|
| New formula | 1.43 ms | 344.88 ms | 89.14 ms | 8.01 ms |
| 30 new formulas at once | 21.08 ms | 2207.74 ms | 752.25 ms | 143.18 ms |

The MathJax Node process uses 78 MB after its first formula and 91 MB after
61; `mathjax.el` stops it after 60 s without output (`mathjax--ttl`).

Stages of one texres equation, with the preamble of a real paper and its
`.fmt` on disk:

| Stage | Time |
|---|---:|
| texres (`pdflatex`) | 58.72–73.25 ms |
| `pdftocairo -svg` | 31.55–34.50 ms |
| Total | 98.15–108.52 ms |

## RaTeX: works today

`render-svg --stdout` reads formulas from stdin, one per line, and answers
each line as it arrives, without waiting for the end of its input. Measured
from Python: 8.9 ms for the first formula, including the start of the
program; then 30 new formulas in 9.46 ms in total, 0.245 ms each (median),
1.168 ms at most.

Measured through Emacs (2026-10-13), with `server-mode-bench/`: the
benchmark talks to two `render-svg --stdout` processes (inline and display)
directly, not through the backend, makes each image with `create-image` and
rasterizes it with `image-size`. Emacs's image cache is emptied before each
run (`clear-image-cache`), so no image is rasterized twice. Medians of three
rounds:

| Scenario | RaTeX as a server | MathJax | RaTeX today |
|---|---:|---:|---:|
| First formula after start | 6.71 ms | 205.35 ms | 10.09 ms |
| New formula | 1.43 ms | 2.32 ms | 7.63 ms |
| 30 new formulas at once | 33.64 ms | 36.37 ms | 142.13 ms |
| New formula after 60 s without math | 1.43 ms (it never stops) | 202.65 ms | 9.40 ms |

The server beats MathJax in every row: narrowly on a new formula and on 30
at once, widely wherever MathJax starts Node. Through Emacs a formula takes
1.43 ms against 0.245 ms from Python: the rest is the process filter,
`create-image` and rasterization, which MathJax pays too. The benchmark
writes no SVG to the disk cache and handles no errors, which the backend
would; both add some time.

The table posted on markdown-ts-appear#7 used the same formulas in every
round without emptying the image cache, so rounds 2 and 3 found images
already rasterized. That flattered every engine about equally; MathJax's
new formula, 1.43 ms there, is 2.32 ms here.

What the backend needs:

- One process per mode: `--inline` and `--color` apply to the whole process,
  so one process for inline formulas and one for display formulas. The color
  is the fixed ink the backend already uses and tints at display time.
- Split the output: each answer ends with `</svg>`.
- Errors: `render-svg` reports each formula on stderr (`OK     1 …`, or an
  error line); match a failure to its formula there.
- Restart a process that dies; fall back to one process per formula when the
  server cannot run.

## texres: a server to write, in Rust

texres ships `libtex` (`crates/libtex`, header `include/tex.h`), built as
`cdylib`, `staticlib` and `rlib`, so Rust code can use it directly. A
`tex_session` takes files from memory (`tex_session_add_file`), and
`tex_compile` returns the PDF as bytes (`tex_result_pdf`), with the log and
the status; separate sessions may run concurrently.

`pdftocairo` is a front end to Poppler and cairo, so the server can do the
conversion too: render the page of the PDF bytes with Poppler onto a cairo
SVG surface (the `poppler-rs` and `cairo-rs` crates). One equation is then a
compile and a render in memory, with no process and no file.

### Prototype (2026-10-13)

The prototype is in `texres-server-proto/`: clone texres 0.7.7 (commit
`a7ffa56`) as `texres-server-proto/../texres-src`, apply
`tex-runtime-set-format.patch` to it, then `cargo build --release` (3 min).
`texres-proto FILE.fmt` times the in-process variants, `texres-proto FILE.fmt
fork` the forked one; `SPLIT=1` also prints TeX's run and the PDF writing of
each equation. The corpus is that of markdown-ts-appear's benchmark, wrapped
as the backend's `equation.tex` without its `%&` line. Poppler and cairo are
called through their C functions, not through the Rust crates.

What texres offers:

- A `Session` keeps only its input files. Each compile loads texres's
  built-in format again (`load_format_from(format_for_engine(...))` in
  `run_pass`), and there is no way to give it the preamble's `.fmt`. The
  patch adds `Session::set_format`.
- `Engine` does not implement `Clone`, so a loaded engine cannot be copied.
- `load_format_from` also takes an uncompressed format, so a server can
  decompress the `.fmt` once (`zstd -d` does it). Building the engine from
  the preamble's format takes 24.65 ms compressed and 16.55 ms uncompressed
  (median of 10).

The variants, per equation (round trip, median of 30), the format
decompressed once:

| Variant | Paper's preamble | Default preamble |
|---|---:|---:|
| Today: texres + `pdftocairo`, two programs | 98.15–108.52 ms | 80.58 ms |
| One process, engine rebuilt per equation | 43.26 ms | — |
| Fork from an engine built once | 31.44–36.51 ms | 19.43 ms |

"Paper's preamble" is the default plus `physics`, `stmaryrd` (only
`llbracket`, `rrbracket`), `siunitx` and `mathtools`. In the fork variant
the parent builds the in-memory file system, typesets and renders one
warm-up equation, and builds the engine; then it forks once per equation,
and the child typesets, writes the PDF, converts it to SVG and sends it
back through a pipe.

Inside a forked child, with the paper's preamble:

| Part | Time |
|---|---:|
| TeX's run (`\begin{document}`, fonts, the equation) | 23.61 ms |
| Writing the PDF | 1.57 ms |
| PDF → SVG with Poppler and cairo | 3.22–3.51 ms |
| Fork, pipe and wait | about 3 ms |

With the default preamble, TeX's run takes 12.57 ms: the packages add about
11–14 ms to every equation, in today's program too.

Conclusions:

1. Poppler and cairo render the SVG in memory in 2.82–3.51 ms, against
   31.55–34.50 ms for `pdftocairo`: about 90% of `pdftocairo`'s time is
   starting it.
2. A forked server typesets an equation 4.1 times as fast as today with the
   default preamble, and about 3 times with the paper's.
3. What remains is TeX's run, mostly `\begin{document}` and the fonts loaded
   on first use, which the `.fmt` cannot hold. Running `\begin{document}`
   once, before the fork, needs a way to stop TeX's main loop after it and
   resume in the child: a change to texres's engine. Its gain is not known.
4. A texres server stays at tens of milliseconds, against 1.43 ms for
   MathJax and 0.245 ms for a RaTeX server.

Licence: Poppler is GPL-2.0-or-later, so the server is GPL, which fits the
GPL-3.0-or-later packages.

Distribution: the server is an optional binary, as Ghostel and other Emacs
packages ship theirs; MELPA cannot ship it. Without the binary, the backend
starts one process per equation as today.

## Not pursued: one compile for several equations

Typesetting several equations as one document, one per page, and splitting
the pages afterwards was dropped: an error in one equation can affect the
others in the batch and has to be traced back to its equation from the log;
the batch runs in one process instead of several in parallel; and the first
preview waits for the whole batch.
