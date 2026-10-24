import Foundation
import FoundationModels

private struct ChatFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct SchemaType: Decodable, Sendable {
    let name: String
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) { name = value }
        else {
            let values = try container.decode([String].self)
            guard let value = values.first(where: { $0 != "null" }) else {
                throw ChatFailure(message: "Unsupported null-only tool schema.")
            }
            name = value
        }
    }
}
final class Schema: Decodable, Sendable {
    let type: SchemaType?
    let description: String?
    let properties: [String: Schema]?
    let required: [String]?
    let items: Schema?
    let anyOf: [Schema]?
    let enumValues: [String]?
    let minItems: Int?
    let maxItems: Int?
    enum CodingKeys: String, CodingKey {
        case type, description, properties, required, items, anyOf, minItems, maxItems
        case enumValues = "enum"
    }
}

private struct ToolSpec: Decodable, Sendable {
    let name: String
    let description: String
    let parameters: Schema
}
private struct Call: Codable, Sendable {
    let id: String
    let name: String
    let input: String
}
private struct Message: Decodable, Sendable {
    let role: String
    let text: String
    let calls: [Call]
    let outputs: [ToolOutput]
}
private struct ToolOutput: Decodable, Sendable {
    let id: String
    let name: String
    let text: String
}
private struct Request: Decodable, Sendable {
    let id: String
    let messages: [Message]
    let tools: [ToolSpec]
    let toolChoice: String
    let maxOutputTokens: Int
}
private struct Reply: Encodable {
    let text: String
    let calls: [Call]
    let inputTokens: Int
    let outputTokens: Int?
}

@available(macOS 26.4, iOS 26.4, *)
func dynamicSchema(_ schema: Schema, name: String) throws -> DynamicGenerationSchema {
    if let choices = schema.anyOf {
        guard let value = choices.first(where: { $0.type?.name != "null" }) else {
            throw ChatFailure(message: "Apple AI cannot use an empty tool schema.")
        }
        return try dynamicSchema(value, name: name)
    }
    if let values = schema.enumValues {
        return DynamicGenerationSchema(name: name, anyOf: values)
    }
    switch schema.type?.name {
    case "object":
        let properties = try (schema.properties ?? [:]).sorted { $0.key < $1.key }.map { key, value in
            DynamicGenerationSchema.Property(
                name: key, description: value.description,
                schema: try dynamicSchema(value, name: name + "_" + key),
                isOptional: !(schema.required ?? []).contains(key))
        }
        return DynamicGenerationSchema(name: name, description: schema.description, properties: properties)
    case "array":
        guard let items = schema.items else { throw ChatFailure(message: "Missing tool array schema.") }
        return DynamicGenerationSchema(arrayOf: try dynamicSchema(items, name: name + "_item"),
            minimumElements: schema.minItems, maximumElements: schema.maxItems)
    case "string": return DynamicGenerationSchema(type: String.self)
    case "integer": return DynamicGenerationSchema(type: Int.self)
    case "number": return DynamicGenerationSchema(type: Double.self)
    case "boolean": return DynamicGenerationSchema(type: Bool.self)
    default: throw ChatFailure(message: "This tool schema is not supported by Apple AI.")
    }
}

private enum DeferredTool: Error { case handoff }
@available(macOS 26.4, iOS 26.4, *)
private actor Capture {
    private var calls: [Call] = []
    func record(name: String, arguments: GeneratedContent) {
        calls.append(Call(id: UUID().uuidString, name: name, input: arguments.jsonString))
    }
    func get() -> [Call] { calls }
}
@available(macOS 26.4, iOS 26.4, *)
private struct HostTool: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String
    let name: String
    let description: String
    let parameters: GenerationSchema
    let capture: Capture
    func call(arguments: GeneratedContent) async throws -> String {
        try Task.checkCancellation()
        await capture.record(name: name, arguments: arguments)
        // The host runs the existing privacy-gated note tools, then replays their results.
        throw DeferredTool.handoff
    }
}

@available(macOS 26.4, iOS 26.4, *)
private func segment(_ value: String) -> Transcript.Segment { .text(.init(content: value)) }

@available(macOS 26.4, iOS 26.4, *)
private func entries(_ messages: [Message], tools: [HostTool], outputLimit: Int) throws -> [Transcript.Entry] {
    let instructions = messages.filter { $0.role == "system" }.map(\.text).joined(separator: "\n")
    var result: [Transcript.Entry] = [.instructions(.init(
        segments: [segment(instructions)], toolDefinitions: tools.map { .init(tool: $0) }))]
    for message in messages where message.role != "system" {
        switch message.role {
        case "user": result.append(.prompt(.init(segments: [segment(message.text)])))
        case "assistant":
            if !message.text.isEmpty {
                result.append(.response(.init(assetIDs: [], segments: [segment(message.text)])))
            }
            if !message.calls.isEmpty {
                let calls = try message.calls.map {
                    Transcript.ToolCall(id: $0.id, toolName: $0.name, arguments: try GeneratedContent(json: $0.input))
                }
                result.append(.toolCalls(.init(calls)))
            }
        case "tool":
            for output in message.outputs {
                let body = output.text.count > outputLimit
                    ? String(output.text.prefix(outputLimit)) + "\n[Tool result truncated to fit the local model. Narrow the request for more detail.]"
                    : output.text
                result.append(.toolOutput(.init(id: output.id, toolName: output.name, segments: [segment(body)])))
            }
        default: throw ChatFailure(message: "Unsupported message role for Apple AI.")
        }
    }
    return result
}

@available(macOS 26.4, iOS 26.4, *)
private func generate(_ request: Request) async throws -> Reply {
    try Task.checkCancellation()
    let model = SystemLanguageModel.default
    guard model.isAvailable else { throw ChatFailure(message: availabilityMessage(model)) }
    let capture = Capture()
    let tools = try request.tools.filter { _ in request.toolChoice != "none" }.map { spec in
        HostTool(name: spec.name, description: spec.description,
            parameters: try GenerationSchema(root: dynamicSchema(spec.parameters, name: spec.name + "Arguments"), dependencies: []),
            capture: capture)
    }
    var messages = request.messages
    var outputLimit = 3500
    let responseBudget = max(64, min(request.maxOutputTokens, 512))
    let continuation = request.messages.last?.role == "tool"
        ? "The tool calls above have already run. Use their results to answer the original user's question now, citing note titles. Do not repeat completed calls. Only use another tool if an essential fact is missing."
        : "Respond to the user's latest message."
    var transcript = try entries(messages, tools: tools, outputLimit: outputLimit)
    var count = try await model.tokenCount(for: transcript) + model.tokenCount(for: Prompt(continuation))
    while count + responseBudget + 128 > model.contextSize {
        try Task.checkCancellation()
        let userIndices = messages.indices.filter { messages[$0].role == "user" }
        if userIndices.count > 1 {
            messages.removeSubrange(userIndices[0]..<userIndices[1])
        } else if outputLimit > 400, messages.contains(where: { !$0.outputs.isEmpty }) {
            outputLimit /= 2
        } else {
            throw ChatFailure(message: "This request is too long for Apple's on-device model. Start a new chat or ask about fewer notes.")
        }
        transcript = try entries(messages, tools: tools, outputLimit: outputLimit)
        count = try await model.tokenCount(for: transcript) + model.tokenCount(for: Prompt(continuation))
    }
    let session = LanguageModelSession(model: model, tools: tools, transcript: Transcript(entries: transcript))
    var options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: responseBudget)
    if #available(macOS 27, iOS 27, *) {
        options.toolCallingMode = request.toolChoice == "none" ? .disallowed : request.toolChoice == "required" ? .required : .allowed
    }
    do {
        let response = try await session.respond(to: continuation, options: options)
        try Task.checkCancellation()
        let outputTokens: Int?
        if #available(macOS 27, iOS 27, *) { outputTokens = response.usage.output.totalTokenCount }
        else { outputTokens = nil }
        return Reply(text: response.content, calls: [], inputTokens: count, outputTokens: outputTokens)
    } catch let error as LanguageModelSession.ToolCallError {
        guard error.underlyingError is DeferredTool else { throw error }
        try Task.checkCancellation()
        return Reply(text: "", calls: await capture.get(), inputTokens: count, outputTokens: nil)
    }
}

@available(macOS 26.4, iOS 26.4, *)
private func availabilityMessage(_ model: SystemLanguageModel) -> String {
    switch model.availability {
    case .available: return "Apple Intelligence is ready on this device."
    case .unavailable(.deviceNotEligible): return "This device does not support Apple Intelligence."
    case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in system Settings to use Apple local AI."
    case .unavailable(.modelNotReady): return "Apple Intelligence is still downloading its on-device model. Try again when it is ready."
    default: return "Apple Intelligence is currently unavailable on this device."
    }
}

private final class TaskRegistry: @unchecked Sendable {
    static let shared = TaskRegistry()
    private let lock = NSLock()
    private var tasks: [String: Task<Void, Never>] = [:]
    private var cancelledBeforeStart: Set<String> = []
    func start(id: String, operation: @escaping @Sendable () async -> Void) {
        lock.lock()
        tasks[id] = Task.detached {
            await operation()
            self.finish(id: id)
        }
        if cancelledBeforeStart.remove(id) != nil { tasks[id]?.cancel() }
        lock.unlock()
    }
    private func finish(id: String) {
        lock.lock(); tasks.removeValue(forKey: id); lock.unlock()
    }
    func cancel(id: String) {
        lock.lock()
        if let task = tasks[id] { task.cancel() }
        else {
            if cancelledBeforeStart.count >= 128 { cancelledBeforeStart.removeAll() }
            cancelledBeforeStart.insert(id)
        }
        lock.unlock()
    }
}
private final class ResultBox: @unchecked Sendable {
    var json = "{}"
}
private func encoded(_ value: some Encodable) throws -> String {
    String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
}
private func errorJSON(_ error: Error) -> String {
    let message = error is CancellationError ? "Apple AI request cancelled." : error.localizedDescription
    let data = (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data("{}".utf8)
    return String(decoding: data, as: UTF8.self)
}

@_cdecl("reflect_language_status")
public func reflectLanguageStatus() -> UnsafeMutablePointer<CChar>? {
    if #available(macOS 26.4, iOS 26.4, *) {
        let model = SystemLanguageModel.default
        let data = try? JSONSerialization.data(withJSONObject: [
            "available": model.isAvailable, "message": availabilityMessage(model), "contextWindow": model.contextSize
        ])
        return strdup(String(decoding: data ?? Data("{}".utf8), as: UTF8.self))
    }
    return strdup("{\"available\":false,\"contextWindow\":4096,\"message\":\"Apple local AI requires macOS 26.4 or iOS 26.4 and Apple Intelligence.\"}")
}

@_cdecl("reflect_language_generate")
public func reflectLanguageGenerate(_ json: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    do {
        let request = try JSONDecoder().decode(Request.self, from: Data(String(cString: json).utf8))
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        TaskRegistry.shared.start(id: request.id) {
            defer { semaphore.signal() }
            do {
                if #available(macOS 26.4, iOS 26.4, *) { box.json = try await encoded(generate(request)) }
                else { throw ChatFailure(message: "Apple local AI requires macOS 26.4 or iOS 26.4.") }
            } catch { box.json = errorJSON(error) }
        }
        semaphore.wait()
        return strdup(box.json)
    } catch { return strdup(errorJSON(error)) }
}

@_cdecl("reflect_language_cancel")
public func reflectLanguageCancel(_ id: UnsafePointer<CChar>) {
    TaskRegistry.shared.cancel(id: String(cString: id))
}
@_cdecl("reflect_language_free")
public func reflectLanguageFree(_ response: UnsafeMutablePointer<CChar>?) { free(response) }
