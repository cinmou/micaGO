import Foundation
import Contacts
import AppKit

/// One contact's display info (name + the addresses it can be matched on).
/// Read-only, name + phones/emails only — never notes/addresses/birthdays.
struct ContactEntry: Identifiable, Hashable {
    let id: String        // CNContact identifier
    let name: String
    let rawAddresses: [String] // original phone/email strings for display
}

struct ServerContactEntry: Codable, Hashable {
    let name: String
    let addresses: [String]
}

/// A flattened (name, address) row used by the contact search UI.
struct ContactAddressRow: Identifiable, Hashable {
    let name: String
    let address: String     // raw address (server normalizes on rule upsert)
    var id: String { "\(name)|\(address)" }
}

/// Companion-only, local-only Contacts integration (v0.11.4). Resolves iMessage
/// handle addresses to display names for the UI. Read-only; in-memory cache;
/// never written to relay.db, sent to the server, or uploaded to any cloud.
@MainActor
final class ContactsStore: ObservableObject {
    @Published private(set) var status: CNAuthorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
    @Published private(set) var loaded = false
    @Published private(set) var contactCount = 0
    @Published private(set) var contactRevision = 0
    /// Last error text surfaced for diagnostics (e.g., TCC/code-signing failure).
    @Published private(set) var lastError: String?

    // normalized address -> display name; plus a last-10-digits fallback for
    // phone numbers that lack a country code on one side.
    private var byAddress: [String: String] = [:]
    private var byLast10: [String: String] = [:]
    private var entries: [ContactEntry] = []

    init() {
        NotificationCenter.default.addObserver(
            forName: .CNContactStoreDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.loadIfAuthorized() }
        }
    }

    var isAuthorized: Bool { status == .authorized }

    var statusDescription: String {
        switch status {
        case .notDetermined: return "not requested"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        @unknown default: return "unknown"
        }
    }

    func refreshStatus() {
        status = CNContactStore.authorizationStatus(for: .contacts)
    }

    func requestAccess() {
        CNContactStore().requestAccess(for: .contacts) { [weak self] granted, error in
            Task { @MainActor in
                if let error {
                    self?.lastError = "requestAccess failed: \(error.localizedDescription)"
                    NSLog("[Contacts] requestAccess error: \(error)")
                }
                self?.refreshStatus()
                if granted { await self?.load() }
            }
        }
    }

    /// Opens System Settings → Privacy & Security → Contacts. macOS only lets an
    /// app present the permission prompt itself once (while status is
    /// `.notDetermined`); once denied/restricted the user must toggle access
    /// here, so the UI routes here rather than offering a dead "Allow" button.
    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts") {
            NSWorkspace.shared.open(url)
        }
    }

    func loadIfAuthorized() async {
        refreshStatus()
        if isAuthorized { await load() }
    }

    func load() async {
        let result = await Task.detached(priority: .utility) { ContactsStore.fetch() }.value
        byAddress = result.byAddress
        byLast10 = result.byLast10
        entries = result.entries
        contactCount = result.entries.count
        lastError = result.error
        loaded = true
        contactRevision &+= 1
    }

    /// Resolve a raw handle address to a contact name, or nil if unmatched.
    func displayName(forHandle handle: String) -> String? {
        let norm = ContactsStore.normalize(handle)
        if let n = byAddress[norm] { return n }
        let digits = handle.filter(\.isNumber)
        if digits.count >= 10 {
            if let n = byLast10[String(digits.suffix(10))] { return n }
        }
        return nil
    }

    /// Address rows matching a query (name or address substring). Empty query
    /// returns a capped slice so the search list isn't huge.
    func searchAddresses(_ query: String) -> [ContactAddressRow] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        var rows: [ContactAddressRow] = []
        for entry in entries {
            let nameMatch = q.isEmpty || entry.name.lowercased().contains(q)
            for addr in entry.rawAddresses {
                if nameMatch || addr.lowercased().contains(q) {
                    rows.append(ContactAddressRow(name: entry.name, address: addr))
                }
            }
            if rows.count >= 100 { break }
        }
        return rows
    }

    var serverEntries: [ServerContactEntry] {
        entries.map { ServerContactEntry(name: $0.name, addresses: $0.rawAddresses) }
    }

    // MARK: - Fetch (off the main actor)

    struct FetchResult {
        let byAddress: [String: String]
        let byLast10: [String: String]
        let entries: [ContactEntry]
        let error: String?
    }

    nonisolated static func fetch() -> FetchResult {
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)

        var byAddress: [String: String] = [:]
        var byLast10: [String: String] = [:]
        var entries: [ContactEntry] = []

        do {
            try store.enumerateContacts(with: request) { contact, _ in
                let name = displayName(for: contact)
                var raws: [String] = []
                for phone in contact.phoneNumbers {
                    let raw = phone.value.stringValue
                    guard !raw.isEmpty else { continue }
                    raws.append(raw)
                    byAddress[normalize(raw)] = name
                    let digits = raw.filter(\.isNumber)
                    if digits.count >= 10 { byLast10[String(digits.suffix(10))] = name }
                }
                for email in contact.emailAddresses {
                    let raw = email.value as String
                    guard !raw.isEmpty else { continue }
                    raws.append(raw)
                    byAddress[normalize(raw)] = name
                }
                if !raws.isEmpty {
                    entries.append(ContactEntry(id: contact.identifier, name: name, rawAddresses: raws))
                }
            }
        } catch {
            let message = "enumerateContacts failed: \(error.localizedDescription)"
            NSLog("[Contacts] \(message)")
            entries.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return FetchResult(byAddress: byAddress, byLast10: byLast10, entries: entries, error: message)
        }
        entries.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return FetchResult(byAddress: byAddress, byLast10: byLast10, entries: entries, error: nil)
    }

    nonisolated static func displayName(for contact: CNContact) -> String {
        let full = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
        if !full.isEmpty { return full }
        if !contact.nickname.isEmpty { return contact.nickname }
        if !contact.organizationName.isEmpty { return contact.organizationName }
        return "(unnamed)"
    }

    /// Mirrors the server's handle normalization so matches are consistent:
    /// emails lowercased; phones keep a leading "+" and digits only.
    nonisolated static func normalize(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return "" }
        if s.contains("@") { return s.lowercased() }
        var out = ""
        for (i, ch) in s.enumerated() {
            if ch.isNumber { out.append(ch) }
            else if ch == "+" && i == 0 { out.append(ch) }
        }
        return out.isEmpty ? s.lowercased() : out
    }
}
