//! Files-picker grants for user-selected folders outside the app's own iCloud container.

use crate::error::{AppError, AppResult};

/// Coordinate a note read with its iOS document provider. Other hosts keep their existing IO path.
pub(crate) fn coordinate_read<T>(
    path: &std::path::Path,
    operation: impl FnOnce() -> AppResult<T>,
) -> AppResult<T> {
    coordinate(path, false, operation)
}

/// Keep a checked read/merge/write transaction inside one provider write reservation.
pub(crate) fn coordinate_write<T>(
    path: &std::path::Path,
    operation: impl FnOnce() -> AppResult<T>,
) -> AppResult<T> {
    coordinate(path, true, operation)
}

fn coordinate<T>(
    path: &std::path::Path,
    writing: bool,
    operation: impl FnOnce() -> AppResult<T>,
) -> AppResult<T> {
    #[cfg(target_os = "ios")]
    {
        use block2::StackBlock;
        use objc2_foundation::{
            NSFileCoordinator, NSFileCoordinatorReadingOptions, NSFileCoordinatorWritingOptions,
            NSString, NSURL,
        };
        use std::cell::RefCell;
        use std::ptr::NonNull;
        let coordinator = NSFileCoordinator::new();
        let url = NSURL::fileURLWithPath(&NSString::from_str(&path.to_string_lossy()));
        let operation = RefCell::new(Some(operation));
        let outcome = RefCell::new(None);
        let mut error = None;
        {
            let accessor = StackBlock::new(|coordinated_url: NonNull<NSURL>| {
                let coordinated_path = unsafe { coordinated_url.as_ref() }
                    .path()
                    .map(|value| std::path::PathBuf::from(value.to_string()));
                if coordinated_path.as_deref() != Some(path) {
                    outcome.replace(Some(Err(AppError::io(
                        "This note moved while its provider was granting access. Reopen it and try again.",
                    ))));
                    return;
                }
                if let Some(operation) = operation.borrow_mut().take() {
                    outcome.replace(Some(operation()));
                }
            });
            if writing {
                coordinator.coordinateWritingItemAtURL_options_error_byAccessor(
                    &url,
                    NSFileCoordinatorWritingOptions::ForReplacing,
                    Some(&mut error),
                    &accessor,
                );
            } else {
                coordinator.coordinateReadingItemAtURL_options_error_byAccessor(
                    &url,
                    NSFileCoordinatorReadingOptions::empty(),
                    Some(&mut error),
                    &accessor,
                );
            }
        }
        if let Some(error) = error {
            return Err(AppError::io(error.localizedDescription().to_string()));
        }
        outcome.into_inner().unwrap_or_else(|| {
            Err(AppError::io(
                "The document provider did not grant access to this note.",
            ))
        })
    }
    #[cfg(not(target_os = "ios"))]
    {
        let _ = (path, writing);
        operation()
    }
}

#[cfg(target_os = "ios")]
mod native {
    use super::*;
    use std::ffi::{CStr, c_char};
    use std::sync::OnceLock;
    use tauri::{Emitter, Manager};

    unsafe extern "C" {
        fn reflect_folder_pick() -> *mut c_char;
        fn reflect_folder_resolve() -> *mut c_char;
        fn reflect_folder_finish(commit: bool) -> *mut c_char;
        fn reflect_folder_release() -> *mut c_char;
        fn reflect_folder_free(response: *mut c_char);
        fn reflect_folder_watch(callback: extern "C" fn(*const c_char)) -> *mut c_char;
    }

    static APP: OnceLock<tauri::AppHandle> = OnceLock::new();

    extern "C" fn changed(root: *const c_char) {
        if root.is_null() {
            return;
        }
        let Some(app) = APP.get() else { return };
        let root = unsafe { CStr::from_ptr(root) }.to_string_lossy();
        let state = app.state::<crate::fs::GraphState>();
        let Ok(current) = crate::fs::current_root(&state) else {
            return;
        };
        let selected = std::path::Path::new(root.as_ref());
        let current = current.canonicalize().unwrap_or(current);
        let selected = selected
            .canonicalize()
            .unwrap_or_else(|_| selected.to_path_buf());
        if current == selected {
            let _ = app.emit("index:reconcile", ());
        }
    }

    pub fn initialize(app: tauri::AppHandle) -> AppResult<()> {
        let _ = APP.set(app);
        unsafe { response(reflect_folder_watch(changed)) }.map(|_| ())
    }

    unsafe fn response(pointer: *mut c_char) -> AppResult<serde_json::Value> {
        if pointer.is_null() {
            return Err(AppError::io("Could not allocate the folder response"));
        }
        let json = unsafe { CStr::from_ptr(pointer) }
            .to_string_lossy()
            .into_owned();
        unsafe { reflect_folder_free(pointer) };
        let value: serde_json::Value =
            serde_json::from_str(&json).map_err(|error| AppError::parse(error.to_string()))?;
        if let Some(error) = value.get("error").and_then(serde_json::Value::as_str) {
            return Err(AppError::io(error));
        }
        Ok(value)
    }

    pub fn pick() -> AppResult<serde_json::Value> {
        unsafe { response(reflect_folder_pick()) }
    }
    pub fn resolve() -> AppResult<serde_json::Value> {
        unsafe { response(reflect_folder_resolve()) }
    }
    pub fn finish(commit: bool) -> AppResult<()> {
        unsafe { response(reflect_folder_finish(commit)) }.map(|_| ())
    }
    pub fn release() -> AppResult<()> {
        unsafe { response(reflect_folder_release()) }.map(|_| ())
    }
}

/// Present the Files directory picker and hold its scoped access until the choice is committed or cancelled.
#[tauri::command]
pub async fn mobile_folder_pick(app: tauri::AppHandle) -> AppResult<serde_json::Value> {
    #[cfg(target_os = "ios")]
    {
        tauri::async_runtime::spawn_blocking(move || {
            native::initialize(app)?;
            native::pick()
        })
        .await
        .map_err(|error| AppError::io(error.to_string()))?
    }
    #[cfg(not(target_os = "ios"))]
    {
        let _ = app;
        Err(AppError::io(
            "Choosing a Files folder is available in the iPhone app.",
        ))
    }
}

/// Resolve the stored security-scoped bookmark and reacquire access before opening the graph.
#[tauri::command]
pub async fn mobile_folder_resolve(app: tauri::AppHandle) -> AppResult<serde_json::Value> {
    #[cfg(target_os = "ios")]
    {
        tauri::async_runtime::spawn_blocking(move || {
            native::initialize(app)?;
            native::resolve()
        })
        .await
        .map_err(|error| AppError::io(error.to_string()))?
    }
    #[cfg(not(target_os = "ios"))]
    {
        let _ = app;
        Ok(serde_json::json!({"path": null}))
    }
}

/// Persist the pending permission only after the graph opens; cancellation preserves the previous bookmark.
#[tauri::command]
pub async fn mobile_folder_finish(commit: bool) -> AppResult<()> {
    #[cfg(target_os = "ios")]
    {
        tauri::async_runtime::spawn_blocking(move || native::finish(commit))
            .await
            .map_err(|error| AppError::io(error.to_string()))?
    }
    #[cfg(not(target_os = "ios"))]
    {
        let _ = commit;
        Ok(())
    }
}

/// Release live folder grants after switching to built-in storage; the bookmark remains available for re-selection.
#[tauri::command]
pub async fn mobile_folder_release() -> AppResult<()> {
    #[cfg(target_os = "ios")]
    {
        tauri::async_runtime::spawn_blocking(native::release)
            .await
            .map_err(|error| AppError::io(error.to_string()))?
    }
    #[cfg(not(target_os = "ios"))]
    {
        Ok(())
    }
}
