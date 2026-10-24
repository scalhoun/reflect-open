//! On-device transcription of durable graph recordings using Apple's Speech framework.

use serde::{Deserialize, Serialize};
use tauri::State;

use crate::error::{AppError, AppResult};
use crate::fs::{GraphState, resolve_in_graph, root_for_generation};

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AppleSpeechStatus {
    available: bool,
    installed: bool,
    locales: Vec<String>,
    message: Option<String>,
}

#[cfg(any(target_os = "macos", target_os = "ios"))]
mod native {
    use std::ffi::{CStr, CString, c_char};

    use super::*;

    unsafe extern "C" {
        fn reflect_speech_status(locale: *const c_char) -> *mut c_char;
        fn reflect_speech_transcribe(path: *const c_char, locale: *const c_char) -> *mut c_char;
        fn reflect_speech_free(response: *mut c_char);
    }

    fn argument(value: &str) -> AppResult<CString> {
        CString::new(value).map_err(|_| AppError::io("Speech arguments cannot contain null bytes"))
    }

    // Swift allocates every response with strdup. Copy before returning ownership
    // to Swift, including when the JSON represents an error.
    unsafe fn response(pointer: *mut c_char) -> AppResult<serde_json::Value> {
        if pointer.is_null() {
            return Err(AppError::io(
                "Apple transcription could not allocate its response",
            ));
        }
        let json = unsafe { CStr::from_ptr(pointer) }
            .to_string_lossy()
            .into_owned();
        unsafe { reflect_speech_free(pointer) };
        let value: serde_json::Value =
            serde_json::from_str(&json).map_err(|error| AppError::parse(error.to_string()))?;
        if let Some(message) = value.get("error").and_then(serde_json::Value::as_str) {
            return Err(AppError::io(message));
        }
        Ok(value)
    }

    pub fn status(locale: &str) -> AppResult<AppleSpeechStatus> {
        let locale = argument(locale)?;
        let value = unsafe { response(reflect_speech_status(locale.as_ptr())) }?;
        serde_json::from_value(value).map_err(|error| AppError::parse(error.to_string()))
    }

    pub fn transcribe(path: &str, locale: &str) -> AppResult<String> {
        let path = argument(path)?;
        let locale = argument(locale)?;
        let value = unsafe { response(reflect_speech_transcribe(path.as_ptr(), locale.as_ptr())) }?;
        value
            .get("text")
            .and_then(serde_json::Value::as_str)
            .map(str::to_owned)
            .ok_or_else(|| AppError::parse("Apple transcription returned no text"))
    }
}

/// Check hardware, OS and language support without requesting microphone access or downloading models.
#[tauri::command]
pub async fn apple_speech_status(locale: String) -> AppResult<AppleSpeechStatus> {
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    {
        tauri::async_runtime::spawn_blocking(move || native::status(&locale))
            .await
            .map_err(|error| AppError::io(error.to_string()))?
    }

    #[cfg(not(any(target_os = "macos", target_os = "ios")))]
    {
        let _ = locale;
        Ok(AppleSpeechStatus {
            available: false,
            installed: false,
            locales: Vec::new(),
            message: Some("Apple transcription requires macOS 26 or iOS 26.".into()),
        })
    }
}

/// Transcribe a generation-pinned recording on-device; the audio never enters the webview or a cloud provider.
#[tauri::command]
pub async fn apple_speech_transcribe(
    path: String,
    locale: String,
    generation: u64,
    state: State<'_, GraphState>,
) -> AppResult<String> {
    let root = root_for_generation(&state, generation)?;
    if std::path::Path::new(&path).parent() != Some(std::path::Path::new("audio-memos")) {
        return Err(AppError::traversal(
            "Only audio memo recordings can be transcribed",
        ));
    }
    let resolved = resolve_in_graph(&root, &path)?;
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    {
        let text = tauri::async_runtime::spawn_blocking(move || {
            native::transcribe(&resolved.to_string_lossy(), &locale)
        })
        .await
        .map_err(|error| AppError::io(error.to_string()))??;
        root_for_generation(&state, generation)?;
        Ok(text)
    }
    #[cfg(not(any(target_os = "macos", target_os = "ios")))]
    {
        let _ = (resolved, locale);
        Err(AppError::io(
            "Apple transcription requires macOS 26 or iOS 26.",
        ))
    }
}

#[cfg(all(test, any(target_os = "macos", target_os = "ios")))]
mod tests {
    use super::*;

    #[test]
    fn native_availability_crosses_the_swift_async_bridge() {
        let status =
            native::status("en-US").expect("Apple speech status must return through Swift");
        assert!(status.available || status.message.is_some());
    }
}
