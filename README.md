# Engram

A private, on-device AI assistant for iPad, iPhone, Mac, and Vision Pro built around Apple Foundation Models and a personal LLM Wiki.

Engram keeps a structured wiki of everything you've discussed and ingested, so the model isn't starting from scratch on every turn. Conversations and imported documents become wiki pages; the wiki gets pulled back into context when it's relevant. Inspired by Andrej Karpathy's [LLM Wiki concept](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f).

## Features

- **On-device chat** via Apple's Foundation Models (~3B parameters, 4096-token context). Free, fast, private, works offline.
- **Bring-your-own-key remote providers** for higher-quality work: Anthropic (Claude) wired up; OpenAI and Gemini scaffolded. Keys stored in the iOS Keychain, never written to disk.
- **Per-task provider routing** — keep chat on-device while sending wiki extraction and lint review to Claude. Or vice versa. Each task can pick its own provider.
- **LLM Wiki**:
  - Pages auto-extracted from conversations after context rotation.
  - Documents (PDF, ePub, plain text, Markdown) imported and turned into structured wiki pages.
  - `[[wikilinks]]` between pages with tap-to-navigate.
  - Markdown + LaTeX math rendering in both chat and wiki via [SwiftMath](https://github.com/mgriebling/SwiftMath).
- **Wiki Health (lint)**:
  - Structural pass: broken links, orphans, dead-ends, duplicate candidates, stale pages, missing concepts.
  - Semantic pass (LLM): merge proposals, stub drafts for missing pages — every change requires explicit confirmation.
  - Optional daily background pass via `BGTaskScheduler`.
- **Workers** — specialised AI personas the assistant can delegate to (Manager-Worker pattern).
- **Knowledge Bases** — PDF / ePub / text ingestion with on-device BERT embeddings (NLContextualEmbedding) for hybrid BM25 + semantic retrieval.
- **Liquid Glass UI** — built for iPadOS 26's visual language: glass effects on prominent overlays, soft scroll-edge fades, drag indicators on sheets, light/dark adaptive throughout.
- **Cross-platform** — single codebase for iPadOS, iOS, macOS, visionOS.
- **Share Extension + Siri Shortcuts** for sending text into chats or memory from anywhere.

## Requirements

- iPadOS 26.2 / iOS 26.2 / macOS 26.2 / visionOS 26.2 or later.
- Apple Intelligence enabled on the device (chat path).
- Xcode 26.2 or later.

## Building

```sh
git clone https://github.com/oxide11/Chatbot.git
cd Chatbot
open ChatBot.xcodeproj
```

### Add the SwiftMath dependency

Engram uses SwiftMath for typeset math in chat and wiki pages. The package is referenced via `#if canImport(SwiftMath)`, so the project still builds without it (math falls back to a monospaced LaTeX badge), but you'll want the real renderer:

1. In Xcode: **File → Add Package Dependencies…**
2. Paste `https://github.com/mgriebling/SwiftMath`
3. **Up to Next Major** (1.7.0 or later)
4. Add to the **ChatBot** target.

### (Optional) Background lint

For the daily background lint pass to actually run, add the task identifier to the app's Info.plist:

1. **Project → ChatBot target → Info → Custom iOS Target Properties**
2. Add a new entry:
   - Key: `BGTaskSchedulerPermittedIdentifiers` (Array)
   - Item 0: `com.polygoncyber.Engram.wiki.lint` (String)

Without this, the lint feature still works as a foreground action — only the nightly background run is gated on the entitlement.

## Configuration

### Adding a remote provider

1. Open the app → **Settings → Providers → Anthropic** (or OpenAI / Gemini once those land).
2. Paste your API key. The key is stored in the iOS Keychain under the service `com.polygoncyber.Engram`.
3. Pick a model from the suggestions or paste a custom alias.
4. Tap **Test Connection**. A 16-token round-trip confirms key, model, and network all work end-to-end. Errors are surfaced verbatim.
5. Optionally set the provider as the **Default**, or pin it to specific tasks (Chat / Wiki Extraction / Wiki Lint Review) under **Settings → Routing**.

### Recommended hybrid setup

Keep chat on-device for privacy and speed; use Claude for the heavy lifting:

- **Routing → Chat**: Apple Intelligence
- **Routing → Wiki Extraction**: Claude
- **Routing → Wiki Lint Review**: Claude

Document import into the wiki then runs on Claude (much higher quality) while chat stays free, fast, and private.

## Architecture

```
┌────────────────┐     ┌────────────────┐     ┌────────────────┐
│  ChatViewModel │     │   WikiEngine   │     │   WikiLinter   │
│   (per-chat)   │     │ (extract+inj.) │     │ (health check) │
└────────┬───────┘     └────────┬───────┘     └────────┬───────┘
         │                      │                      │
         └──────────────────────┴──────────────────────┘
                                │
                       ┌────────▼─────────┐
                       │ ProviderRegistry │   ← per-task routing
                       │   + KeychainMgr  │
                       └────────┬─────────┘
                                │
              ┌─────────────────┼─────────────────┐
              ▼                 ▼                 ▼
   ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐
   │ FoundationModels│  │ AnthropicProvider│  │ OpenAI / Gemini │
   │  (on-device)    │  │  (SSE streaming)│  │   (scaffolded)  │
   └─────────────────┘  └─────────────────┘  └─────────────────┘
```

- **`ChatProvider`** protocol abstracts a streaming backend. `streamReply(history:systemPrompt:options:)` yields raw text deltas; `respond(...)` is a convenience wrapper that collects the stream.
- **`ProviderRegistry`** resolves the right provider for each task (chat / extraction / lint), reading credentials from `KeychainManager` and model overrides from `UserDefaults`.
- **SwiftData** for persistent storage: `SDWikiPage`, `SDKnowledgeBase`, `SDDocumentChunk`, `SDKnowledgeDomain`, `WorkerProfile`. `@ModelActor` wrappers (`WikiActor`, `KnowledgeBaseActor`) keep all mutations off the main actor.
- **`RichContentRenderer`** parses chat / wiki content into segments — markdown text, inline `$math$`, display `$$math$$`, fenced code blocks, `[[wikilinks]]` — and dispatches each to the right SwiftUI view.

## Privacy

- **Chat on Apple Intelligence**: nothing leaves the device.
- **Chat / extraction / lint on a remote provider**: only when you explicitly configure that provider with a key. Requests go directly from your device to the provider's API; no Engram backend in between.
- **Embeddings**: computed on-device with `NLContextualEmbedding` (BERT, 512-dim).
- **Keys**: stored in the iOS Keychain with `kSecAttrAccessibleAfterFirstUnlock`.
- **Documents**: kept on-device after import. Source files are retained so you can re-extract with a different model later.

## Status

Engram is under active development. Recent milestones:

- LLM Wiki replaces the legacy MemoryStore as the primary long-term knowledge surface.
- Document → Wiki extraction with paragraph-aware chunking, progress UI, and background continuation.
- Karpathy-style wiki lint with structural and semantic passes; human-in-the-loop merge UI.
- Multi-provider scaffolding + Anthropic streaming + per-task routing.
- Liquid Glass UI sweep with iOS 26 scroll edge effects.

In flight: removing Knowledge Domains, replacing Knowledge Bases with a simpler Document Importer, and wiring OpenAI + Gemini providers.

## License

Personal project. License TBD.
