import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Notifications page (v0.12): provider status + self-host Firebase (FCM) setup.
/// micaGO provides no cloud — each user brings their own Firebase project.
struct NotificationsPage: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            ProviderStatusCard()
            FirebaseSetupCard()
            PushPrivacyCard()
        }
        .task { await model.refresh() }
    }
}

private struct ProviderStatusCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        SectionCard(title: "Provider Status") {
            if let n = model.status?.notifications {
                LabeledRow(label: "State", value: stateLabel(n))
                LabeledRow(label: "Enabled", value: n.enabled ? "yes" : "no")
                LabeledRow(label: "Provider", value: n.provider)
                LabeledRow(label: "Preview", value: n.preview)
                LabeledRow(label: "Implemented", value: n.implemented.joined(separator: ", "))
                LabeledRow(label: "Stub", value: n.stub.isEmpty ? "—" : n.stub.joined(separator: ", "))
                LabeledRow(label: "Firestore URL sync", value: model.firestoreSyncActive ? "enabled" : "disabled")
            } else {
                Text("Start the server to read notification status.").foregroundStyle(.secondary)
            }
        }
    }

    private func stateLabel(_ n: NotificationStatus) -> String {
        if !n.enabled { return "disabled" }
        if n.provider == "fcm" { return n.implemented.contains("fcm") ? "configured (fcm)" : "config invalid (fcm)" }
        return "active (\(n.provider))"
    }
}

private struct FirebaseSetupCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        SectionCard(title: "Firebase Self-Host (Android FCM)") {
            Toggle("Notifications enabled", isOn: $model.notifEnabled)

            Picker("Provider", selection: $model.notifProvider) {
                Text("None").tag("none")
                Text("Webhook").tag("webhook")
                Text("FCM (Firebase)").tag("fcm")
            }
            .pickerStyle(.menu)

            Picker("Preview", selection: $model.notifPreview) {
                Text("None (generic)").tag("none")
                Text("Sender only").tag("sender")
                Text("Sender + text").tag("sender_and_text")
            }
            .pickerStyle(.menu)

            if model.notifProvider == "fcm" {
                Toggle("Enable FCM delivery", isOn: $model.fcmEnabled)

                HStack(spacing: 8) {
                    Image(systemName: model.serviceAccountPath.isEmpty ? "doc.badge.plus" : "checkmark.seal.fill")
                        .foregroundStyle(model.serviceAccountPath.isEmpty ? Color.secondary : Color.green)
                    Text(serviceAccountLabel)
                        .font(.callout).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose service-account JSON…") { chooseServiceAccount() }
                }
                Text("The service-account JSON stays on this Mac. It is never shown again, uploaded, or sent to clients.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextField("Firebase project ID (optional; inferred from the JSON)", text: $model.fcmProjectID)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))

                Toggle("Sync public URL to Firestore (optional)", isOn: $model.firestoreURLSync)
                Text("When on, ONLY the public server URL is written to your Firestore so remote clients can rediscover a changed tunnel URL. No tokens, contacts, or message content.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                Button("Save") { Task { await model.saveNotificationsConfig() } }
                    .disabled(model.notifBusy)
                Button("Clear Firebase config", role: .destructive) { Task { await model.clearNotificationsConfig() } }
                    .disabled(model.notifBusy)
                if model.notifBusy { ProgressView().controlSize(.small) }
            }

            if let result = model.notifResult {
                Text(result).font(.caption)
                    .foregroundStyle(result.hasPrefix("Saved") || result.contains("sent") ? .green : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Test Push is on the Devices page (per registered device).")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var serviceAccountLabel: String {
        if model.serviceAccountPath.isEmpty { return "No service-account file selected" }
        return "Selected: " + (model.serviceAccountPath as NSString).lastPathComponent
    }

    private func chooseServiceAccount() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            model.serviceAccountPath = url.path
        }
    }
}

private struct PushPrivacyCard: View {
    var body: some View {
        SectionCard(title: "Push Privacy") {
            Text("""
            • micaGO runs no cloud server — you use your own Firebase project.
            • Firebase is only for Android FCM push and the optional public-URL discovery.
            • Windows clients use WebSocket + local notifications while running. Huawei/HarmonyOS Push is deferred. iOS push is out of scope.
            • Firebase NEVER stores message content, contacts, phone numbers, bearer tokens, attachments, chat history, the device registry, or sync rules.
            • Push text is gated by Preview: None sends no text, Sender sends only the sender label, Sender + text includes the message text in the transient push (never stored).
            """)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Link("Firebase Console", destination: URL(string: "https://console.firebase.google.com")!)
            Link("Firebase setup guide", destination: URL(string: "https://github.com/cinmou/MicaGo/blob/main/docs/setup/firebase/README.md")!)
                .font(.caption2)
        }
    }
}
