import AVFoundation
import Foundation
import Speech

private final class SpeechResponse: @unchecked Sendable {
  var json = ""
}

// Rust calls these functions on its blocking pool. Waiting here keeps Swift's
// async model and result lifetimes inside Swift without blocking the UI thread.
@available(macOS 26.0, iOS 26.0, *)
private func speechResponse(
  _ operation: @escaping @Sendable () async throws -> [String: Any]
) -> UnsafeMutablePointer<CChar>? {
  let response = SpeechResponse()
  let finished = DispatchSemaphore(value: 0)
  Task.detached {
    let payload: [String: Any]
    do {
      payload = try await operation()
    } catch {
      payload = ["error": error.localizedDescription]
    }
    let data = try! JSONSerialization.data(withJSONObject: payload)
    response.json = String(decoding: data, as: UTF8.self)
    finished.signal()
  }
  finished.wait()
  return strdup(response.json)
}

private struct SpeechFailure: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

@available(macOS 26.0, iOS 26.0, *)
private func supportedLocale(_ identifier: String) async throws -> Locale {
  guard SpeechTranscriber.isAvailable else {
    throw SpeechFailure(message: "Apple on-device transcription is not supported on this device.")
  }
  guard
    let locale = await SpeechTranscriber.supportedLocale(
      equivalentTo: Locale(identifier: identifier))
  else {
    throw SpeechFailure(message: "Apple transcription does not support the selected language.")
  }
  return locale
}

@_cdecl("reflect_speech_status")
public func reflectSpeechStatus(_ localePointer: UnsafePointer<CChar>) -> UnsafeMutablePointer<
  CChar
>? {
  guard #available(macOS 26.0, iOS 26.0, *) else {
    return strdup("{\"available\":false,\"installed\":false,\"locales\":[],\"message\":\"Apple transcription requires macOS 26 or iOS 26.\"}")
  }
  let identifier = String(cString: localePointer)
  return speechResponse {
    let locales = await SpeechTranscriber.supportedLocales.map(\.identifier).sorted()
    do {
      let locale = try await supportedLocale(identifier)
      let installed = await SpeechTranscriber.installedLocales.contains(locale)
      return ["available": true, "installed": installed, "locales": locales, "message": NSNull()]
    } catch {
      return [
        "available": false, "installed": false, "locales": locales,
        "message": error.localizedDescription,
      ]
    }
  }
}

@available(macOS 26.0, iOS 26.0, *)
private func transcribeFile(_ path: String, identifier: String) async throws -> String {
  let locale = try await supportedLocale(identifier)
  let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
  if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
  {
    try await installation.downloadAndInstall()
  }
  let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
  let analyzer = SpeechAnalyzer(modules: [transcriber])
  do {
    async let transcript: String = transcriber.results.reduce("") { text, result in
      text + String(result.text.characters)
    }
    if let lastSample = try await analyzer.analyzeSequence(from: file) {
      try await analyzer.finalizeAndFinish(through: lastSample)
    } else {
      await analyzer.cancelAndFinishNow()
    }
    return try await transcript.trimmingCharacters(in: .whitespacesAndNewlines)
  } catch {
    await analyzer.cancelAndFinishNow()
    throw error
  }
}

@_cdecl("reflect_speech_transcribe")
public func reflectSpeechTranscribe(
  _ pathPointer: UnsafePointer<CChar>,
  _ localePointer: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>? {
  guard #available(macOS 26.0, iOS 26.0, *) else {
    return strdup("{\"error\":\"Apple transcription requires macOS 26 or iOS 26.\"}")
  }
  let path = String(cString: pathPointer)
  let identifier = String(cString: localePointer)
  return speechResponse {
    return ["text": try await transcribeFile(path, identifier: identifier)]
  }
}

@_cdecl("reflect_speech_free")
public func reflectSpeechFree(_ pointer: UnsafeMutablePointer<CChar>?) {
  free(pointer)
}
