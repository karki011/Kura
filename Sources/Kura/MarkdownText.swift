// MarkdownText — lightweight markdown rendering: prose via AttributedString(markdown:),
// fenced code blocks (incl. ASCII diagrams) in monospaced boxes. No dependencies.
import SwiftUI

struct MarkdownText: View {
    let text: String
    var fontSize: CGFloat = 12
    @Environment(\.colorScheme) private var colorScheme

    enum Segment: Equatable {
        case prose(String)
        case code(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                switch seg {
                case .prose(let s):
                    Text(Self.attributed(s))
                        .font(.system(size: fontSize))
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .code(let code):
                    Text(code.trimmingCharacters(in: .newlines))
                        .font(.system(size: fontSize - 0.5, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(colorScheme == .dark ? Color.black.opacity(0.45) : Color.primary.opacity(0.08)))
                }
            }
        }
    }

    var segments: [Segment] {
        var segs: [Segment] = []
        var prose = ""
        var code = ""
        var inCode = false
        for line in text.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode {
                    segs.append(.code(code))
                    code = ""
                    inCode = false
                } else {
                    if !prose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        segs.append(.prose(prose))
                    }
                    prose = ""
                    inCode = true
                }
            } else if inCode {
                code += line + "\n"
            } else {
                prose += line + "\n"
            }
        }
        if inCode {
            segs.append(.code(code)) // unterminated fence while streaming
        } else if !prose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            segs.append(.prose(prose))
        }
        return segs
    }

    static func attributed(_ s: String) -> AttributedString {
        // AttributedString(markdown:) only parses inline syntax, so normalize
        // block-level markers: ### headers → bold, "- "/"* " bullets → "•".
        var processed = ""
        for line in s.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") {
                let stripped = t.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                processed += "**\(stripped)**\n"
            } else if t.hasPrefix("- [ ] ") || t.hasPrefix("* [ ] ") {
                processed += "☐ " + t.dropFirst(6) + "\n"
            } else if t.hasPrefix("- [x] ") || t.hasPrefix("* [x] ") {
                processed += "☑ " + t.dropFirst(6) + "\n"
            } else if t.hasPrefix("- ") || t.hasPrefix("* ") {
                processed += "• " + t.dropFirst(2) + "\n"
            } else {
                processed += line + "\n"
            }
        }
        return (try? AttributedString(markdown: processed,
                                      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}
