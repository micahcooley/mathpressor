// build.rs — compile the Slint UI description into Rust bindings and keep
// libmathpressor.so in sync with the Zig build output.

use std::path::PathBuf;

fn main() {
    slint_build::compile("ui/appwindow.slint").expect("Slint compile failed");

    // Automatically run `zig build` so the .so is always fresh.
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")); // gui/
    let zig_root = manifest_dir.parent().expect("expected parent of gui/");

    let zig_so = zig_root.join("zig-out/lib/libmathpressor.so");
    let zig_bin = zig_root.join("zig-out/bin/mathpressor");

    // Build the Zig project — prefer `zig` from PATH, fall back to the
    // conventional install location.
    let status = std::process::Command::new("zig")
        .args(["build", "-Doptimize=ReleaseFast"])
        .current_dir(zig_root)
        .status()
        .or_else(|_| {
            std::process::Command::new("/usr/local/bin/zig")
                .args(["build", "-Doptimize=ReleaseFast"])
                .current_dir(zig_root)
                .status()
        })
        .expect("zig build failed — is `zig` installed?");
    assert!(status.success(), "zig build returned non-zero");

    // Copy .so and binary next to the Rust binary (target/{debug,release}/).
    let out_dir = PathBuf::from(std::env::var("OUT_DIR").unwrap());
    // OUT_DIR layout: target/<profile>/build/<crate-hash>/out
    // Three parents up → target/<profile>/
    let target_profile = out_dir
        .parent().unwrap()
        .parent().unwrap()
        .parent().unwrap();

    if zig_so.exists() {
        let dst = target_profile.join("libmathpressor.so");
        std::fs::copy(&zig_so, &dst)
            .unwrap_or_else(|e| panic!("copy {zig_so:?} → {dst:?}: {e}"));
    }
    if zig_bin.exists() {
        let dst = target_profile.join("mathpressor");
        std::fs::copy(&zig_bin, &dst)
            .unwrap_or_else(|e| panic!("copy {zig_bin:?} → {dst:?}: {e}"));
    }

    // Re-run this script when any Zig source changes.
    println!("cargo:rerun-if-changed=../src/main.zig");
    println!("cargo:rerun-if-changed=../src/container.zig");
    println!("cargo:rerun-if-changed=../src/vm.zig");
    println!("cargo:rerun-if-changed=../src/translator.zig");
    println!("cargo:rerun-if-changed=../src/abi.zig");
    println!("cargo:rerun-if-changed=../build.zig");
}
