use std::path::{Path, PathBuf};

/// Libraries the logos-delivery transport needs at runtime. `liblogosdelivery`
/// is what we link against; `librln` is its own dependency, resolved via the
/// `@loader_path`/`$ORIGIN` rpath it carries, so it has to travel beside it.
const MACOS_LIBS: [&str; 2] = ["liblogosdelivery.dylib", "librln.dylib"];
const LINUX_LIBS: [&str; 2] = ["liblogosdelivery.so", "librln.so"];

/// Where `tauri.conf.json` expects to find the libraries to bundle.
const STAGE_DIR: &str = "frameworks";

fn main() {
    if relocatable() {
        stage_native_libs();
    }
    tauri_build::build()
}

/// Mirrors `LOGOS_DELIVERY_RELOCATABLE` in the logos-delivery build script: in
/// relocatable mode the library keeps its `@rpath`/`$ORIGIN` name, so we have
/// to ship it inside the bundle and point the binary at it. In the default
/// (dev) mode the library is linked by absolute nix store path and there is
/// nothing to stage.
fn relocatable() -> bool {
    println!("cargo:rerun-if-env-changed=LOGOS_DELIVERY_RELOCATABLE");
    matches!(
        std::env::var("LOGOS_DELIVERY_RELOCATABLE").as_deref(),
        Ok("1") | Ok("true")
    )
}

fn stage_native_libs() {
    println!("cargo:rerun-if-env-changed=LOGOS_DELIVERY_LIB_DIR");

    let lib_dir = std::env::var("LOGOS_DELIVERY_LIB_DIR").expect(
        "LOGOS_DELIVERY_RELOCATABLE is set but LOGOS_DELIVERY_LIB_DIR is not; \
         it must point at the directory holding liblogosdelivery (e.g. the \
         output of `nix build .#logos-delivery` in the libchat repo)",
    );
    let lib_dir = PathBuf::from(&lib_dir)
        .canonicalize()
        .unwrap_or_else(|e| panic!("LOGOS_DELIVERY_LIB_DIR='{lib_dir}' is unusable: {e}"));

    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    let libs: &[&str] = match target_os.as_str() {
        "macos" => &MACOS_LIBS,
        "linux" => &LINUX_LIBS,
        other => panic!("unsupported OS for logos-delivery transport: {other}"),
    };

    let stage = Path::new(env!("CARGO_MANIFEST_DIR")).join(STAGE_DIR);
    std::fs::create_dir_all(&stage).unwrap_or_else(|e| panic!("create {}: {e}", stage.display()));

    for lib in libs {
        copy_writable(&lib_dir.join(lib), &stage.join(lib));
    }

    // The libraries record a relocatable name, so the binary needs an rpath to
    // resolve them from inside the bundle. On macOS that is `Contents/
    // Frameworks`, one level up from `Contents/MacOS`. Linux needs nothing
    // here: the soname is already `$ORIGIN`-relative, which ld.so expands
    // against the binary's own directory.
    if target_os == "macos" {
        println!("cargo:rustc-link-arg-bins=-Wl,-rpath,@executable_path/../Frameworks");
    }
}

/// Nix store files are read-only; restore owner write so a re-run can
/// overwrite the staged copy instead of failing on a stale read-only file.
fn copy_writable(src: &Path, dst: &Path) {
    use std::os::unix::fs::PermissionsExt;

    // Remove first: copying onto an existing read-only file fails.
    let _ = std::fs::remove_file(dst);
    std::fs::copy(src, dst)
        .unwrap_or_else(|e| panic!("copy {} -> {}: {e}", src.display(), dst.display()));
    std::fs::set_permissions(dst, std::fs::Permissions::from_mode(0o755)).unwrap();
    println!("cargo:rerun-if-changed={}", src.display());
}
