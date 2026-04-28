//
//  OpenAIProvider.swift
//  ChatBot
//
//  Streaming chat client for the OpenAI Chat Completions API.
//  https://platform.openai.com/docs/api-reference/chat
//
//  SSE wire format with `data: [DONE]` terminator. Yields raw text
//  deltas (not cumulative). Maps HTTP / decoding / rate-limit failures
//  into ChatProviderError, mirroring AnthropicProvider so callers see
//  consistent error shapes regardless of which provider is bound to a
//  task.
//

import Foundation

struct OpenAIProvider: ChatProvider {
    let id: ChatProviderID = .openAI
    let apiKey: String
    let model: String
    let endpoint: URL
    let urlSession: URLSession

    init(
        apiKey: String,
        model: String = "gpt-4.1",
        endpoint: URL = URL(string: "https://api.openai.com/v1/chat/completions")!,
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
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body = OpenAIRequestBody(
            model: model,
            messages: messagesPayload(history: history, systemPrompt: systemPrompt),
            stream: true,
            temperature: options.temperature,
            max_completion_tokens: max(1, options.maxOutputTokens)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        request.httpBody = try encoder.encode(body)
        return request
    }

    /// Build the messages array. OpenAI accepts the system role inline, so we
    /// prepend the system prompt as the first message rather than threading
    /// it through a separate field. `ProviderMessage.system` entries from
    /// `history` are also routed to system role.
    private func messagesPayload(
        history: [ProviderMessage],
        systemPrompt: String?
    ) -> [OpenAIAPIMessage] {
        var out: [OpenAIAPIMessage] = []
        if let trimmed = systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmed.isEmpty {
            out.append(OpenAIAPIMessage(role: "system", content: trimmed))
        }
        for msg in history {
            switch msg.role {
            case .system:
                out.append(OpenAIAPIMessage(role: "system", content: msg.content))
            case .user:
                out.append(OpenAIAPIMessage(role: "user", content: msg.content))
            case .assistant:
                out.append(OpenAIAPIMessage(role: "assistant", content: msg.content))
            }
        }
        return out
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
            // OpenAI uses retry-after as either seconds or HTTP-date; we
            // treat it as seconds for parity with Anthropic.
            let retry = headers?.value(forHTTPHeaderField: "retry-after").flatMap(Double.init)
            throw ChatProviderError.rateLimited(retryAfterSeconds: retry)
        }
        throw ChatProviderError.invalidResponse(status: status, message: message)
    }

    private func parseErrorMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let env = try? JSONDecoder().decode(OpenAIErrorEnvelope.self, from: data) {
            return env.error.message
        }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    // MARK: - SSE

    /// OpenAI streams `data: {json}` events terminated by a literal
    /// `data: [DONE]` line. We yield each non-nil `choices[0].delta.content`
    /// as a text delta. Errors that arrive mid-stream as `data: {"error":…}`
    /// abort the stream with a ChatProviderError.
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

            if payload == "[DONE]" { return }
            guard let data = payload.data(using: .utf8) else { continue }

            // Mid-stream error envelope.
            if let env = try? decoder.decode(OpenAIErrorEnvelope.self, from: data) {
                throw ChatProviderError.invalidResponse(status: 0, message: env.error.message)
            }

            if let chunk = try? decoder.decode(OpenAIStreamChunk.self, from: data),
               let text = chunk.choices.first?.delta.content,
               !text.isEmpty {
                sawAnyDelta = true
                continuation.yield(text)
            }
        }

        // 200 OK but no text deltas — surface it instead of finishing empty.
        if !sawAnyDelta {
            throw ChatProviderError.invalidResponse(
                status: 200,
                message: "Stream ended without any text content."
            )
        }
    }
}

// MARK: - Wire types

private struct OpenAIRequestBody: Encodable {
    let model: String
    let messages: [OpenAIAPIMessage]
    let stream: Bool
    let temperature: Double
    let max_completion_tokens: Int
}

private struct OpenAIAPIMessage: Encodable {
    let role: String
    let content: String
}

private struct OpenAIStreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
        }
        let delta: Delta
    }
    let choices: [Choice]
}

private struct OpenAIErrorEnvelope: Decodable {
    struct ErrorBody: Decodable {
        let message: String
        let type: String?
        let code: String?
    }
    let error: ErrorBody
}

// MARK: - Helpers

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
