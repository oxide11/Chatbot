# Ingestion Queue, Storage Stats & About Update

## Overview
Three features: (1) a batch ingestion pipeline that queues multiple files, (2) storage statistics displayed in Settings, and (3) an updated About section reflecting all the work done since 1.0.

---

## 1. Batch Ingestion Queue

**Current state:** `fileImporter` allows only one file (`allowsMultipleSelection: false`), and `ingestDocument(from:)` processes a single document at a time. If you import while processing, it overwrites the state.

**Changes:**

### KnowledgeBaseStore.swift
- Add an `IngestionJob` struct: `id: UUID`, `url: URL`, `fileName: String`, `status: .queued | .processing | .completed | .failed(String)`
- Add observable properties:
  - `var ingestionQueue: [IngestionJob] = []`
  - `var currentJobIndex: Int?`
  - `var overallProgress: Double` (across all files)
- New `queueDocuments(from urls: [URL])` method:
  - Creates `IngestionJob` for each URL
  - Appends to queue
  - If not already processing, kicks off `processQueue()`
- New `private func processQueue()`:
  - Iterates through queued jobs sequentially
  - Updates `currentJobIndex`, per-job status, and `overallProgress`
  - Calls existing `ingestDocument(from:)` logic per job (refactored into a helper)
  - On failure, marks job as failed and continues to next
- Refactor `ingestDocument(from:)` → `private func ingestSingleDocument(job: IngestionJob)` (core logic stays the same)
- Add `func cancelQueue()` to clear remaining queued jobs
- Add `func removeJob(_ job: IngestionJob)` to dismiss completed/failed items

### ContentView.swift — KnowledgeBaseListView
- Change `allowsMultipleSelection: false` → `true`
- Update the `.fileImporter` result handler to call `queueDocuments(from: urls)`
- Replace the single `ProgressView` with an **ingestion queue section** showing:
  - Each job with its name, status icon (queued/spinning/checkmark/error), and progress
  - Overall progress bar at top when processing
  - A "Cancel" button to stop remaining jobs
  - Failed jobs show error message with a dismiss button

---

## 2. Storage Statistics in Settings

**What to track:**
- **Conversations:** count + estimated size (from UserDefaults data)
- **Memories:** count + estimated size (from UserDefaults data)
- **Knowledge Bases:** count + total file size (already stored as `kb.fileSize`) + total chunks + on-disk chunk storage size
- **Embeddings:** whether available, model ID
- **Total on-disk usage**

### KnowledgeBaseStore.swift
- Add computed properties:
  - `var totalOriginalFileSize: Int64` — sum of `kb.fileSize`
  - `var totalChunkCount: Int` — sum of `kb.chunkCount`
  - `var totalChunkStorageSize: Int64` — sum of actual chunk JSON file sizes on disk

### ConversationStore (ChatViewModel.swift)
- Add computed properties:
  - `var conversationDataSize: Int` — size of encoded conversations data
  - `var memoryDataSize: Int` — size of encoded memories data
  - `var totalStorageSize: Int64` — conversations + memories + knowledge base chunk files

### ContentView.swift — SettingsView
- Add a new **"Storage"** section between "Data" and "About":
  - Row: "Conversations" — `X conversations · XX KB`
  - Row: "Memories" — `X memories · XX KB`
  - Row: "Knowledge Bases" — `X documents · Y chunks · XX MB`
  - Row: "Embeddings" — Status indicator (available/downloading/unavailable)
  - Footer: "Total: XX MB on device"
- Use `ByteCountFormatter` for human-readable sizes (already used in KB list)

---

## 3. Updated About Section

### AppInfo
- Bump to `version = "1.1.0"`, `build = "2"`

### AboutView — Key Features
Add new features reflecting recent work:
- **Semantic Search** (magnifyingglass.circle) — "On-device BERT embeddings for intelligent document and memory retrieval"
- **Agentic Workers** (person.2.badge.gearshape) — "Delegate specialized tasks to AI worker personas"
- **Batch Import** (square.and.arrow.down.on.square) — "Queue multiple documents for processing at once"

### AboutView — Changelog
Add a new `ChangelogEntry` for version 1.1.0:
- Semantic embeddings with NLContextualEmbedding (BERT)
- Batch document ingestion queue
- Storage statistics in Settings
- Agentic Manager-Worker system with built-in presets
- Optimized prompts and context management
- Session prewarming for faster responses
- Smaller chunks (600 chars) for better retrieval
- Cross-device embedding portability

### AboutView — Technical Section
- Add row: "Embeddings" → "NLContextualEmbedding (BERT)"
- Add row: "Min. OS" → "iOS 26 / macOS 26"

---

## Files Modified
1. **KnowledgeBaseStore.swift** — IngestionJob model, queue logic, storage stats
2. **ChatViewModel.swift** — Storage size computed properties on ConversationStore
3. **ContentView.swift** — Queue UI in KnowledgeBaseListView, Storage section in SettingsView, updated AboutView + AppInfo

## Build Target
Zero errors, zero warnings.
