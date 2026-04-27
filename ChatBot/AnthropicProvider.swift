//
//  AnthropicProvider.swift
//  ChatBot
//
//  Streaming chat client for the Anthropic Messages API.
//  https://docs.anthropic.com/en/api/messages
//
//  Implements the SSE wire format. Yields raw text deltas (not cumulative
//  content). Maps HTTP / decoding / rate-limit failures into ChatProviderError.
//

import Foundation

struct AnthropicProvider: ChatProvider {
    let id: ChatProviderID = .anthropic
    let apiKey: String
    let model: String
    let endpoint: URL
    let urlSession: URLSession

    init(
        apiKey: String,
        model: String = "claude-sonnet-4-6",
        endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!,
        urlSession: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint
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
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let messages = sanitize(history: history)
        let body = AnthropicRequestBody(
            model: model,
            max_tokens: max(1, options.maxOutputTokens),
            stream: true,
            system: systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            messages: messages,
            temperature: options.temperature
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        request.httpBody = try encoder.encode(body)
        return request
    }

    /// Anthropic requires the conversation start with a user turn and that
    /// user/assistant turns alternate. Drop any system messages that ended up
    /// in `history` (system prompt is sent separately) and merge consecutive
    /// turns from the same role.
    private func sanitize(history: [ProviderMessage]) -> [AnthropicAPIMessage] {
        var cleaned: [AnthropicAPIMessage] = []
        for msg in history where msg.role != .system {
            let role = (msg.role == .user) ? "user" : "assistant"
            if let last = cleaned.last, last.role == role {
                cleaned[cleaned.count - 1] = AnthropicAPIMessage(
                    role: role,
                    content: last.content + "\n\n" + msg.content
                )
            } else {
                cleaned.append(AnthropicAPIMessage(role: role, content: msg.content))
            }
        }
        // The first message must be from user. If it isn't, prepend a benign one.
        if cleaned.first?.role != "user" {
            cleaned.insert(AnthropicAPIMessage(role: "user", content: "Continue."), at: 0)
        }
        return cleaned
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

        if status == 429 {
            let retry = headers?.value(forHTTPHeaderField: "retry-after").flatMap(Double.init)
            throw ChatProviderError.rateLimited(retryAfterSeconds: retry)
        }
        throw ChatProviderError.invalidResponse(status: status, message: message)
    }

    private func parseErrorMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let env = try? JSONDecoder().decode(AnthropicErrorEnvelope.self, from: data) {
            return env.error.message
        }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    // MARK: - SSE

    /// Parse the SSE stream by routing on the JSON `type` field inside each
    /// `data:` payload. We deliberately ignore `event:` markers — every
    /// data envelope from Anthropic carries its own `type`, and trusting
    /// the JSON means weird buffering / missing event lines can't silently
    /// produce empty replies.
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
            guard let data = payload.data(using: .utf8) else { continue }

            // Peek at type without committing to a full schema.
            let type = (try? decoder.decode(AnthropicEnvelopeType.self, from: data).type) ?? ""
            switch type {
            case "content_block_delta":
                if let event = try? decoder.decode(AnthropicDeltaEvent.self, from: data),
                   let text = event.delta.text {
                    sawAnyDelta = true
                    continuation.yield(text)
                }
            case "message_stop":
                return
            case "error":
                if let env = try? decoder.decode(AnthropicErrorEnvelope.self, from: data) {
                    throw ChatProviderError.invalidResponse(
                        status: 0,
                        message: env.error.message
                    )
                }
                throw ChatProviderError.invalidResponse(status: 0, message: "Stream error.")
            default:
                continue
            }
        }

        // 200 OK but no text — usually a streaming-mode issue. Surface it
        // instead of returning empty content so the chat doesn't appear
        // to hang or quietly fail.
        if !sawAnyDelta {
            throw ChatProviderError.invalidResponse(
                status: 200,
                message: "Stream ended without any text content."
            )
        }
    }
}

// MARK: - Wire types

private struct AnthropicRequestBody: Encodable {
    let model: String
    let max_tokens: Int
    let stream: Bool
    let system: String?
    let messages: [AnthropicAPIMessage]
    let temperature: Double
}

private struct AnthropicAPIMessage: Encodable {
    let role: String
    let content: String
}

private struct AnthropicEnvelopeType: Decodable {
    let type: String
}

private struct AnthropicDeltaEvent: Decodable {
    struct Delta: Decodable {
        let type: String?
        let text: String?
    }
    let type: String?
    let index: Int?
    let delta: Delta
}

private struct AnthropicErrorEnvelope: Decodable {
    struct ErrorBody: Decodable {
        let type: String
        let message: String
    }
    let type: String
    let error: ErrorBody
}

// MARK: - Helpers

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
