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
        swift_rs::SwiftLinker::new("10.15")
            .with_ios("16.0")
            .with_package("ReflectSpeech", "apple-speech")
            .link();
    }
    tauri_build::build()
}
