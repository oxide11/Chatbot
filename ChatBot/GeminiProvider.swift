//
//  GeminiProvider.swift
//  ChatBot
//
//  Streaming chat client for Google's Generative Language API.
//  https://ai.google.dev/api/generate-content#method:-models.streamgeneratecontent
//
//  Differences from OpenAI / Anthropic worth knowing:
//  - The model id lives in the URL path, not the body.
//  - Roles are "user" and "model" (not "user" / "assistant"). Like
//    Anthropic, the conversation must start with user and alternate.
//  - The system prompt is a top-level `systemInstruction` object, not a
//    role in the contents array.
//  - With `?alt=sse` the wire format is the same `data: {json}` shape
//    as OpenAI but without a `[DONE]` terminator — the stream just ends.
//

import Foundation

struct GeminiProvider: ChatProvider {
    let id: ChatProviderID = .gemini
    let apiKey: String
    let model: String
    let baseURL: URL
    let urlSession: URLSession

    init(
        apiKey: String,
        model: String = "gemini-2.5-pro",
        baseURL: URL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
        urlSession: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
        self.urlSession = urlSession
    }

    func streamReply(
        history: [ProviderMessage],
        systemPrompt: String?,
        options: ProviderGenerationOptions
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try buildRequest(
                        history: history,
                        systemPrompt: systemPrompt,
                        options: options
                    )
                    let (bytes, response) = try await urlSession.bytes(for: request)

                    let http = response as? HTTPURLResponse
                    let status = http?.statusCode ?? 0
                    if !(200..<300).contains(status) {
                        try await throwForErrorBody(bytes: bytes, status: status, headers: http)
                        return
                    }

                    try await consumeSSE(bytes: bytes, continuation: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Request

    private func buildRequest(
        history: [ProviderMessage],
        systemPrompt: String?,
        options: ProviderGenerationOptions
    ) throws -> URLRequest {
        var request = URLRequest(url: endpointURL())
        request.httpMethod = "POST"
        // Auth via header keeps the key out of the URL (and out of any
        // logs that capture URLs but not headers).
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body = GeminiRequestBody(
            contents: contentsPayload(history: history),
            systemInstruction: systemInstruction(from: systemPrompt),
            generationConfig: GeminiGenerationConfig(
                temperature: options.temperature,
                maxOutputTokens: max(1, options.maxOutputTokens)
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        request.httpBody = try encoder.encode(body)
        return request
    }

    /// Build the streaming endpoint URL. The model id goes in the path
    /// (e.g. `models/gemini-2.5-pro:streamGenerateContent`) and we ask
    /// for `alt=sse` so the response is the same `data: {json}` line
    /// format we already parse for OpenAI.
    private func endpointURL() -> URL {
        // Tolerate both "gemini-2.5-pro" and "models/gemini-2.5-pro" — the
        // user might paste a fully-qualified id from the Google AI Studio
        // model picker.
        let pathSegment = model.hasPrefix("models/") ? model : "models/\(model)"
        let path = "\(pathSegment):streamGenerateContent"
        return baseURL
            .appending(path: path)
            .appending(queryItems: [URLQueryItem(name: "alt", value: "sse")])
    }

    /// Sanitise the conversation into Gemini's `contents` shape. Roles
    /// must be "user" or "model"; turns must alternate; the first turn
    /// must be a user. Drops any `system` entries from `history` (the
    /// system prompt is sent separately as `systemInstruction`).
    private func contentsPayload(history: [ProviderMessage]) -> [GeminiContent] {
        var cleaned: [GeminiContent] = []
        for msg in history where msg.role != .system {
            let role = (msg.role == .user) ? "user" : "model"
            if let last = cleaned.last, last.role == role {
                // Merge consecutive same-role turns — the API rejects
                // duplicates with INVALID_ARGUMENT.
                let mergedText = (last.parts.first?.text ?? "") + "\n\n" + msg.content
                cleaned[cleaned.count - 1] = GeminiContent(
                    role: role,
                    parts: [GeminiPart(text: mergedText)]
                )
            } else {
                cleaned.append(GeminiContent(role: role, parts: [GeminiPart(text: msg.content)]))
            }
        }
        if cleaned.first?.role != "user" {
            cleaned.insert(
                GeminiContent(role: "user", parts: [GeminiPart(text: "Continue.")]),
                at: 0
            )
        }
        return cleaned
    }

    private func systemInstruction(from prompt: String?) -> GeminiSystemInstruction? {
        guard let trimmed = prompt?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return GeminiSystemInstruction(parts: [GeminiPart(text: trimmed)])
    }

    // MARK: - Error parsing

    private func throwForErrorBody(
        bytes: URLSession.AsyncBytes,
        status: Int,
        headers: HTTPURLResponse?
    ) async throws {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > 64_000 { break }
        }
        let message = parseErrorMessage(from: data)

        if status == 401 || status == 403 {
            throw ChatProviderError.invalidAPIKey(id, detail: message)
        }
        if status == 429 {
            // Gemini returns retry-after as integer seconds when present.
            let retry = headers?.value(forHTTPHeaderField: "retry-after").flatMap(Double.init)
            throw ChatProviderError.rateLimited(retryAfterSeconds: retry)
        }
        throw ChatProviderError.invalidResponse(status: status, message: message)
    }

    private func parseErrorMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        // The non-stream error body is wrapped in an `error` object;
        // streaming errors arrive in the same shape but as a single
        // top-level object.
        if let env = try? JSONDecoder().decode(GeminiErrorEnvelope.self, from: data) {
            return env.error.message
        }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    // MARK: - SSE

    /// With `?alt=sse` Gemini emits `data: {json}` lines like OpenAI but
    /// without a `[DONE]` terminator — the stream just ends. Each chunk
    /// can carry text in `candidates[0].content.parts[*].text`. Mid-stream
    /// errors arrive as `data: {"error": {...}}` and abort the stream.
    private func consumeSSE(
        bytes: URLSession.AsyncBytes,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        let decoder = JSONDecoder()
        var sawAnyDelta = false

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line
                .dropFirst("data:".count)
                .trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty, let data = payload.data(using: .utf8) else { continue }

            // Mid-stream error envelope.
            if let env = try? decoder.decode(GeminiErrorEnvelope.self, from: data) {
                throw ChatProviderError.invalidResponse(status: 0, message: env.error.message)
            }

            if let chunk = try? decoder.decode(GeminiStreamChunk.self, from: data) {
                for candidate in chunk.candidates ?? [] {
                    for part in candidate.content?.parts ?? [] {
                        if let text = part.text, !text.isEmpty {
                            sawAnyDelta = true
                            continuation.yield(text)
                        }
                    }
                }
            }
        }

        if !sawAnyDelta {
            throw ChatProviderError.invalidResponse(
                status: 200,
                message: "Stream ended without any text content."
            )
        }
    }
}

// MARK: - Wire types

private struct GeminiRequestBody: Encodable {
    let contents: [GeminiContent]
    let systemInstruction: GeminiSystemInstruction?
    let generationConfig: GeminiGenerationConfig
}

private struct GeminiContent: Encodable {
    let role: String
    let parts: [GeminiPart]
}

private struct GeminiSystemInstruction: Encodable {
    let parts: [GeminiPart]
}

private struct GeminiPart: Encodable {
    let text: String
}

private struct GeminiGenerationConfig: Encodable {
    let temperature: Double
    let maxOutputTokens: Int
}

private struct GeminiStreamChunk: Decodable {
    struct Candidate: Decodable {
        struct Content: Decodable {
            struct Part: Decodable {
                let text: String?
            }
            let parts: [Part]?
            let role: String?
        }
        let content: Content?
        let finishReason: String?
    }
    let candidates: [Candidate]?
}

private struct GeminiErrorEnvelope: Decodable {
    struct ErrorBody: Decodable {
        let code: Int?
        let message: String
        let status: String?
    }
    let error: ErrorBody
}

// MARK: - Helpers

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
