//! Records the compiler version and build profile so `version` can report them.
use std::process::Command;

fn main() {
    let rustc = std::env::var("RUSTC").unwrap_or_else(|_| "rustc".to_string());
    let version = Command::new(rustc)
        .arg("--version")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| {
            // "rustc 1.96.0 (hash date)" -> "rustc 1.96.0"
            s.split_whitespace().take(2).collect::<Vec<_>>().join(" ")
        })
        .unwrap_or_else(|| "rustc unknown".to_string());
    println!("cargo:rustc-env=PQ_RUSTC_VERSION={version}");
    let profile = std::env::var("PROFILE").unwrap_or_else(|_| "unknown".to_string());
    println!("cargo:rustc-env=PQ_BUILD_PROFILE={profile}");
    let opt = std::env::var("OPT_LEVEL").unwrap_or_default();
    println!("cargo:rustc-env=PQ_BUILD_FLAGS=opt-level={opt}");
    println!("cargo:rerun-if-changed=build.rs");
}
