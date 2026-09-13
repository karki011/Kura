import Foundation

// A separate preview bundle uses synthetic data and a stub provider, never real meeting history or API keys.
enum PreviewFixtures {
    @MainActor static func model() -> OverlayViewModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KuraPreview-\(UUID())")
        let model = OverlayViewModel(root: root, restore: false, providerFactory: { _ in PreviewProvider() })
        model.session.meta.title = "Launch planning"
        model.session.goal = "Agree on a launch date and give every next step an owner."
        model.session.context = "A small product team preparing the next release. Keep the launch focused."
        model.session.attachments = [ContextAttachment(name: "Launch brief.md", text: "The release includes a refreshed meeting workspace, speaker labels, and editable next steps.")]
        model.transcript.appendFinal("Let’s keep Friday as our target. I’ll send the updated launch brief tomorrow.", speaker: "Alex")
        model.transcript.appendFinal("That works. I’ll check the onboarding flow and share the remaining issues today.", speaker: "You")
        model.transcript.appendFinal("Friday is the target. Alex owns the brief; you own the onboarding review. The remaining question is who will approve the release.", speaker: "Kura", source: "assistant")
        model.session.wrapUp.notes = """
        ## Summary
        The team agreed on a Friday launch, with preparation focused on the brief and onboarding experience.

        ## Decisions
        - Target Friday for the release.

        ## Action items
        - [ ] Send the updated launch brief — Alex (Tomorrow)
        - [ ] Review onboarding and share remaining issues — You (Today)

        ## Open questions
        - Who gives final release approval?
        """
        var previous = Meeting.empty(); previous.meta.title = "Customer discovery"; previous.tags = "Research, Customer"; previous.favorite = true
        previous.lines = [TranscriptLine(speaker: "Jamie", text: "We need a faster way to turn conversations into clear next steps.")]
        model.meetings.meetings = [previous]
        model.notice = "Preview workspace · sample data"
        return model
    }
}
private struct PreviewProvider: LLMProvider {
    func stream(messages: [LLMMessage], system: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let output = messages.first?.content.contains("Write the meeting wrap-up") == true
                    ? "## Summary\n\nThe team agreed on a Friday release.\n\n## Decisions\n- Target Friday\n\n## Action items\n- Send the launch brief — Alex (Tomorrow)\n\n## Open questions\n- Who approves the release?"
                    : "The next useful step is to confirm who approves Friday’s release. Alex is preparing the brief, and you’re reviewing onboarding."
                do {
                    for word in output.split(separator: " ", omittingEmptySubsequences: false) { try await Task.sleep(for: .milliseconds(35)); continuation.yield(String(word) + " ") }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
