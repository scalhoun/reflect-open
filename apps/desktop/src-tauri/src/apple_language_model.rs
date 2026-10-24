//! On-device text generation through Apple's Foundation Models framework.

use crate::error::{AppError, AppResult};
use serde_json::Value;

#[cfg(any(target_os = "macos", target_os = "ios"))]
mod native {
    use super::*;
    use std::ffi::{CStr, CString, c_char};
    unsafe extern "C" {
        fn reflect_language_status() -> *mut c_char;
        fn reflect_language_generate(request: *const c_char) -> *mut c_char;
        fn reflect_language_cancel(id: *const c_char);
        fn reflect_language_free(response: *mut c_char);
    }
    unsafe fn response(pointer: *mut c_char) -> AppResult<Value> {
        if pointer.is_null() {
            return Err(AppError::io("Apple AI could not allocate its response"));
        }
        let json = unsafe { CStr::from_ptr(pointer) }
            .to_string_lossy()
            .into_owned();
        unsafe { reflect_language_free(pointer) };
        let value: Value =
            serde_json::from_str(&json).map_err(|error| AppError::parse(error.to_string()))?;
        if let Some(message) = value.get("error").and_then(Value::as_str) {
            return Err(AppError::io(message));
        }
        Ok(value)
    }
    pub fn status() -> AppResult<Value> {
        unsafe { response(reflect_language_status()) }
    }
    pub fn generate(request: Value) -> AppResult<Value> {
        let json = CString::new(request.to_string())
            .map_err(|_| AppError::parse("Invalid Apple AI request"))?;
        unsafe { response(reflect_language_generate(json.as_ptr())) }
    }
    pub fn cancel(id: &str) -> AppResult<()> {
        let id = CString::new(id).map_err(|_| AppError::parse("Invalid Apple AI request id"))?;
        unsafe { reflect_language_cancel(id.as_ptr()) };
        Ok(())
    }
}

/// Check on-device model readiness without sending data or downloading a model.
#[tauri::command]
pub async fn apple_language_status() -> AppResult<Value> {
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    {
        tauri::async_runtime::spawn_blocking(native::status)
            .await
            .map_err(|error| AppError::io(error.to_string()))?
    }
    #[cfg(not(any(target_os = "macos", target_os = "ios")))]
    {
        Ok(
            serde_json::json!({"available": false, "contextWindow": 4096, "message": "Apple local AI requires macOS or iOS with Apple Intelligence."}),
        )
    }
}

/// Generate text or a deferred host tool call. No network provider is used.
#[tauri::command]
pub async fn apple_language_generate(request: Value) -> AppResult<Value> {
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    {
        tauri::async_runtime::spawn_blocking(move || native::generate(request))
            .await
            .map_err(|error| AppError::io(error.to_string()))?
    }
    #[cfg(not(any(target_os = "macos", target_os = "ios")))]
    {
        let _ = request;
        Err(AppError::io(
            "Apple local AI is unavailable on this platform.",
        ))
    }
}

/// Cancel the generation task for a request owned by this webview.
#[tauri::command]
pub fn apple_language_cancel(id: String) -> AppResult<()> {
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    {
        native::cancel(&id)
    }
    #[cfg(not(any(target_os = "macos", target_os = "ios")))]
    {
        let _ = id;
        Ok(())
    }
}

#[cfg(all(test, any(target_os = "macos", target_os = "ios")))]
mod tests {
    use super::*;
    #[test]
    fn availability_crosses_the_swift_bridge() {
        let status = native::status().expect("Apple AI status must return through Swift");
        assert!(status["available"].is_boolean());
        assert!(status["contextWindow"].as_u64().unwrap_or(0) > 0);
    }
}
