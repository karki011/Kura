import Foundation
import PDFKit

struct MeetingMeta: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    var title: String
    let date: Date
}
struct ContextAttachment: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var text: String
    var warning: String = ""
}
struct ContextPack: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var notes: String
    var goal: String
    var attachments: [ContextAttachment]
}
struct ActionItem: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var title: String
    var owner: String = ""
    var deadline: String = ""
    var completed = false
    var sourceID: UUID?
}
struct MeetingWrapUp: Codable, Equatable, Sendable {
    // The structured fields predate the freeform notes editor; they are kept so
    // saved meetings still decode and can be seeded into notes.
    var summary = ""
    var decisions: [String] = []
    var questions: [String] = []
    var tasks: [ActionItem] = []
    var followUp = ""
    var notes = ""
    init() {}
    enum CodingKeys: String, CodingKey { case summary, decisions, questions, tasks, followUp, notes }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        decisions = try c.decodeIfPresent([String].self, forKey: .decisions) ?? []
        questions = try c.decodeIfPresent([String].self, forKey: .questions) ?? []
        tasks = try c.decodeIfPresent([ActionItem].self, forKey: .tasks) ?? []
        followUp = try c.decodeIfPresent(String.self, forKey: .followUp) ?? ""
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }
    /// Markdown rendering of the legacy structured fields; empty when they hold nothing.
    var legacyMarkdown: String {
        var text = ""
        if !summary.isEmpty { text += "## Summary\n\(summary)\n\n" }
        if !decisions.isEmpty { text += "## Decisions\n" + decisions.map { "- \($0)" }.joined(separator: "\n") + "\n\n" }
        if !tasks.isEmpty {
            text += "## Action items\n" + tasks.map {
                "- [\($0.completed ? "x" : " ")] \($0.title)" + ($0.owner.isEmpty ? "" : " — \($0.owner)") + ($0.deadline.isEmpty ? "" : " (\($0.deadline))")
            }.joined(separator: "\n") + "\n\n"
        }
        if !questions.isEmpty { text += "## Open questions\n" + questions.map { "- \($0)" }.joined(separator: "\n") + "\n\n" }
        if !followUp.isEmpty { text += "## Follow-up draft\n\(followUp)\n\n" }
        return text
    }
}
struct Meeting: Codable, Equatable, Sendable, Identifiable {
    var meta: MeetingMeta
    var context = ""
    var lines: [TranscriptLine] = []
    var goal = ""
    var attachments: [ContextAttachment] = []
    var tags = ""
    var favorite = false
    var wrapUp = MeetingWrapUp()
    var endedAt: Date?
    /// Running total of priced AI calls for this meeting. Unpriced usage (local models,
    /// unknown model IDs) adds tokens to answer metadata but nothing here.
    var aiSpendUSD: Double = 0
    /// Which listen engine captured this meeting ("apple" / "fluid" / "realtime"); nil if never recorded.
    var captureEngine: String?
    var id: UUID { meta.id }
    var hasContent: Bool { !lines.isEmpty || !context.isEmpty || !attachments.isEmpty || !goal.isEmpty || !meta.title.isEmpty || wrapUp != MeetingWrapUp() }
    var title: String {
        if !meta.title.isEmpty { return meta.title }
        if let first = lines.first(where: { $0.source == "speech" && !$0.text.isEmpty }) { return String(first.text.prefix(56)) }
        return "Untitled meeting"
    }
    static func empty() -> Meeting { Meeting(meta: MeetingMeta(id: UUID(), title: "", date: Date())) }
    enum CodingKeys: String, CodingKey { case meta, context, lines, goal, attachments, tags, favorite, wrapUp, endedAt, aiSpendUSD, captureEngine }
    init(meta: MeetingMeta) { self.meta = meta }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        meta = try c.decode(MeetingMeta.self, forKey: .meta)
        context = try c.decodeIfPresent(String.self, forKey: .context) ?? ""
        lines = try c.decodeIfPresent([TranscriptLine].self, forKey: .lines) ?? []
        goal = try c.decodeIfPresent(String.self, forKey: .goal) ?? ""
        attachments = try c.decodeIfPresent([ContextAttachment].self, forKey: .attachments) ?? []
        tags = try c.decodeIfPresent(String.self, forKey: .tags) ?? ""
        favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        wrapUp = try c.decodeIfPresent(MeetingWrapUp.self, forKey: .wrapUp) ?? MeetingWrapUp()
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        aiSpendUSD = try c.decodeIfPresent(Double.self, forKey: .aiSpendUSD) ?? 0
        captureEngine = try c.decodeIfPresent(String.self, forKey: .captureEngine)
    }
    var contextForAI: String {
        var result = "Meeting: \(title)\nGoal: \(goal)\nNotes:\n\(context)"
        for item in attachments { result += "\n\nAttachment: \(item.name)\n\(item.text)" }
        return String(result.prefix(40000))
    }
    var contextIsTrimmed: Bool { context.count + goal.count + attachments.reduce(0) { $0 + $1.text.count + $1.name.count + 20 } > 39000 }
    var markdown: String {
        var text = "# \(title)\n\n\(meta.date.formatted())\n\n"
        if !goal.isEmpty { text += "## Goal\n\(goal)\n\n" }
        if !wrapUp.notes.isEmpty { text += "## Wrap-up\n\(wrapUp.notes)\n\n" }
        else { text += wrapUp.legacyMarkdown }
        text += "## Transcript\n\n"
        for line in lines where !line.text.isEmpty {
            let stamp = line.timestamp == .distantPast ? "" : " [\(line.timestamp.formatted(date: .omitted, time: .standard))]"
            text += "**\(line.speaker)**\(stamp): \(line.text)\n\n"
        }
        return text
    }
}

actor MeetingRepository {
    let root: URL
    init(root: URL) { self.root = root }
    private func prepare() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    func list() throws -> [Meeting] {
        try prepare()
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
            .compactMap { try? JSONDecoder().decode(Meeting.self, from: Data(contentsOf: $0)) }
            .sorted { $0.meta.date > $1.meta.date }
    }
    func write(_ meeting: Meeting, draft: Bool) throws {
        try prepare()
        let name = draft ? "active" : meeting.id.uuidString
        try JSONEncoder().encode(meeting).write(to: root.appendingPathComponent(name + ".json"), options: .atomic)
    }
    func draft() throws -> Meeting? {
        let url = root.appendingPathComponent("active.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        do { return try JSONDecoder().decode(Meeting.self, from: data) }
        catch {
            // Preserve unreadable data before a fresh draft can be created.
            let recovery = root.appendingPathComponent("Recovery")
            try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
            let backup = recovery.appendingPathComponent("active-\(UUID()).json")
            try data.write(to: backup, options: .atomic)
            throw KuraError.message("The previous draft could not be read. A copy is preserved at \(backup.path).")
        }
    }
    func trash(_ id: UUID) throws {
        let trash = root.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: root.appendingPathComponent(id.uuidString + ".json"), to: trash.appendingPathComponent(id.uuidString + ".json"))
    }
    func restore(_ id: UUID) throws {
        try FileManager.default.moveItem(at: root.appendingPathComponent("Trash/\(id).json"), to: root.appendingPathComponent("\(id).json"))
    }
    func packs() throws -> [ContextPack] {
        let url = root.appendingPathComponent("context-packs.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([ContextPack].self, from: Data(contentsOf: url))
    }
    func savePacks(_ packs: [ContextPack]) throws {
        try prepare()
        try JSONEncoder().encode(packs).write(to: root.appendingPathComponent("context-packs.json"), options: .atomic)
    }
}

@MainActor
final class MeetingStore: ObservableObject {
    @Published var meetings: [Meeting] = [] {
        didSet { searchIndex = Dictionary(uniqueKeysWithValues: meetings.map { ($0.id, $0.title + " " + $0.tags + " " + $0.context + " " + $0.lines.map(\.text).joined(separator: " ")) }) }
    }
    @Published var packs: [ContextPack] = []
    private var searchIndex: [UUID: String] = [:]
    func matches(_ id: UUID, query: String) -> Bool { query.isEmpty || (searchIndex[id]?.localizedCaseInsensitiveContains(query) ?? false) }
    let repository: MeetingRepository
    init(root: URL? = nil) {
        repository = MeetingRepository(root: root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kura/Meetings"))
    }
    func reload() async throws {
        meetings = try await repository.list(); packs = try await repository.packs()
    }
    func save(_ meeting: Meeting, draft: Bool = false) async throws {
        try await repository.write(meeting, draft: draft)
        if !draft {
            meetings.removeAll { $0.id == meeting.id }; meetings.append(meeting)
            meetings.sort { $0.meta.date > $1.meta.date }
        }
    }
    nonisolated static func extractAttachment(from url: URL) throws -> ContextAttachment {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 20_000_000 else { throw CocoaError(.fileReadTooLarge) }
        let text: String
        if url.pathExtension.lowercased() == "pdf" {
            guard let value = PDFDocument(url: url)?.string, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NSError(domain: "Kura", code: 1, userInfo: [NSLocalizedDescriptionKey: "This PDF has no selectable text. Paste its notes or use a text-based PDF."])
            }
            text = value
        } else { text = try String(contentsOf: url, encoding: .utf8) }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "Kura", code: 2, userInfo: [NSLocalizedDescriptionKey: "This file is empty."])
        }
        return ContextAttachment(name: url.lastPathComponent, text: String(text.prefix(30000)), warning: text.count > 30000 ? "First 30,000 characters imported" : "")
    }
}
