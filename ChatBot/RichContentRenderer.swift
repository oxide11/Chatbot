//
//  RichContentRenderer.swift
//  ChatBot
//
//  Renders mixed markdown + LaTeX math + fenced code blocks + wikilinks.
//  Used by chat message bubbles and wiki page detail views.
//

import SwiftUI

// MARK: - Segments

enum ContentSegment: Hashable {
    case text(String)
    case inlineMath(String)
    case displayMath(String)
    case codeBlock(language: String?, code: String)
}

// MARK: - Parser

enum RichContentParser {

    /// Tokenize a string into ordered segments. Display math (`$$…$$`) and
    /// fenced code (` ``` `) split into their own segments. Inline math
    /// (`$…$`) does too — for simplicity we render it as its own line rather
    /// than intermixing with surrounding text.
    static func parse(_ input: String) -> [ContentSegment] {
        var segments: [ContentSegment] = []
        var buffer = ""
        var i = input.startIndex
        let end = input.endIndex

        func flushText() {
            let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                segments.append(.text(buffer))
            }
            buffer = ""
        }

        while i < end {
            // Fenced code block: ``` optional-lang \n ... ```
            if input[i...].hasPrefix("```") {
                flushText()
                let afterFence = input.index(i, offsetBy: 3)
                var langEnd = afterFence
                while langEnd < end, input[langEnd] != "\n" {
                    langEnd = input.index(after: langEnd)
                }
                let language = String(input[afterFence..<langEnd])
                    .trimmingCharacters(in: .whitespaces)
                let bodyStart = langEnd < end ? input.index(after: langEnd) : langEnd
                if let closing = input.range(of: "```", range: bodyStart..<end) {
                    let code = String(input[bodyStart..<closing.lowerBound])
                    segments.append(.codeBlock(
                        language: language.isEmpty ? nil : language,
                        code: code.trimmingCharacters(in: .newlines)
                    ))
                    i = closing.upperBound
                    // Eat a trailing newline after the closing fence
                    if i < end, input[i] == "\n" { i = input.index(after: i) }
                } else {
                    // Unterminated fence — render the rest as text.
                    buffer += String(input[i...])
                    i = end
                }
                continue
            }

            // Display math: $$ ... $$
            if input[i...].hasPrefix("$$") {
                let bodyStart = input.index(i, offsetBy: 2)
                if let closing = input.range(of: "$$", range: bodyStart..<end) {
                    flushText()
                    let math = String(input[bodyStart..<closing.lowerBound])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !math.isEmpty {
                        segments.append(.displayMath(math))
                    }
                    i = closing.upperBound
                    continue
                }
                // Unterminated — fall through to text
            }

            // Inline math: $ ... $   (must not be empty, must not span paragraph break)
            if input[i] == "$" {
                let bodyStart = input.index(after: i)
                var search = bodyStart
                var found: String.Index? = nil
                var hitParaBreak = false
                while search < end {
                    if input[search] == "$" {
                        if search != bodyStart { found = search; break }
                    }
                    if input[search] == "\n",
                       input.index(after: search) < end,
                       input[input.index(after: search)] == "\n" {
                        hitParaBreak = true; break
                    }
                    search = input.index(after: search)
                }
                if let closing = found, !hitParaBreak {
                    let math = String(input[bodyStart..<closing])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !math.isEmpty {
                        flushText()
                        segments.append(.inlineMath(math))
                        i = input.index(after: closing)
                        continue
                    }
                }
                // Not a math span — pass the dollar sign through as text.
                buffer.append("$")
                i = input.index(after: i)
                continue
            }

            buffer.append(input[i])
            i = input.index(after: i)
        }
        flushText()
        return segments
    }
}

// MARK: - Wikilink preprocessing

enum Wikilink {
    /// Matches `[[Target]]` or `[[Target|Display]]`.
    private static let regex: NSRegularExpression = {
        // Non-greedy bodies; reject nested brackets.
        try! NSRegularExpression(pattern: #"\[\[([^\[\]|]+?)(?:\|([^\[\]]+?))?\]\]"#)
    }()

    /// If `linksEnabled`, rewrite each `[[Page]]` as a markdown link
    /// `[Page](wiki://Page)`. Otherwise drop the brackets and keep display text.
    static func preprocess(_ text: String, linksEnabled: Bool) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }

        var output = ""
        var cursor = text.startIndex
        for match in matches {
            guard let fullRange = Range(match.range, in: text) else { continue }
            output += text[cursor..<fullRange.lowerBound]
            let target = Range(match.range(at: 1), in: text).map { String(text[$0]) } ?? ""
            let display: String = {
                if match.range(at: 2).location != NSNotFound,
                   let r = Range(match.range(at: 2), in: text) {
                    return String(text[r])
                }
                return target
            }()
            if linksEnabled {
                let encoded = target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target
                output += "[\(display)](wiki://\(encoded))"
            } else {
                output += display
            }
            cursor = fullRange.upperBound
        }
        output += text[cursor...]
        return output
    }

    /// Decode the page title from a `wiki://...` URL produced by `preprocess`.
    static func target(from url: URL) -> String? {
        guard url.scheme == "wiki" else { return nil }
        // The title is in the host (single-segment titles) or the full path
        // depending on encoding; combine both and unescape.
        let raw = (url.host ?? "") + url.path
        return raw.removingPercentEncoding ?? raw
    }
}

// MARK: - Rich Content View

struct RichContentView: View {
    let segments: [ContentSegment]
    let wikilinkAction: ((String) -> Void)?

    init(_ raw: String, wikilinkAction: ((String) -> Void)? = nil) {
        self.segments = RichContentParser.parse(raw)
        self.wikilinkAction = wikilinkAction
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                view(for: segment)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func view(for segment: ContentSegment) -> some View {
        switch segment {
        case .text(let raw):
            textView(raw)
        case .inlineMath(let latex):
            MathView(latex: latex, mode: .text)
        case .displayMath(let latex):
            MathView(latex: latex, mode: .display)
                .frame(maxWidth: .infinity, alignment: .center)
        case .codeBlock(let language, let code):
            CodeBlockView(language: language, code: code)
        }
    }

    @ViewBuilder
    private func textView(_ raw: String) -> some View {
        let preprocessed = Wikilink.preprocess(raw, linksEnabled: wikilinkAction != nil)
        if let attributed = try? AttributedString(
            markdown: preprocessed,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attributed)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.openURL, OpenURLAction { url in
                    if url.scheme == "wiki", let action = wikilinkAction {
                        let title = Wikilink.target(from: url) ?? url.absoluteString
                        action(title)
                        return .handled
                    }
                    return .systemAction
                })
        } else {
            Text(preprocessed)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Code Block

struct CodeBlockView: View {
    let language: String?
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let lang = language, !lang.isEmpty {
                Text(lang.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.tertiary, in: .rect(cornerRadius: 10))
        }
    }
}
