import Foundation
import UIKit
import UniformTypeIdentifiers

private struct FolderFailure: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

private final class FolderResponse: @unchecked Sendable {
  var json = ""
}

private typealias FolderChangeCallback = @convention(c) (UnsafePointer<CChar>) -> Void

private final class FolderPresenter: NSObject, NSFilePresenter {
  let root: URL
  let changed: FolderChangeCallback
  let presentedItemOperationQueue: OperationQueue
  var presentedItemURL: URL? { root }

  init(root: URL, changed: @escaping FolderChangeCallback) {
    self.root = root
    self.changed = changed
    presentedItemOperationQueue = OperationQueue()
    presentedItemOperationQueue.maxConcurrentOperationCount = 1
    super.init()
  }

  private func notify(_ url: URL) {
    let relative = url.pathComponents.dropFirst(root.pathComponents.count)
    guard !relative.contains(".reflect"), !relative.contains(".git") else { return }
    root.path.withCString { changed($0) }
  }

  func presentedSubitemDidAppear(at url: URL) { notify(url) }
  func presentedSubitemDidChange(at url: URL) { notify(url) }
  func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { notify(oldURL); notify(newURL) }
  func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping (Error?) -> Void) {
    completionHandler(nil)
    notify(url)
  }
}

// The C entry points run on Rust's blocking pool. UIKit and scoped URL
// ownership remain on the main actor while the picker waits for the user.
private func folderResponse(
  _ operation: @escaping @Sendable () async throws -> [String: Any]
) -> UnsafeMutablePointer<CChar>? {
  let response = FolderResponse()
  let finished = DispatchSemaphore(value: 0)
  Task.detached {
    defer { finished.signal() }
    let payload: [String: Any]
    do { payload = try await operation() }
    catch { payload = ["error": error.localizedDescription] }
    if let data = try? JSONSerialization.data(withJSONObject: payload) {
      response.json = String(decoding: data, as: UTF8.self)
    } else {
      response.json = "{\"error\":\"Could not encode the folder selection.\"}"
    }
  }
  finished.wait()
  return strdup(response.json)
}

@MainActor
private final class FolderAccess: NSObject, UIDocumentPickerDelegate {
  static let shared = FolderAccess()
  private let bookmarkKey = "ReflectSelectedNotesFolderBookmark"
  private var activeURL: URL?
  private var pendingURL: URL?
  private var pendingBookmark: Data?
  private var continuation: CheckedContinuation<[String: Any], Error>?
  private var changed: FolderChangeCallback?
  private var presenter: FolderPresenter?

  func setChangeCallback(_ callback: @escaping FolderChangeCallback) { changed = callback }

  private func watch(_ url: URL) {
    if let presenter { NSFileCoordinator.removeFilePresenter(presenter) }
    guard let changed else { return }
    let presenter = FolderPresenter(root: url, changed: changed)
    self.presenter = presenter
    NSFileCoordinator.addFilePresenter(presenter)
  }

  func pick() async throws -> [String: Any] {
    guard continuation == nil else { throw FolderFailure(message: "A folder picker is already open.") }
    finish(commit: false)
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    guard var presenter = scenes.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController else {
      throw FolderFailure(message: "The app is not ready to present the Files picker.")
    }
    while let presented = presenter.presentedViewController { presenter = presented }
    return try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
      let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
      picker.delegate = self
      picker.allowsMultipleSelection = false
      picker.title = "Choose your Reflect notes folder"
      presenter.present(picker, animated: true)
    }
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let continuation else { return }
    self.continuation = nil
    guard let url = urls.first else { continuation.resume(returning: ["path": NSNull()]); return }
    guard url.startAccessingSecurityScopedResource() else {
      continuation.resume(throwing: FolderFailure(message: "Access to the selected folder was not granted."))
      return
    }
    do {
      let coordinator = NSFileCoordinator()
      var coordinationError: NSError?
      var bookmark: Data?
      var bookmarkError: Error?
      coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
        do { bookmark = try coordinatedURL.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) }
        catch { bookmarkError = error }
      }
      if let coordinationError { throw coordinationError }
      if let bookmarkError { throw bookmarkError }
      guard let bookmark else { throw FolderFailure(message: "Could not remember the selected folder.") }
      pendingURL = url
      pendingBookmark = bookmark
      continuation.resume(returning: ["path": url.path])
    } catch {
      url.stopAccessingSecurityScopedResource()
      continuation.resume(throwing: error)
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    continuation?.resume(returning: ["path": NSNull()])
    continuation = nil
  }

  func resolve() throws -> [String: Any] {
    if let activeURL { return ["path": activeURL.path] }
    guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return ["path": NSNull()] }
    var stale = false
    let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    guard url.startAccessingSecurityScopedResource() else {
      throw FolderFailure(message: "Choose your notes folder again to restore access.")
    }
    do {
      if stale {
        let refreshed = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(refreshed, forKey: bookmarkKey)
      }
      activeURL = url
      watch(url)
      return ["path": url.path]
    } catch {
      url.stopAccessingSecurityScopedResource()
      throw error
    }
  }

  func finish(commit: Bool) {
    if commit, let pendingURL, let pendingBookmark {
      UserDefaults.standard.set(pendingBookmark, forKey: bookmarkKey)
      activeURL?.stopAccessingSecurityScopedResource()
      activeURL = pendingURL
      watch(pendingURL)
    } else {
      pendingURL?.stopAccessingSecurityScopedResource()
    }
    pendingURL = nil
    pendingBookmark = nil
  }

  func release() {
    if let presenter { NSFileCoordinator.removeFilePresenter(presenter) }
    presenter = nil
    finish(commit: false)
    activeURL?.stopAccessingSecurityScopedResource()
    activeURL = nil
  }
}

@_cdecl("reflect_folder_pick")
public func reflectFolderPick() -> UnsafeMutablePointer<CChar>? {
  folderResponse { try await FolderAccess.shared.pick() }
}

@_cdecl("reflect_folder_watch")
public func reflectFolderWatch(_ callback: @escaping @convention(c) (UnsafePointer<CChar>) -> Void) -> UnsafeMutablePointer<CChar>? {
  folderResponse {
    await FolderAccess.shared.setChangeCallback(callback)
    return ["ok": true]
  }
}

@_cdecl("reflect_folder_resolve")
public func reflectFolderResolve() -> UnsafeMutablePointer<CChar>? {
  folderResponse { try await FolderAccess.shared.resolve() }
}

@_cdecl("reflect_folder_finish")
public func reflectFolderFinish(_ commit: Bool) -> UnsafeMutablePointer<CChar>? {
  folderResponse {
    await FolderAccess.shared.finish(commit: commit)
    return ["ok": true]
  }
}

@_cdecl("reflect_folder_release")
public func reflectFolderRelease() -> UnsafeMutablePointer<CChar>? {
  folderResponse {
    await FolderAccess.shared.release()
    return ["ok": true]
  }
}

@_cdecl("reflect_folder_free")
public func reflectFolderFree(_ pointer: UnsafeMutablePointer<CChar>?) { free(pointer) }
