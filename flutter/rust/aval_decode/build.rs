//! Build script: on Apple targets, compile the Objective-C VideoToolbox decode
//! backend into the staticlib and link the required system frameworks.
//!
//! The ObjC source (`src/vt/videotoolbox_decoder.m`) exposes a tiny C ABI
//! (`aval_vt_*`) that the Rust `VideoToolboxAdapter` (`src/adapter.rs`, also
//! Apple-gated) calls. On non-Apple targets this is a no-op and only the
//! software OpenH264 backend exists. See ARCHITECTURE.md §2(c).

use std::env;

fn main() {
    let target_vendor =
        env::var("CARGO_CFG_TARGET_VENDOR").unwrap_or_default();
    if target_vendor != "apple" {
        return;
    }

    let src = "src/vt/videotoolbox_decoder.m";
    println!("cargo:rerun-if-changed={src}");

    cc::Build::new()
        .file(src)
        // ARC manages the ObjC object; CoreFoundation/CoreMedia handles are
        // released explicitly (CFRelease) since CF types are not ARC-managed.
        .flag("-fobjc-arc")
        .compile("aval_vt");

    // Frameworks the decode path pulls in. On the macOS host cdylib build,
    // cargo applies these at link time directly; for the iOS staticlib they
    // must also be present in the final Xcode link (Runner OTHER_LDFLAGS).
    for framework in ["VideoToolbox", "CoreMedia", "CoreVideo", "CoreFoundation"] {
        println!("cargo:rustc-link-lib=framework={framework}");
    }
}
