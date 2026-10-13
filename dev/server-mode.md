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
1.168 ms at most. Not yet measured through Emacs's process filters.

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

Open questions, for a prototype of a few dozen lines (compile 30 equations
in one session, render each with Poppler, time both steps):

1. Does a `tex_session` keep the preamble loaded between compiles? If it
   loads it again every time, much of texres's 59–73 ms stays.
2. How much of `pdftocairo`'s 32–35 ms is starting the program rather than
   rendering?

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
