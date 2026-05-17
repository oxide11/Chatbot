# Engram Backlog

This file tracks deferred work — features and polish items I've explicitly chosen to push past the current branch. Items are ordered roughly by leverage / cost ratio. New items go in the appropriate section; completed items move into the README's `Status` section, not here.

## Medium-leverage, medium-effort

- [ ] **Dynamic Island + Live Activity for import progress.** Show "Chunk 12 of 47 · 26%" on iPhone while a long PDF is in flight. Adds a Widget Extension target. Tap returns to the Imports sheet.
- [ ] **Stage Manager / multi-window on iPad.** Declare `UIApplicationSupportsMultipleScenes` and let the user open two chats side by side. App Group is already configured; just need the scene declaration and a per-scene `selectedConversationID`.
- [ ] **Scribble + Apple Pencil verification.** `TextField` should support Scribble by default but it's worth confirming on iPad with Pencil. Maybe add `.scribbleInteraction` modifiers explicitly.
- [ ] **Custom accent color.** `AccentColor` is the system blue. A tuned brand hue would tie the Liquid Glass styling together. Probably extracted from the bubble blue (`Color.userBubbleColor`).
- [ ] **Cross-sheet wiki page navigation from import detail.** `DocumentImportDetailView` lists the wiki pages an import produced but doesn't push into them — they live in a different sheet. Either hoist the wiki sheet to a shared root, or use a navigation router.
- [ ] **Two-pass wikilink resolution after extraction.** When chunk 5 references `[[Chunk 9 Topic]]`, the link target won't exist when chunk 5's page is saved. Final reconciliation pass would re-link orphans (`linkedPageIDs` field is already there).
- [ ] **`BGContinuedProcessingTask` for long imports.** Currently `BackgroundTask.run` gives ~30s. iOS 26's `BGContinuedProcessingTask` shows a system progress UI while a user-initiated job runs in the background; perfect for multi-hundred-page extractions. Needs `Info.plist` registration + capability.
- [ ] **Serialise simultaneous conversation auto-extracts.** Document imports are already serialised through `DocumentImporter.processQueue`. The remaining edge case is multiple chats rotating at the same time, each firing `extractKnowledge` in parallel — rare in practice but worth a single internal gate on `WikiEngine` to be safe under load.
- [ ] **Wiki page detail: source documents.** Show which imports / conversations a wiki page came from (via `sourceDocumentIDs` / `sourceConversationIDs`). Tap the source to open it.
- [ ] **Worker library polish.** The Workers list works but could surface "active in this conversation" hints more clearly.
- [ ] **Search improvements.** Sidebar search is title + message-content substring. A semantic search across messages and wiki pages (using existing embeddings) would be more useful.
- [ ] **Link in-chat imports to the conversation.** The chat composer's paperclip / drag-drop already routes through `DocumentImporter`, but the resulting wiki pages aren't yet tagged with `sourceConversationIDs` — only the document is. Threading the active conversation id through `extractKnowledgeFromDocument` would make the Sources section on a page show both "from `PDF.pdf`" and "while chatting in `Thread Title`".
- [ ] **App Shortcuts surface.** Already have Siri intents. Could expose more (Open Wiki Page, Run Lint, Import Document) and add Spotlight donation for chats.

## High-leverage, high-effort

- [ ] **iCloud sync for wiki pages.** `CKSyncEngine` + the existing SwiftData schema. Sync wiki pages, conversations, and worker profiles across iPhone / iPad / Mac. Big feature; would justify a `2.1.0` minor.
- [ ] **App icon redesign + launch screen polish.** Current icon and launch screen are auto-generated.
- [ ] **Localization.** English-only right now. Even just `en-GB` plus `fr` doubles reach. String catalogs are configured; just need translations.
- [ ] **Provider key validation on disconnect.** When a key is revoked or expires, the next chat fails with a 401 — clearer surfacing in the chat itself ("Key invalid → Settings → Providers → Anthropic → Test Connection").
- [ ] **Wiki export.** Export the entire wiki as a folder of markdown files with `[[wikilinks]]` preserved. Pairs well with iCloud sync.
- [ ] **Citation rendering in chat.** When the model uses a wiki page or document chunk, render the source as a small chip at the end of the bubble that taps into the source.
- [ ] **Provider cost ledger.** Surface estimated tokens / cost per remote provider call so users can see how much an extraction cost.

## iOS / iPadOS specific polish

- [ ] **Dynamic Type AX5 audit.** Layout breaks at large text sizes need defensive `Layout` containers (FlowLayout already helps; but chat bubbles, wiki page lists, settings rows haven't been tested at AX5).
- [ ] **VoiceOver navigation through chat bubbles.** Most icon buttons have labels now; rotor / swipe through messages should announce role + content cleanly.
- [ ] **Compact iPhone chat detail.** Margins and bubble sizing optimised for iPhone SE-class widths.
- [ ] **External keyboard hints.** Discoverability HUD already shows shortcuts; long-press `⌘` to verify all expected shortcuts surface with intelligible names.
- [ ] **Accessibility shortcuts.** `accessibilityCustomAction` on chat bubbles for Copy / Edit / Share without invoking the context menu.

## Diagnostics and tooling

- [ ] **Logging viewer.** Surface `AppLogger` output from inside the app for live debugging without Xcode attached.
- [ ] **Provider request log.** Optional ring buffer of recent provider calls + errors, accessible from Settings → Providers → \<provider\> → Request Log.
- [ ] **Import statistics.** Settings → Storage already shows imported docs total. Add per-import token cost estimates if the extraction provider was remote.
- [ ] **In-app crash reporting.** Tiny self-hosted ring buffer that catches uncaught NSExceptions and surfaces at next launch.

## Discoverability

- [ ] **Onboarding sheet.** First-launch walkthrough explaining the wiki concept, where chat fits, how to import a document, and how to switch providers.
- [ ] **"Try this" suggestions.** Empty chat could surface 3-4 example prompts based on what's in the wiki ("Ask about [[Adam Optimizer]]" / "Summarise [recent doc]").
- [ ] **Help / FAQ link in About.** Static markdown in-app for common questions (why does extraction take so long? what happens if I delete a wiki page?).
