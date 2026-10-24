# Apple on-device chat with deferred tool calls

Verified 2026-10-24 using Xcode 27.1, Apple Swift 6.4, and the local macOS 27 SDK. Only synthetic note data was used. No application code or user notes were touched.

## Proven behavior

The native `SystemLanguageModel.default` reported `available` with `contextSize == 4096`. A dynamically declared `Tool` with `Arguments = GeneratedContent` received a genuine model-generated `searchNotes` call, recorded its arguments, and threw a deliberate deferred-tool error. Catching `LanguageModelSession.ToolCallError` returned control to the host. A second, fresh session replayed explicit instructions, the original prompt, the tool call, and fake note results. It answered the original question from those results. This proves the native tool workflow needed by a host-managed AI SDK tool loop.

Observed output:

```text
FIRST_REQUEST_CALLS [searchNotes {"query": "Project Aurora launch date"}]
SECOND_REQUEST_ANSWER Project Aurora launches on November 12, 2026.
CALL_COUNT 1
```

The executable probe is `/tmp/reflect-apple-chat-probe.swift`. Reproduce with:

```sh
rtk proxy xcrun swiftc -parse-as-library /tmp/reflect-apple-chat-probe.swift -o /tmp/reflect-apple-chat-probe
rtk proxy /tmp/reflect-apple-chat-probe
```

Apple documents `ToolCallError` wrapping a tool's underlying error, default transcript rollback, and constructing a new session from transcript entries. [Tool calling](https://developer.apple.com/documentation/foundationmodels/expanding-generation-with-tool-calling), [Transcript](https://developer.apple.com/documentation/foundationmodels/transcript).

## Deferring a dynamic tool to the host

```swift
enum DeferredTool: Error { case handoff }

actor Capture {
    private var calls: [Transcript.ToolCall] = []
    func record(name: String, args: GeneratedContent) {
        calls.append(.init(id: UUID().uuidString, toolName: name, arguments: args))
    }
    func get() -> [Transcript.ToolCall] { calls }
}

struct DynamicTool: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String
    let name: String
    let description: String
    let parameters: GenerationSchema
    let capture: Capture

    func call(arguments: GeneratedContent) async throws -> String {
        await capture.record(name: name, args: arguments)
        throw DeferredTool.handoff
    }
}
```

Catch only `LanguageModelSession.ToolCallError` whose `underlyingError is DeferredTool`. Propagate other errors. The default rollback removed the failed request's prompt and calls from `session.transcript`, leaving just instructions. Capture tool arguments inside `call` before throwing; do not depend on the failed session transcript retaining them. The generated-content arguments expose `jsonString` for transport to the AI SDK. [Tool](https://developer.apple.com/documentation/foundationmodels/tool), [ToolCallError](https://developer.apple.com/documentation/foundationmodels/languagemodelsession/toolcallerror).

## Replaying results in a fresh request

This construction ran successfully, using the captured calls and a synthetic JSON result:

```swift
func text(_ value: String) -> Transcript.Segment { .text(.init(content: value)) }
var entries: [Transcript.Entry] = [
    .instructions(.init(
        segments: [text(instructions)],
        toolDefinitions: [.init(tool: tool)]
    )),
    .prompt(.init(segments: [text(question)])),
    .toolCalls(.init(calls))
]
for call in calls {
    entries.append(.toolOutput(.init(
        id: call.id,
        toolName: call.toolName,
        segments: [text(resultJSON)]
    )))
}
let next = LanguageModelSession(
    model: SystemLanguageModel.default,
    tools: [tool],
    transcript: Transcript(entries: entries)
)
let response = try await next.respond(
    to: "Answer the original question using the searchNotes result already supplied. Do not call any more tools.",
    options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 128)
)
```

The continuation prompt above is part of the tested probe. The tool result's id reused the corresponding call id. Preserve tool calls and results together when trimming history. Tools can run concurrently; the capture must be concurrency-safe, and deferred-tool handling must distinguish the intentional handoff from real failures. The probe proved a single tool call and continuation, not a parallel multi-tool batch. [Tool output](https://developer.apple.com/documentation/foundationmodels/transcript/tooloutput), [Transcript](https://developer.apple.com/documentation/foundationmodels/transcript).

## Dynamic schema compatibility

The documented Swift schema route works:

```swift
let root = DynamicGenerationSchema(name: "searchNotesArguments", properties: [
    .init(name: "query", description: "Search keywords", schema: .init(type: String.self))
])
let schema = try GenerationSchema(root: root, dependencies: [])
```

Direct `JSONDecoder().decode(GenerationSchema.self, ...)` on a conventional object JSON Schema failed with `DecodingError.keyNotFound` for `x-order`. Apple's encoded object schema contained:

```json
{
  "title": "searchNotesArguments",
  "type": "object",
  "properties": {"query": {"type": "string", "description": "Search keywords"}},
  "required": ["query"],
  "additionalProperties": false,
  "x-order": ["query"]
}
```

Adding `x-order: ["query"]` and the title to the ordinary schema decoded successfully. Using that decoded schema in the actual tool also completed the two-request workflow. This establishes compatibility for the tested object/string schema only. Prefer recursive conversion to `DynamicGenerationSchema` for the production schema subset, or normalize and validate Apple's extra requirements deliberately. Arbitrary JSON Schema keywords are not proven compatible. `GenerationSchema` is `Codable`, but that is not a guarantee it accepts every external JSON Schema dialect. [DynamicGenerationSchema](https://developer.apple.com/documentation/foundationmodels/dynamicgenerationschema), [GenerationSchema](https://developer.apple.com/documentation/foundationmodels/generationschema).

## Token counting and deployment versions

The installed Swift interface exposes `SystemLanguageModel.tokenCount(for:)` overloads for prompts, instructions, tools, schemas, and collections of transcript entries from iOS/macOS 26.4. `contextSize` is available from 26.0 and is back-deployed with a 4096-token value before OS 27. Check the actual model property rather than hardcoding it for newer systems. Count the complete reconstructed transcript, including tool definitions and outputs, plus any continuation prompt, then reserve space for generated output before each request. Apple recommends trimming transcript entries or using a new session when the window fills. [Managing the context window](https://developer.apple.com/documentation/foundationmodels/managing-the-context-window), [SystemLanguageModel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel).

Measured with the successful probe:

| Item | Tokens |
| --- | ---: |
| Tool definition | 260 |
| Instructions alone | 72 |
| Reconstructed transcript before continuation prompt | 381 |
| Second request actual input usage | 410 |
| Second request output usage | 21 |

`Response.usage` and `GenerationOptions.toolCallingMode` are OS 27 APIs in the inspected SDK. The probe used neither explicit required/disallowed tool mode nor response usage as a dependency of the handoff mechanism. Guard usage inspection with availability checks if targeting 26.4. `GeneratedContent`, dynamic schemas, transcript constructors, tool deferral, and session rehydration have 26.0 availability in this interface. Runtime behavior was exercised on OS 27 only.

Local interface inspected:

```text
/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/FoundationModels.framework/Versions/A/Modules/FoundationModels.swiftmodule/arm64e-apple-macos.swiftinterface
```
