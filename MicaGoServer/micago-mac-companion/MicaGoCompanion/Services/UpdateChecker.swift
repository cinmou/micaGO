import Foundation

/// C74: "is there a newer build?" against the project's GitHub releases.
///
/// Read-only and unauthenticated: fetches the latest published release, compares
/// its tag with the running Companion version, and reports the outcome. Nothing
/// is downloaded or installed — the UI opens the release page and the user
/// decides. Every failure resolves to `.unknown`, so an offline or rate-limited
/// check never blocks the About page or raises a false alarm.
enum UpdateCheckStatus: Equatable {
    case idle
    case checking
    case upToDate
    case updateAvailable(version: String, url: URL)
    case unknown
}

/// Splits a version into comparable numeric parts, ignoring a leading "v" and
/// any pre-release suffix ("0.65.0-beta.1" → [0, 65, 0]).
func updateVersionParts(_ raw: String) -> [Int] {
    var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    while value.first == "v" || value.first == "V" { value.removeFirst() }
    if let cut = value.firstIndex(where: { $0 == "-" || $0 == "+" || $0 == " " }) {
        value = String(value[value.startIndex..<cut])
    }
    return value.split(separator: ".").map { part in
        Int(part.filter(\.isNumber)) ?? 0
    }
}

/// True when `latest` is strictly newer than `current`. Missing trailing parts
/// count as 0, so "0.65" == "0.65.0".
func isNewerVersion(_ latest: String, than current: String) -> Bool {
    let a = updateVersionParts(latest)
    let b = updateVersionParts(current)
    for index in 0..<max(a.count, b.count) {
        let left = index < a.count ? a[index] : 0
        let right = index < b.count ? b[index] : 0
        if left != right { return left > right }
    }
    return false
}

/// Pure: turns a releases-API body into a status (no I/O — unit testable).
func updateStatus(fromReleaseJSON data: Data, currentVersion: String) -> UpdateCheckStatus {
    guard
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        (object["draft"] as? Bool) != true,
        let tag = (object["tag_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
        !tag.isEmpty
    else { return .unknown }

    guard isNewerVersion(tag, than: currentVersion) else { return .upToDate }
    var version = tag
    while version.first == "v" || version.first == "V" { version.removeFirst() }
    let url = (object["html_url"] as? String).flatMap(URL.init(string:))
        ?? URL(string: "https://github.com/cinmou/MicaGo/releases/latest")!
    return .updateAvailable(version: version, url: url)
}

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    @Published private(set) var status: UpdateCheckStatus = .idle

    private static let endpoint = URL(string: "https://api.github.com/repos/cinmou/MicaGo/releases/latest")!

    /// The running Companion version from the bundle.
    static var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }

    func check() {
        guard status != .checking else { return }
        status = .checking
        Task { @MainActor in
            var request = URLRequest(url: Self.endpoint)
            request.timeoutInterval = 10
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    status = .unknown
                    return
                }
                status = updateStatus(fromReleaseJSON: data, currentVersion: Self.currentVersion)
            } catch {
                status = .unknown
            }
        }
    }
}
