//
//  MathView.swift
//  ChatBot
//
//  SwiftUI math typesetting for LaTeX strings.
//
//  Real rendering uses SwiftMath (https://github.com/mgriebling/SwiftMath).
//  Add via Xcode → File → Add Package Dependencies → that URL → ChatBot target.
//
//  When SwiftMath isn't linked the view falls back to a tasteful monospaced
//  badge so the project still builds and the LaTeX source stays visible.
//

import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

enum MathMode {
    case text       // inline-style (x-height roughly matches body text)
    case display    // centred, block-level, larger
}

#if canImport(SwiftMath) && canImport(UIKit)

import SwiftMath

struct MathView: View {
    let latex: String
    let mode: MathMode

    var body: some View {
        MathLabelRepresentable(latex: latex, mode: mode)
            .padding(.vertical, mode == .display ? 6 : 0)
    }
}

private struct MathLabelRepresentable: UIViewRepresentable {
    let latex: String
    let mode: MathMode
    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> MTMathUILabel {
        let label = MTMathUILabel()
        label.labelMode = (mode == .display) ? .display : .text
        label.textAlignment = (mode == .display) ? .center : .left
        label.fontSize = mode == .display ? 19 : 16
        label.contentInsets = .zero
        label.setContentHuggingPriority(.required, for: .vertical)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        label.backgroundColor = .clear
        label.latex = latex
        return label
    }

    func updateUIView(_ uiView: MTMathUILabel, context: Context) {
        if uiView.latex != latex { uiView.latex = latex }
        uiView.textColor = colorScheme == .dark ? .white : .label
    }
}

#else

// Fallback when SwiftMath isn't installed — render the LaTeX source verbatim
// inside a styled box so the user can still read what was emitted.
struct MathView: View {
    let latex: String
    let mode: MathMode

    var body: some View {
        Text(latex)
            .font(.system(size: mode == .display ? 16 : 14, design: .monospaced))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, mode == .display ? 8 : 3)
            .frame(maxWidth: mode == .display ? .infinity : nil, alignment: .center)
            .background(.fill.tertiary, in: .rect(cornerRadius: 8))
            .overlay(alignment: .topTrailing) {
                if mode == .display {
                    Text("LaTeX")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.fill.quaternary, in: .capsule)
                        .padding(6)
                }
            }
    }
}

#endif
