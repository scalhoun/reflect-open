fn main() {
    #[cfg(target_os = "macos")]
    if matches!(
        std::env::var("CARGO_CFG_TARGET_OS").as_deref(),
        Ok("macos" | "ios")
    ) {
        println!("cargo:rerun-if-changed=apple-speech");
        if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
            // Rust does not add the search path for Swift's @rpath async runtime.
            println!("cargo:rustc-link-arg=-Wl,-rpath,/usr/lib/swift");
        }
        tauri_utils::build::link_apple_library("ReflectSpeech", "apple-speech");
    }
    tauri_build::build()
}
