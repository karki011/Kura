import SwiftUI
import AppKit

/// Each editor owns exactly one credential; switching providers never saves hidden fields.
struct APIKeyEditor: View {
    let account: String
    let title: String
    var onCredentialChange: () -> Void = {}
    @State private var key = ""
    @State private var savedKey = ""
    @State private var revealed = false
    @State private var status = ""
    @State private var confirmRemoval = false
    @State private var busy = true

    var body: some View {
        WorkspaceSection(title) {
            HStack {
                Group {
                    if revealed { TextField("Paste your API key", text: $key) }
                    else { SecureField("Paste your API key", text: $key) }
                }.textFieldStyle(.roundedBorder)
                Button { revealed.toggle() } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                }.help(revealed ? "Hide API key" : "Show API key")
                    .accessibilityLabel(revealed ? "Hide API key" : "Show API key")
            }
            HStack {
                Button("Paste") {
                    if let value = NSPasteboard.general.string(forType: .string) { key = value.trimmingCharacters(in: .whitespacesAndNewlines) }
                    else { status = "Clipboard does not contain text." }
                }
                Button("Save key") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || key == savedKey)
                if !savedKey.isEmpty {
                    Button("Remove…", role: .destructive) { confirmRemoval = true }
                }
                Spacer()
                Text(key != savedKey ? "Unsaved changes" : (savedKey.isEmpty ? "Not connected" : "Key saved"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Stored securely in macOS Keychain. Saving a key does not verify access.")
                .font(.caption).foregroundStyle(.secondary)
            if !status.isEmpty { Text(status).font(.caption) }
            if busy { ProgressView("Waiting for Keychain…").controlSize(.small) }
        }
        .disabled(busy)
        .task(id: account) { await reload() }
        .onChange(of: key) { _, _ in status = "" }
        .confirmationDialog("Remove this saved API key?", isPresented: $confirmRemoval) {
            Button("Remove key", role: .destructive) {
                busy = true
                let target = account
                Task {
                    let removed = await Task.detached { Keychain.delete(account: target) }.value
                    guard target == account else { return }
                    if removed { key = ""; savedKey = ""; revealed = false; status = "Key removed."; onCredentialChange() }
                    else { status = "Could not remove the key. Check Keychain access and try again." }
                    busy = false
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: { Text("This removes it from Kura, not from your provider account.") }
    }

    private func reload() async {
        busy = true
        let target = account
        let value = await Task.detached { Keychain.get(account: target, allowInteraction: true) ?? "" }.value
        guard !Task.isCancelled, target == account else { return }
        key = value
        savedKey = key
        revealed = false
        status = ""
        busy = false
    }

    private func save() async {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        busy = true
        let target = account
        let saved = await Task.detached { Keychain.set(value, account: target) && Keychain.get(account: target, allowInteraction: true) == value }.value
        guard target == account else { return }
        if saved {
            key = value; savedKey = value; revealed = false
            status = "Saved securely. Use Test connection to verify your answer provider."
            onCredentialChange()
        } else { status = "Could not save. Check macOS Keychain access and try again." }
        busy = false
    }
}
