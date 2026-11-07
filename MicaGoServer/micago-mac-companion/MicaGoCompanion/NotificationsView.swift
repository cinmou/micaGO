import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Notifications page: UnifiedPush (Web Push) needs no setup on the Mac — each
/// phone picks its own distributor (ntfy, FCM via Google Play, ...). The
/// self-hosted Firebase project remains as a legacy, optional path.
struct NotificationsPage: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            UnifiedPushCard()
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
                LabeledRow(label: "Enabled", value: n.enabled ? L10n.localized( "yes") : L10n.localized( "no"))
                LabeledRow(label: "Provider", value: n.provider)
                LabeledRow(label: "Client config", value: (n.fcmClientConfigured ?? false) ? L10n.localized( "configured") : L10n.localized( "not set"))
                LabeledRow(label: "Service account", value: (n.fcmServiceAccountConfigured ?? false) ? L10n.localized( "configured") : L10n.localized( "not set"))
                LabeledRow(label: "Implemented", value: n.implemented.joined(separator: ", "))
                LabeledRow(label: "Firestore URL sync", value: model.firestoreSyncActive ? L10n.localized( "enabled") : L10n.localized( "disabled"))
            } else {
                Text("Start the server to read notification status.").foregroundStyle(.secondary)
            }
        }
    }

    private func stateLabel(_ n: NotificationStatus) -> String {
        if !n.enabled { return L10n.localized( "disabled") }
        if n.provider == "fcm" {
            let ready = n.implemented.contains("fcm") && n.fcmClientConfigured == true && n.fcmServiceAccountConfigured == true
            return ready ? L10n.localized("configured (fcm)") : L10n.localized("config invalid (fcm)")
        }
        return L10n.localized( "active (\(n.provider))")
    }
}

/// DAVx5-style: the Mac only signs and encrypts; which push service carries
/// the ciphertext is chosen on each phone.
private struct UnifiedPushCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        SectionCard(title: "Push Notifications (UnifiedPush)") {
            Toggle("Notifications enabled", isOn: $model.notifEnabled)

            Picker("Notification preview", selection: $model.notifPreview) {
                Text("Sender & message").tag("sender_and_text")
                Text("Sender only").tag("sender")
                Text("None (silent wake)").tag("none")
            }
            .pickerStyle(.menu)
            Text("UnifiedPush messages are end-to-end encrypted to each phone. The push service (ntfy, Google, …) only relays ciphertext and sees timing and size. Legacy Firebase pushes are not encrypted this way.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let key = model.status?.notifications.unifiedPushVapidPublicKey, !key.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text("VAPID public key").font(.callout)
                    Text(key)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(key, forType: .string)
                    }
                }
                Text("Generated on this Mac; the private key never leaves it. Choose ntfy or FCM (Google Play) in micaGO on each phone to enable this path. Private push hosts require an explicit Mac administrator configuration.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("UnifiedPush is unavailable: the running backend has no VAPID key. Update the backend.")
                    .font(.caption).foregroundStyle(.orange)
            }

            let pushDevices = model.devices.filter { $0.pushEnabled && $0.pushProvider != "none" && !$0.pushProvider.isEmpty }
            if pushDevices.isEmpty {
                Text("No phones registered for push yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(pushDevices) { device in
                    HStack(spacing: 8) {
                        Image(systemName: "iphone.gen3.radiowaves.left.and.right").foregroundStyle(.secondary)
                        Text(device.name).font(.callout)
                        Spacer()
                        Text(routeLabel(device)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 12) {
                Button("Save") { Task { await model.saveNotificationsConfig() } }
                    .disabled(model.notifBusy)
                Button("Send test notification") { Task { await model.testAllPushDevices() } }
                    .disabled(model.notifBusy || pushDevices.isEmpty)
                if model.notifBusy { ProgressView().controlSize(.small) }
            }
            if let result = model.notifResult {
                Text(result).font(.caption)
                    .foregroundStyle(result.hasPrefix("Saved") || result.contains("sent") ? .green : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func routeLabel(_ device: DeviceInfo) -> String {
        switch device.pushProvider {
        case "unifiedpush":
            if let host = device.pushEndpointHost, !host.isEmpty {
                return L10n.localized("via \(host)")
            }
            return "UnifiedPush"
        case "fcm": return L10n.localized("Firebase")
        default: return device.pushProvider
        }
    }
}

private struct FirebaseSetupCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        SectionCard(title: "Firebase Self-Host (optional)") {
            Text("Use your own Firebase project, or choose a UnifiedPush distributor on each phone.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Enable FCM delivery", isOn: $model.fcmEnabled)
                .onChange(of: model.fcmEnabled) { enabled in
                    if enabled { model.notifEnabled = true }
                }

            firebaseFileRow(
                icon: "iphone.gen3.radiowaves.left.and.right",
                ready: googleServicesReady,
                title: googleServicesLabel,
                button: "Choose google-services.json…",
                action: { chooseJSONFile(into: $model.googleServicesPath) }
            )
            Text("The Android app uses this file to set up Firebase.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            firebaseFileRow(
                icon: "key.horizontal.fill",
                ready: serviceAccountReady,
                title: serviceAccountLabel,
                button: "Choose service-account JSON…",
                action: { chooseJSONFile(into: $model.serviceAccountPath) }
            )
            Text("This file stays on the Mac. The server uses it to send pushes.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Firebase project ID (optional)", text: $model.fcmProjectID)
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))

            Toggle("Sync public URL to Firestore (optional)", isOn: $model.firestoreURLSync)
            Text("Only the public server URL is written there. Messages, tokens, contacts, and attachments are never stored.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button("Save") { Task { await model.saveNotificationsConfig() } }
                    .disabled(model.notifBusy)
                Button("Clear Firebase config", role: .destructive) { Task { await model.clearNotificationsConfig() } }
                    .disabled(model.notifBusy)
            }
        }
    }

    private var serviceAccountReady: Bool {
        model.serviceAccountPath.isEmpty && (model.status?.notifications.fcmServiceAccountConfigured ?? false)
    }

    private var googleServicesReady: Bool {
        model.googleServicesPath.isEmpty && (model.status?.notifications.fcmClientConfigured ?? false)
    }

    private var serviceAccountLabel: String {
        if model.serviceAccountPath.isEmpty {
            return serviceAccountReady ? L10n.localized( "Service account already configured") : L10n.localized( "No service-account file selected")
        }
        return L10n.localized( "Selected: \((model.serviceAccountPath as NSString).lastPathComponent)")
    }

    private var googleServicesLabel: String {
        if model.googleServicesPath.isEmpty {
            return googleServicesReady ? L10n.localized( "google-services.json already configured") : L10n.localized( "No google-services.json selected")
        }
        return L10n.localized( "Selected: \((model.googleServicesPath as NSString).lastPathComponent)")
    }

    private func firebaseFileRow(icon: String, ready: Bool, title: String, button: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ready ? "checkmark.seal.fill" : icon)
                .foregroundStyle(ready ? Color.green : Color.secondary)
            Text(title)
                .font(.callout).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button(LocalizedStringKey(button)) { action() }
        }
    }

    private func chooseJSONFile(into selection: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            selection.wrappedValue = url.path
        }
    }

}

private struct PushPrivacyCard: View {
    var body: some View {
        SectionCard(title: "Push Privacy") {
            Text("""
            • micaGO has no cloud server. Android push uses UnifiedPush: each phone picks a distributor (your own ntfy, FCM via Google Play, …).
            • UnifiedPush payloads are encrypted to the phone (RFC 8291). The push service sees only ciphertext, timing and size — not the sender or text.
            • Windows clients get notifications over WebSocket while they run. Huawei/HarmonyOS push isn't supported yet, and iOS push isn't planned.
            • Legacy Firebase pushes are not end-to-end encrypted: depending on your preview setting they can include the sender and message text.
            • Optional Firestore sync stores only the public server URL. Chat history and attachments still sync over your micaGO connection.
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
