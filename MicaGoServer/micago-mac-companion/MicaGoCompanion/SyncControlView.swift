import SwiftUI
import AppKit

/// A target the rule editor can act on (a chat GUID or a normalized handle).
struct RuleTarget: Identifiable {
    let kind: String   // "chat" | "handle"
    let value: String
    let label: String
    var id: String { "\(kind):\(value)" }
}

// MARK: - Sync Control page

struct SyncControlPage: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var contacts: ContactsStore
    @State private var editorTarget: RuleTarget?

    var body: some View {
        Group {
            SectionCard(title: L10n.tr("sync.title")) {
                Text(L10n.tr("sync.desc"))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = model.lastError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let err = model.syncControlError {
                SyncControlErrorCard(message: err)
            }

            ContactsCard()
            DefaultPolicyCard()
            BackfillSettingsCard()
            ContactSearchCard(editorTarget: $editorTarget)
            ChatsCard(editorTarget: $editorTarget)
            RulesOverviewCard()
        }
        .task {
            await model.loadSyncControl()
            await contacts.loadIfAuthorized()
        }
        .sheet(item: $editorTarget) { target in
            RuleEditorSheet(target: target)
                .environmentObject(model)
                .environmentObject(contacts)
        }
    }
}

// MARK: - Load-error state (Retry + Copy diagnostics)

/// Shown when one or more Sync Control requests fail to load. Replaces the old
/// single-line "Server returned HTTP 500" inline note with an actionable card
/// that names which request failed and offers Retry + Copy diagnostics.
private struct SyncControlErrorCard: View {
    @EnvironmentObject var model: AppModel
    let message: String

    var body: some View {
        SectionCard(title: L10n.tr("sync.loadErrorTitle")) {
            Text(message)
                .font(.callout).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.tr("sync.loadErrorHelp"))
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button { Task { await model.loadSyncControl() } } label: {
                    Label(L10n.tr("sync.retry"), systemImage: "arrow.clockwise")
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.syncControlDiagnosticsText, forType: .string)
                } label: {
                    Label(L10n.tr("sync.copyDiagnostics"), systemImage: "doc.on.doc")
                }
                Spacer()
            }
        }
    }
}

// MARK: - Backfill / service scope

private struct BackfillSettingsCard: View {
    @EnvironmentObject var model: AppModel

    private let limits = [50, 100, 200, 500]

    var body: some View {
        SectionCard(title: L10n.tr("sync.backfill")) {
            Picker("Backfill mode", selection: binding(\.backfillMode)) {
                Text("Global recent").tag("global_recent")
                Text("Per chat recent").tag("per_chat_recent")
                Text("Hybrid").tag("hybrid")
            }
            .pickerStyle(.segmented)

            HStack {
                Text("Backfill depth per chat").foregroundStyle(.secondary)
                Picker("", selection: binding(\.recentMessagesPerChat)) {
                    ForEach(limits, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
                Spacer()
            }

            Toggle("Show iMessage conversations", isOn: binding(\.includeIMessage))
            Toggle("Show SMS conversations", isOn: binding(\.includeSMS))
            Toggle("Show RCS conversations", isOn: binding(\.includeRCS))
            Toggle("Show unknown-service conversations in debug mode", isOn: binding(\.includeUnknown))
            Toggle("Include debug-only/noise in normal client", isOn: binding(\.includeDebugInNormal))

            HStack {
                if model.syncBusy || model.syncNowBusy { ProgressView().controlSize(.small) }
                Button {
                    Task { await model.saveSyncSettings(model.syncSettings) }
                } label: {
                    Label("Save and run backfill", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(model.syncBusy || !model.reachable)
                Button {
                    Task { await model.runSyncNow() }
                } label: {
                    Label("Run backfill now", systemImage: "arrow.clockwise")
                }
                .disabled(model.syncNowBusy || !model.reachable)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.syncDiagnosticsText, forType: .string)
                } label: {
                    Label("Copy diagnostics", systemImage: "doc.on.doc")
                }
                Spacer()
            }

            if let d = model.syncDiagnostics {
                Text("Mode \(d.lastBackfillMode ?? "—") · limit \(d.lastPerChatLimit ?? 0) · chats \(model.chatsList.count) · rows \(d.lastRowsScanned ?? 0) · renderable \(d.lastRenderableRows ?? 0) · hidden \(d.lastHiddenDebugRows ?? 0)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let err = d.lastSyncError, !err.isEmpty {
                    Text("Last error: \(err)").font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<SyncSettings, T>) -> Binding<T> {
        Binding(
            get: { model.syncSettings[keyPath: keyPath] },
            set: { model.syncSettings[keyPath: keyPath] = $0 }
        )
    }
}

// MARK: - Contacts permission

private struct ContactsCard: View {
    @EnvironmentObject var contacts: ContactsStore

    var body: some View {
        SectionCard(title: L10n.tr("sync.contacts")) {
            HStack(spacing: 8) {
                Image(systemName: contacts.isAuthorized ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.questionmark")
                    .foregroundStyle(contacts.isAuthorized ? Color.green : Color.secondary)
                Text("Access: \(contacts.statusDescription)")
                if contacts.isAuthorized {
                    Text("· \(contacts.contactCount) contacts").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if contacts.status == .notDetermined {
                    Button(L10n.tr("sync.requestContacts")) { contacts.requestAccess() }
                } else if !contacts.isAuthorized {
                    Button(L10n.tr("sync.openSystemSettings")) { contacts.openSystemSettings() }
                }
            }
            if contacts.status == .notDetermined {
                Text("Contacts are optional and local-only. Grant access to show names for handles and create handle rules more easily; contacts are never uploaded.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !contacts.isAuthorized {
                Text("Contacts permission is managed by macOS. Open System Settings → Privacy & Security → Contacts and enable micaGO Companion. Without it, contact names and photos may be unavailable — the app still works using the raw phone/email handles where supported.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = contacts.lastError {
                    Text("Diagnostic: \(error)")
                        .font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Optional and local-only. Contacts are read on this Mac to show names for handles and help you create rules. They are never uploaded, stored in the relay, or sent in push.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Contact search (create a handle rule)

private struct ContactSearchCard: View {
    @EnvironmentObject var contacts: ContactsStore
    @Binding var editorTarget: RuleTarget?
    @State private var query = ""

    var body: some View {
        SectionCard(title: L10n.tr("sync.findContact")) {
            if !contacts.isAuthorized {
                Text("Enable Contacts access (see above) to search for people and create handle rules.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                TextField("Search name, phone, or email", text: $query)
                    .textFieldStyle(.roundedBorder)
                let rows = contacts.searchAddresses(query)
                if rows.isEmpty {
                    Text("No matches.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(rows.prefix(20)) { row in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.name).fontWeight(.medium).lineLimit(1)
                                Text(row.address).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button("Rule…") {
                                editorTarget = RuleTarget(kind: "handle", value: row.address,
                                                          label: "\(row.name) · \(row.address)")
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 1)
                        Divider()
                    }
                    if rows.count > 20 {
                        Text("Showing first 20 of \(rows.count) matches; refine the search.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Default policy

private struct DefaultPolicyCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        SectionCard(title: L10n.tr("sync.defaultPolicy")) {
            Picker("Default sync", selection: Binding(
                get: { model.syncRules?.defaultSyncPolicy ?? "allow_all" },
                set: { newValue in
                    Task { await model.saveDefaultPolicy(sync: newValue, push: model.syncRules?.defaultPushPolicy ?? "enabled") }
                }
            )) {
                Text("Allow all (block specific)").tag("allow_all")
                Text("Block all (allowlist)").tag("block_all")
            }
            .pickerStyle(.menu)

            Text("Rules below override the default sync policy for a specific chat or handle. Chat rules win over handle rules; both win over the default.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Chats (rule targets)

private struct ChatsCard: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var contacts: ContactsStore
    @Binding var editorTarget: RuleTarget?

    var body: some View {
        SectionCard(title: "\(L10n.tr("sync.chats")) (\(model.chatsList.count))") {
            if model.chatsList.isEmpty {
                Text("No chats synced yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(model.chatsList) { chat in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(label(for: chat)).fontWeight(.medium).lineLimit(1)
                            Text(ruleStatus(forChat: chat.guid)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Rule…") {
                            editorTarget = RuleTarget(kind: "chat", value: chat.guid, label: label(for: chat))
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 2)
                    Divider()
                }
            }
        }
    }

    // Use the contact name when the chat has no display name and its identifier
    // is a recognizable handle (1:1 chats).
    private func label(for chat: ChatSummary) -> String {
        if let display = chat.displayName, !display.isEmpty { return display }
        if let ident = chat.chatIdentifier, !ident.isEmpty,
           let name = contacts.displayName(forHandle: ident) {
            return name
        }
        return chat.label
    }

    private func ruleStatus(forChat guid: String) -> String {
        guard let rule = model.storedRule(kind: "chat", value: guid) else { return "default policy" }
        return "sync: \(rule.syncMode)"
    }
}

// MARK: - Rules overview

private struct RulesOverviewCard: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var contacts: ContactsStore

    var body: some View {
        SectionCard(title: L10n.tr("sync.activeRules")) {
            let rules = model.syncRules?.rules ?? []
            if rules.isEmpty {
                Text("No overrides — the default policy applies to everything.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(rules) { rule in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            if rule.targetKind == "handle", let name = contacts.displayName(forHandle: rule.targetValue) {
                                Text(name).fontWeight(.medium).lineLimit(1)
                            }
                            Text("\(rule.targetKind): \(rule.targetValue)")
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1).truncationMode(.middle)
                            Text("sync: \(rule.syncMode)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            Task { await model.clearSyncRule(targetKind: rule.targetKind, targetValue: rule.targetValue) }
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 2)
                    Divider()
                }
            }
        }
    }
}

// MARK: - Rule editor sheet

struct RuleEditorSheet: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var contacts: ContactsStore
    @Environment(\.dismiss) private var dismiss
    let target: RuleTarget

    @State private var syncMode = "inherit"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rule for \(target.kind)").font(.headline)
            if target.kind == "handle", let name = contacts.displayName(forHandle: target.value) {
                Text(name).fontWeight(.medium)
            }
            Text(target.label)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2).truncationMode(.middle)

            Picker("Sync", selection: $syncMode) {
                Text("Inherit default").tag("inherit")
                Text("Allow").tag("allow")
                Text("Block").tag("block")
            }
            .pickerStyle(.segmented)

            Text("Blocking sync stops future messages for this target from being saved to the relay. Messages already synced are kept.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Clear rule", role: .destructive) {
                    Task {
                        await model.clearSyncRule(targetKind: target.kind, targetValue: target.value)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    Task {
                        await model.saveSyncRule(targetKind: target.kind, targetValue: target.value,
                                                 syncMode: syncMode, pushMode: existingPushMode)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.syncBusy)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            if let existing = model.storedRule(kind: target.kind, value: target.value) {
                syncMode = existing.syncMode
            }
        }
    }

    private var existingPushMode: String {
        model.storedRule(kind: target.kind, value: target.value)?.pushMode ?? "inherit"
    }
}
