fn main() {
    for lib in ["poppler-glib", "cairo", "gobject-2.0", "glib-2.0"] {
        pkg_config::probe_library(lib).unwrap();
    }
}
