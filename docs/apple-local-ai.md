# Apple local AI and iPhone folders

In Settings → AI providers, add **Apple (on-device)** and choose it in the chat model picker. No API key or server URL is needed. It uses `SystemLanguageModel.default` through Apple's Foundation Models framework. The provider never switches to a cloud model when local generation is unavailable.

Apple Intelligence must be enabled and its model ready on supported hardware running macOS 26.4 or iOS 26.4 or later. Build the native app with Xcode 27 or newer. The browser preview reports the native provider as unavailable.

Chat uses the existing note tools and private-note checks. Apple chat uses lexical search, avoiding a query embedding request. Private notes remain excluded. The model accepts text only; attachments and structured response requests fail with an explicit explanation. Answers are delivered after each native generation completes.

The local model has a small context window, currently 4096 tokens. Apple chat returns smaller note batches and bodies, allows at most three retrieval rounds followed by an answer, and counts the native transcript before every generation. Old conversation turns and oversized tool results are shortened as needed, keeping tool calls paired with their results. Truncated results are labeled. If the question and instructions still do not fit, chat asks for a shorter request. This provider is best for short questions about a few notes.

Audio transcription is a separate setting under Audio memos. Choose Apple there to use the local Speech framework. Selecting an Apple chat provider alone does not change the transcription engine.

## Existing iCloud Drive folders on iPhone

Use **Choose an existing notes folder** during setup or in Settings → Graphs. Select the same notes folder used on the Mac through the system Files picker. This works without an app-owned iCloud container or paid Apple Developer membership.

The app stores the folder permission as a native bookmark after successfully opening the graph. It restores that permission on launch instead of saving an absolute container path. If access is lost, setup asks for the folder again. Existing notes are opened in place. Files manages their syncing.

A free Personal Team can sign the main app for development. App-owned iCloud containers, App Groups, and the share/widget targets require different provisioning. Keep personal signing identifiers and generated project overrides in ignored local files. Free development profiles expire and need another build and install.

## Verification

Run the focused TypeScript tests for `apple-language-model`, the chat engine, note tools, provider configuration, and mobile onboarding. Run `pnpm check`, `pnpm build`, and `cargo test -p reflect-open`. Schema conversion tests run with:

```sh
rtk proxy xcrun swift test --package-path apps/desktop/src-tauri/apple-language-model
```

On an Apple Intelligence Mac, a synthetic note smoke test verified native search → note read → cited answer through the AI SDK tool loop with all five real note tools and zero HTTP requests. Physical iPhone installation and folder restoration must also be tested on a paired device.
