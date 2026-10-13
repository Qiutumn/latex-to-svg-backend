//! Prototype: typeset equations in one process with texres's runtime and a
//! preamble `.fmt` held in memory, then render each PDF to SVG with Poppler.
use std::ffi::{c_char, c_double, c_int, c_uint, c_void};
use std::time::Instant;
use tex_runtime::Session;

#[repr(C)] struct GBytes(c_void);
#[repr(C)] struct PopplerDocument(c_void);
#[repr(C)] struct PopplerPage(c_void);
#[repr(C)] struct Cairo(c_void);
#[repr(C)] struct CairoSurface(c_void);
type WriteFn = extern "C" fn(*mut c_void, *const u8, c_uint) -> c_int;
extern "C" {
    fn g_bytes_new(data: *const c_void, size: usize) -> *mut GBytes;
    fn g_bytes_unref(b: *mut GBytes);
    fn g_object_unref(o: *mut c_void);
    fn poppler_document_new_from_bytes(b: *mut GBytes, pw: *const c_char, err: *mut *mut c_void) -> *mut PopplerDocument;
    fn poppler_document_get_page(d: *mut PopplerDocument, i: c_int) -> *mut PopplerPage;
    fn poppler_page_get_size(p: *mut PopplerPage, w: *mut c_double, h: *mut c_double);
    fn poppler_page_render(p: *mut PopplerPage, cr: *mut Cairo);
    fn cairo_svg_surface_create_for_stream(f: WriteFn, closure: *mut c_void, w: c_double, h: c_double) -> *mut CairoSurface;
    fn cairo_create(s: *mut CairoSurface) -> *mut Cairo;
    fn cairo_show_page(cr: *mut Cairo);
    fn cairo_destroy(cr: *mut Cairo);
    fn cairo_surface_finish(s: *mut CairoSurface);
    fn cairo_surface_destroy(s: *mut CairoSurface);
}
extern "C" fn write_svg(closure: *mut c_void, data: *const u8, len: c_uint) -> c_int {
    let out = unsafe { &mut *(closure as *mut Vec<u8>) };
    out.extend_from_slice(unsafe { std::slice::from_raw_parts(data, len as usize) });
    0 // CAIRO_STATUS_SUCCESS
}
fn pdf_to_svg(pdf: &[u8]) -> Vec<u8> {
    let mut svg = Vec::new();
    unsafe {
        let bytes = g_bytes_new(pdf.as_ptr() as *const c_void, pdf.len());
        let doc = poppler_document_new_from_bytes(bytes, std::ptr::null(), std::ptr::null_mut());
        assert!(!doc.is_null(), "Poppler cannot read the PDF");
        let page = poppler_document_get_page(doc, 0);
        let (mut w, mut h) = (0.0, 0.0);
        poppler_page_get_size(page, &mut w, &mut h);
        let surface = cairo_svg_surface_create_for_stream(write_svg, &mut svg as *mut Vec<u8> as *mut c_void, w, h);
        let cr = cairo_create(surface);
        poppler_page_render(page, cr);
        cairo_show_page(cr);
        cairo_destroy(cr);
        cairo_surface_finish(surface);
        cairo_surface_destroy(surface);
        g_object_unref(page as *mut c_void);
        g_object_unref(doc as *mut c_void);
        g_bytes_unref(bytes);
    }
    svg
}

/// The benchmark corpus of markdown-ts-appear's benchmark-math.el.
fn formula(n: u32) -> String {
    let body = match n % 5 {
        0 => format!("x_{{{n}}}^2+y_{{{n}}}^2=z_{{{n}}}^2"),
        1 => format!("\\frac{{a_{{{n}}}+b}}{{1+\\sqrt{{x}}}}"),
        2 => format!("\\int_0^{{{n}}} e^{{-x^2}}\\,dx"),
        3 => format!("\\begin{{pmatrix}}{n}&1\\\\0&{n}\\end{{pmatrix}}"),
        _ => format!("\\sum_{{k=1}}^{{{n}}}\\frac{{1}}{{k^2}}"),
    };
    if n % 2 == 1 { format!("\\[{body}\\]") } else { format!("${body}$") }
}

/// The backend's equation.tex, without its `%&' line.
fn document(math: &str) -> String {
    format!("\\begin{{document}}\n\\ifdefined\\definecolorset\\color[RGB]{{1,2,3}}\\fi\n{math}\n\
\\ifhmode\\ifnum\\prevgraf=0 \\pdfsavepos\\write-1{{latex-to-svg-backend-baseline \\the\\pdflastypos\\space\\the\\pdfpageheight}}\\fi\\fi\n\
\\begingroup\\dimen0=\\fontdimen5\\textfont1 \\ifdim\\dimen0=0pt \\dimen0=\\fontdimen5\\font\\fi \\dimen0=\\dimexpr\\dimen0*7200/7227\\relax \\immediate\\write-1{{latex-to-svg-backend-x-height \\the\\dimen0}}\\endgroup\n\
\\end{{document}}\n")
}

fn ms(t: Instant) -> f64 { t.elapsed().as_secs_f64() * 1000.0 }

fn main() {
    if std::env::args().nth(2).as_deref() == Some("fork") {
        let fmt = std::fs::read(std::env::args().nth(1).unwrap()).unwrap();
        return fork_bench(fmt);
    }
    let fmt_path = std::env::args().nth(1).expect("usage: texres-proto FILE.fmt");
    let t = Instant::now();
    let fmt = std::fs::read(&fmt_path).unwrap();
    println!("read .fmt ({} bytes): {:.2} ms", fmt.len(), ms(t));

    let t = Instant::now();
    tex_core_load_check(&fmt);
    println!("empty document: format load + setup (first): {:.2} ms", ms(t));
    let mut loads = Vec::new();
    for _ in 0..10 { let t = Instant::now(); tex_core_load_check(&fmt); loads.push(ms(t)); }
    println!("empty document: format load + setup (median of 10): {:.2} ms", median(&mut loads));

    let mut bare = Vec::new();
    for _ in 0..10 {
        let t = Instant::now();
        let engine = tex_core::format::load_format_from(&fmt).unwrap();
        bare.push(ms(t));
        drop(engine);
    }
    println!("load_format_from alone (median of 10): {:.2} ms", median(&mut bare));
    let mut session = Session::new();
    session.set_format(fmt);
    let (mut tex, mut svg, mut total, mut passes) = (Vec::new(), Vec::new(), Vec::new(), Vec::new());
    let all = Instant::now();
    for n in 300..330 {
        session.add_file("equation.tex", document(&formula(n)).as_bytes()).unwrap();
        let t0 = Instant::now();
        let result = session.compile("equation.tex");
        let tt = ms(t0);
        if result.pdf.is_empty() {
            eprintln!("equation {n} failed: {:?}\n{}", result.status, result.diagnostics);
            eprintln!("{}", String::from_utf8_lossy(&result.log_bytes()));
            std::process::exit(1);
        }
        let t1 = Instant::now();
        let out = pdf_to_svg(&result.pdf);
        let st = ms(t1);
        assert!(out.windows(4).any(|w| w == b"<svg"), "no SVG");
        tex.push(tt); svg.push(st); total.push(tt + st); passes.push(result.passes as f64);
        if n == 300 { std::fs::write("first.svg", &out).unwrap(); std::fs::write("first.pdf", &result.pdf).unwrap(); }
    }
    let all = ms(all);
    println!("30 equations, one after the other: {all:.2} ms in total");
    println!("  typeset (median): {:.2} ms, max {:.2}", median(&mut tex.clone()), tex.iter().cloned().fold(0.0, f64::max));
    println!("  PDF -> SVG (median): {:.2} ms, max {:.2}", median(&mut svg.clone()), svg.iter().cloned().fold(0.0, f64::max));
    println!("  per equation (median): {:.2} ms", median(&mut total));
    println!("  TeX passes per equation: {:?}", passes.iter().map(|p| *p as u32).collect::<std::collections::BTreeSet<_>>());
}

fn tex_core_load_check(fmt: &[u8]) {
    // Time loading the format alone, as each compile does.
    let mut session = Session::new();
    session.set_format(fmt.to_vec());
    session.add_file("empty.tex", b"\\begin{document}\\end{document}\n").unwrap();
    let _ = session.compile("empty.tex");
}

fn median(v: &mut Vec<f64>) -> f64 {
    v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let n = v.len();
    if n % 2 == 1 { v[n / 2] } else { (v[n / 2 - 1] + v[n / 2]) / 2.0 }
}

use std::path::Path;
use tex_core::{driver, engine::{Engine, InteractionMode}};
use tex_kpse::fs::{MemoryFs, ResourceContext};

/// Build an engine from FMT, prepared for the job `equation`, as `run_pass` does.
fn prepared_engine(fmt: &[u8]) -> Engine {
    let mut engine = tex_core::format::load_format_from(fmt).unwrap();
    driver::finalize_format_load(&mut engine);
    driver::prepare_latex_job(&mut engine);
    engine.set_interaction_mode(InteractionMode::Nonstop);
    engine.halt_on_error = true;
    engine.allow_missing_main_aux = true;
    engine.job_name = "equation".to_owned();
    engine.main_dir = Some(Path::new("/project").to_owned());
    engine.aux_dir = Some(Path::new("/project").to_owned());
    engine.out_dir = "/project/".to_owned();
    engine
}

/// Typeset MATH with ENGINE and return (PDF, typeset ms).
fn typeset(engine: &mut Engine, memory: &MemoryFs, math: &str) -> (Vec<u8>, f64) {
    let t = Instant::now();
    memory.insert(Path::new("/project/equation.tex"), document(math).into_bytes()).unwrap();
    if engine.input_file("/project/equation.tex") {
        driver::insert_everyjob(engine);
        engine.run();
        engine.finish_job_diagnostics();
    }
    let run = ms(t);
    assert!(engine.error_count == 0 && !engine.pdf_doc.pages.is_empty(), "TeX failed:\n{}", engine.log);
    let t2 = Instant::now();
    let pdf = driver::finish_pdf(engine, false).unwrap();
    if std::env::var_os("SPLIT").is_some() {
        eprintln!("split run {run:.2} ms, finish_pdf {:.2} ms", ms(t2));
    }
    (pdf, ms(t))
}

fn fork_bench(fmt: Vec<u8>) {
    let epoch = 1_791_000_000;
    let memory = MemoryFs::new(Path::new("/project"), epoch).unwrap();
    let context = ResourceContext::memory(memory.clone(), Path::new("/project"),
                                          Path::new("/project"), true).unwrap();
    let _scope = context.enter();

    // Warm up the caches of the process, then build the engine to fork from.
    let t = Instant::now();
    let mut warm = prepared_engine(&fmt);
    let (pdf, _) = typeset(&mut warm, &memory, "$a+b=c$");
    let _ = pdf_to_svg(&pdf);
    drop(warm);
    println!("warm-up equation in the parent: {:.2} ms", ms(t));
    let t = Instant::now();
    let template = prepared_engine(&fmt);
    println!("engine to fork from, built once: {:.2} ms", ms(t));

    let (mut round, mut tex, mut svg) = (Vec::new(), Vec::new(), Vec::new());
    let all = Instant::now();
    for n in 300..330 {
        let t = Instant::now();
        let mut fds = [0i32; 2];
        unsafe { assert_eq!(libc::pipe(fds.as_mut_ptr()), 0) };
        let pid = unsafe { libc::fork() };
        if pid == 0 {
            // Child: typeset with the inherited engine, render, report, exit.
            unsafe { libc::close(fds[0]) };
            let mut engine = template;
            let (pdf, tt) = typeset(&mut engine, &memory, &formula(n));
            let t1 = Instant::now();
            let out = pdf_to_svg(&pdf);
            let st = ms(t1);
            let mut msg = format!("{tt} {st} {}\n", out.len()).into_bytes();
            msg.extend_from_slice(&out);
            let mut off = 0;
            while off < msg.len() {
                let w = unsafe { libc::write(fds[1], msg[off..].as_ptr() as *const c_void, msg.len() - off) };
                assert!(w > 0); off += w as usize;
            }
            unsafe { libc::_exit(0) };
        }
        unsafe { libc::close(fds[1]) };
        let mut buf = Vec::new();
        let mut chunk = [0u8; 65536];
        loop {
            let r = unsafe { libc::read(fds[0], chunk.as_mut_ptr() as *mut c_void, chunk.len()) };
            if r <= 0 { break; }
            buf.extend_from_slice(&chunk[..r as usize]);
        }
        unsafe { libc::close(fds[0]); libc::waitpid(pid, std::ptr::null_mut(), 0) };
        round.push(ms(t));
        let head_end = buf.iter().position(|&b| b == b'\n').expect("child sent nothing");
        let head = String::from_utf8_lossy(&buf[..head_end]).to_string();
        let mut it = head.split(' ');
        tex.push(it.next().unwrap().parse::<f64>().unwrap());
        svg.push(it.next().unwrap().parse::<f64>().unwrap());
        assert!(buf[head_end + 1..].windows(4).any(|w| w == b"<svg"), "no SVG");
        if n == 300 { std::fs::write("fork-first.svg", &buf[head_end + 1..]).unwrap(); }
    }
    println!("30 equations, forked one after the other: {:.2} ms in total", ms(all));
    println!("  typeset in the child (median): {:.2} ms", median(&mut tex));
    println!("  PDF -> SVG in the child (median): {:.2} ms", median(&mut svg));
    println!("  round trip per equation, fork included (median): {:.2} ms, max {:.2}",
             median(&mut round.clone()), round.iter().cloned().fold(0.0, f64::max));
}
