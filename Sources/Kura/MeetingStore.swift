// MeetingStore — persisted meeting history: JSON per meeting, smart titles, PDF/text context extraction.
import Foundation
import PDFKit

struct MeetingMeta: Identifiable, Equatable, Codable {
    let id: UUID
    var title: String
    let date: Date
}

struct Meeting: Codable {
    let meta: MeetingMeta
    let context: String
    let lines: [TranscriptLineData]
}

struct TranscriptLineData: Codable, Equatable {
    let speaker: String
    let text: String
    let isFinal: Bool
}

@MainActor
final class MeetingStore: ObservableObject {
    @Published private(set) var meetings: [MeetingMeta] = []

    private var dir: URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let current = applicationSupport.appendingPathComponent("Kura/Meetings")
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: current, withIntermediateDirectories: true)
        return current
    }

    init() { reload() }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        meetings = files.filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let meeting = try? JSONDecoder().decode(Meeting.self, from: data) else { return nil }
                return meeting.meta
            }
            .sorted { $0.date > $1.date }
    }

    @discardableResult
    func save(lines: [TranscriptLine], context: String) -> MeetingMeta? {
        let usable = lines.filter { !$0.text.isEmpty }
        guard !usable.isEmpty else { return nil }
        let meta = MeetingMeta(id: UUID(), title: Self.makeTitle(lines: usable, context: context), date: Date())
        let meeting = Meeting(
            meta: meta,
            context: context,
            lines: usable.map { TranscriptLineData(speaker: $0.speaker, text: $0.text, isFinal: $0.isFinal) }
        )
        if let data = try? JSONEncoder().encode(meeting) {
            try? data.write(to: dir.appendingPathComponent("\(meta.id.uuidString).json"))
        }
        reload()
        return meta
    }

    func load(_ meta: MeetingMeta) -> Meeting? {
        let url = dir.appendingPathComponent("\(meta.id.uuidString).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Meeting.self, from: data)
    }

    func delete(_ meta: MeetingMeta) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(meta.id.uuidString).json"))
        reload()
    }

    // Smart title: first sentence of an AI summary's Overview, else the opening
    // topic line, else the session context, else a dated fallback.
    static func makeTitle(lines: [TranscriptLine], context: String) -> String {
        if let ai = lines.first(where: { $0.speaker == "AI" && $0.text.contains("Overview") }),
           let overview = ai.text.components(separatedBy: "Overview").last?
               .trimmingCharacters(in: CharacterSet(charactersIn: " #\n"))
               .components(separatedBy: .newlines).first?
               .trimmingCharacters(in: .whitespaces),
           !overview.isEmpty {
            return String(overview.prefix(64))
        }
        if let first = lines.first(where: { !$0.text.isEmpty && $0.speaker != "AI" }) {
            let t = first.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.count > 56 ? String(t.prefix(56)) + "…" : t
        }
        let ctx = context.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ctx.isEmpty { return String(ctx.prefix(56)) }
        return "Meeting " + DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)
    }

    // Text extraction for context attachments (PDF via PDFKit, plain text otherwise).
    static func extractText(from url: URL) throws -> String {
        if url.pathExtension.lowercased() == "pdf" {
            guard let doc = PDFDocument(url: url), let text = doc.string, !text.isEmpty else {
                throw NSError(domain: "Kura", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not read text from that PDF"])
            }
            return String(text.prefix(12000))
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        return String(text.prefix(12000))
    }
}
