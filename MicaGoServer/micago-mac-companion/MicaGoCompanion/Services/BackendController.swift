import Foundation
import AppKit
import Combine
import Security

/// Lifecycle state of the *companion-launched* backend process. This is purely
/// about the child process; reachability/auth come from the API poll and are
/// combined separately (see `ServerDisplayState`).
enum BackendProcessState: Equatable {
    case notInstalled   // no runnable binary found
    case stopped        // never started, or stopped cleanly by the user
    case starting       // launch requested, process not yet confirmed
    case running        // child process is alive
    case stopping       // user asked to stop; awaiting exit
    case exited(Int32)  // process ended (not a user stop), exit code
    case failed(String) // failed to launch / crashed with a summarized reason
}

/// Classified backend failure, used to drive remediation UI (esp. Full Disk
/// Access) and to suppress pointless auto-restarts.
enum BackendFailureKind: Equatable {
    case fullDiskAccess
    case addressInUse
    case messagesNotRunning
    case configInvalid
    case unknown
}

/// BackendController is the isolated, testable process manager for the bundled
/// Go relay binary. It only ever controls a process **it** launched; it never
/// touches an external/unmanaged server (see `ServerDisplayState`).
@MainActor
final class BackendController: ObservableObject {
    // Process state
    @Published private(set) var processState: BackendProcessState = .stopped
    @Published private(set) var logLines: [String] = []
    @Published private(set) var lastExitCode: Int32?
    @Published private(set) var lastStderrLine: String?
    @Published private(set) var failureKind: BackendFailureKind?
    @Published private(set) var nextRestartInfo: String?
    @Published private(set) var binarySource: String = "none"  // bundled | override | default | none

    // Persisted settings
    @Published var userBinaryPath: String { didSet { defaults.set(userBinaryPath, forKey: K.binaryPath) } }
    @Published var manageLifecycleWithApp: Bool { didSet { defaults.set(manageLifecycleWithApp, forKey: K.autoStart) } }
    @Published var autoRestart: Bool { didSet { defaults.set(autoRestart, forKey: K.autoRestart) } }
    @Published var launchHidden: Bool { didSet { defaults.set(launchHidden, forKey: K.launchHidden) } }
    // v0.11.2.1: hide the Dock icon while running menu-bar-only (no window open).
    // Persistence only — activation policy is applied centrally (applyActivationPolicy()).
    @Published var hideDockIcon: Bool { didSet { defaults.set(hideDockIcon, forKey: K.hideDockIcon) } }
    // Bind address for the companion-launched server, passed as `--addr host:port`.
    // Empty used to mean "server default"; C25 normalizes old empty/loopback
    // values to the LAN default so first launch can pair without Save/Restart.
    // This only affects the server the companion launches; it does not touch an
    // external server.
    @Published var bindAddress: String { didSet { defaults.set(bindAddress, forKey: K.bindAddress) } }

    private var process: Process?
    private var intentionalStop = false
    private var restartAttempt = 0
    private var restartWork: DispatchWorkItem?
    private var healthyResetWork: DispatchWorkItem?

    private let backoff: [TimeInterval] = [1, 2, 5, 15, 30, 60]
    private let maxConsecutiveCrashes = 5
    private static let maxLogLines = 300
    static let defaultLANBindAddress = "0.0.0.0:3000"
    private let defaults = UserDefaults.standard

    private enum K {
        static let binaryPath = "serverBinaryPath"
        static let autoStart = "autoStartServer"
        static let autoRestart = "autoRestartServer"
        static let launchHidden = "launchHidden"
        static let hideDockIcon = "hideDockIcon"
        static let bindAddress = "serverBindAddress"
    }

    init() {
        userBinaryPath = defaults.string(forKey: K.binaryPath) ?? ""
        manageLifecycleWithApp = defaults.object(forKey: K.autoStart) as? Bool ?? true
        autoRestart = defaults.bool(forKey: K.autoRestart)
        launchHidden = defaults.bool(forKey: K.launchHidden)
        hideDockIcon = defaults.bool(forKey: K.hideDockIcon)
        bindAddress = Self.normalizedLaunchBind(defaults.string(forKey: K.bindAddress))
        refreshInstalledState()
    }

    // MARK: - Binary resolution (override → NEWEST of cached/bundled)

    struct ResolvedBinary { let path: String; let source: String }

    /// C17 freshness policy. The old order (override → cached ~/.micago/bin →
    /// bundled) let a stale cached binary silently shadow newer builds — fixes
    /// like the chat.db immutable removal then never actually ran. Now:
    ///   1. An explicit user override always wins (deliberate choice).
    ///   2. Otherwise the NEWEST (by modification time) of the cached dev build
    ///      and the bundled binary wins. A fresh `scripts/build-backend.sh`
    ///      output beats an older bundle; a newer app bundle beats a stale cache.
    /// A skipped-stale candidate raises `staleBinaryWarning` — never silent.
    func resolveBinary() -> ResolvedBinary? {
        let fm = FileManager.default
        // Debug override (highest priority): launch the binary named in
        // MICAGO_BACKEND_BIN. Lets you point the Companion at a freshly-built
        // backend without touching cache-selection logic.
        let envOverride = (ProcessInfo.processInfo.environment["MICAGO_BACKEND_BIN"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !envOverride.isEmpty {
            if fm.isExecutableFile(atPath: envOverride) {
                return ResolvedBinary(path: envOverride, source: "env-override")
            }
            appendLog("backend: MICAGO_BACKEND_BIN set to \(envOverride) but it is not an executable file — ignoring")
        }
        let override = userBinaryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty, fm.isExecutableFile(atPath: override) {
            return ResolvedBinary(path: override, source: "override")
        }

        // C27: the bundled backend ships with the app and is the exact version
        // the Companion is built against, so it is ALWAYS preferred over the
        // cached `~/.micago/bin/micago` dev build. The previous "newest mtime
        // wins" could silently launch a stale cached binary (an old build with a
        // recent mtime), producing inconsistent versions across status /
        // --version / the Companion. For local backend development, point at a
        // fresh build explicitly with MICAGO_BACKEND_BIN or the binary-path
        // override above — neither of which is affected by this.
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("micago").path,
           fm.isExecutableFile(atPath: bundled) {
            return ResolvedBinary(path: bundled, source: "bundled")
        }
        let def = (NSHomeDirectory() as NSString).appendingPathComponent(".micago/bin/micago")
        if fm.isExecutableFile(atPath: def) {
            return ResolvedBinary(path: def, source: "default")
        }
        return nil
    }

    private static func modificationDate(_ path: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)
            .flatMap { $0 } ?? .distantPast
    }

    // MARK: - Version probing + stale detection (C17)

    /// One probed `--version` line, e.g.
    /// "MicaGoServer v0.15.0 commit=abc1234 buildTime=2026-06-12T11:00:00Z go=go1.26 darwin/arm64".
    /// nil line = the binary predates --version (pre-v0.15) and is stale by definition.
    @Published private(set) var launchedVersionLine: String?
    @Published private(set) var staleBinaryWarning: String?

    /// Runs `path --version` with a watchdog. Safe on old binaries: the unknown
    /// flag makes them print usage and exit instead of starting the server.
    nonisolated static func probeVersionLine(at path: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["--version"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        let deadline = DispatchTime.now() + 3
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { proc.waitUntilExit(); done.signal() }
        if done.wait(timeout: deadline) == .timedOut {
            proc.terminate()
            return nil
        }
        guard proc.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let line = String(data: data, encoding: .utf8)?
            .split(separator: "\n").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return line.hasPrefix("MicaGoServer") ? line : nil
    }

    /// Probes the resolved binary and updates `launchedVersionLine` /
    /// `staleBinaryWarning`. Called on start and from the UI's refresh action.
    func refreshBinaryFreshness() {
        guard let resolved = resolveBinary() else {
            launchedVersionLine = nil
            staleBinaryWarning = nil
            return
        }
        let line = Self.probeVersionLine(at: resolved.path)
        launchedVersionLine = line
        if line == nil {
            staleBinaryWarning = "The selected backend (\(resolved.source)) does not report a version — it predates v0.15 and is missing recent sync fixes. Rebuild it: MicaGoServer/micago-server/scripts/build-backend.sh"
        } else if resolved.source == "override" {
            // An override pins an exact binary; warn if a newer build exists elsewhere.
            let overrideDate = Self.modificationDate(resolved.path)
            let def = (NSHomeDirectory() as NSString).appendingPathComponent(".micago/bin/micago")
            let newerCached = FileManager.default.isExecutableFile(atPath: def) && Self.modificationDate(def) > overrideDate
            let bundled = Bundle.main.resourceURL?.appendingPathComponent("micago").path
            let newerBundled = bundled.map { FileManager.default.isExecutableFile(atPath: $0) && Self.modificationDate($0) > overrideDate } ?? false
            staleBinaryWarning = (newerCached || newerBundled)
                ? "A newer backend build exists, but the override path pins an older one. Clear the override or update it."
                : nil
        } else {
            staleBinaryWarning = nil
        }
        if let line { appendLog("backend freshness: \(line) [\(resolved.source)] \(resolved.path)") }
        else { appendLog("backend freshness: --version probe failed for \(resolved.path) (stale pre-v0.15 binary)") }
    }

    /// C17 Part D: stop, re-resolve (newest build wins), start, and let the
    /// status poll re-confirm the running version. Resolution happens per
    /// start(), so this simply forces the cycle and re-probes.
    func restartWithLatestBackend() {
        appendLog("restart with latest backend requested")
        refreshBinaryFreshness()
        restart()
    }

    /// Reveal the resolved backend binary in Finder ("Open backend location").
    func revealBinaryInFinder() {
        guard let path = resolvedBinaryPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    var binaryExists: Bool { resolveBinary() != nil }

    var resolvedBinaryPath: String? { resolveBinary()?.path }

    /// True while a companion-launched process is alive (or being launched).
    var isProcessAlive: Bool {
        switch processState {
        case .running, .starting, .stopping: return true
        default: return false
        }
    }

    private func refreshInstalledState() {
        if let r = resolveBinary() {
            binarySource = r.source
            if case .notInstalled = processState { processState = .stopped }
        } else {
            binarySource = "none"
            if process == nil { processState = .notInstalled }
        }
    }

    // MARK: - Lifecycle

    func start() {
        restartWork?.cancel(); restartWork = nil
        guard process == nil else { return }
        guard let resolved = resolveBinary() else {
            processState = .notInstalled
            binarySource = "none"
            appendLog("error: no runnable backend binary (set a path, or build the bundled binary)")
            return
        }

        binarySource = resolved.source
        intentionalStop = false
        failureKind = nil
        nextRestartInfo = nil
        processState = .starting
        // C17: record exactly which build we are about to launch, and warn if
        // it is a stale pre-version binary — never silently.
        refreshBinaryFreshness()

        // Debug diagnostics: which binary, why, when it was built, and what its
        // own --version reports. Makes a stale-binary mismatch obvious in the Log.
        let mtime = Self.modificationDate(resolved.path)
        appendLog("backend launch: source=\(resolved.source) path=\(resolved.path)")
        appendLog("backend launch: modified=\(mtime) version=\(launchedVersionLine ?? "<no --version (pre-v0.15 / stale)>")")
        if resolved.source == "env-override" {
            appendLog("backend launch: using MICAGO_BACKEND_BIN override")
        }

        do {
            try Self.ensureConfigFile()
        } catch {
            processState = .failed("could not create config: \(error.localizedDescription)")
            appendLog("error: failed to prepare ~/.micago/config.yaml: \(error.localizedDescription)")
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: resolved.path)
        let addr = effectiveBindAddress
        proc.arguments = ["--addr", addr]

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    self?.appendLog(String(line))
                }
            }
        }
        proc.terminationHandler = { [weak self] p in
            let code = p.terminationStatus
            Task { @MainActor in self?.handleTermination(code: code) }
        }

        do {
            try proc.run()
            process = proc
            processState = .running
            appendLog("started backend (\(resolved.source)): \(resolved.path) --addr \(addr)")
            scheduleHealthyReset()
        } catch {
            process = nil
            processState = .failed("could not launch: \(error.localizedDescription)")
            appendLog("error: failed to start backend: \(error.localizedDescription)")
        }
    }

    private static func ensureConfigFile() throws {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let dir = (home as NSString).appendingPathComponent(".micago")
        let path = (dir as NSString).appendingPathComponent("config.yaml")
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        if fm.fileExists(atPath: path) {
            if ConfigReader.read() == nil {
                throw NSError(domain: "MicaGoConfig", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "existing ~/.micago/config.yaml could not be read or has an empty auth.token"
                ])
            }
            try migrateLegacyLoopbackConfig(path: path)
            return
        }
        let token = try randomHex(byteCount: 32)
        // C17: default to all interfaces so a phone on the same LAN can pair
        // out of the box. Safe because the generated bearer token is required
        // for every API/WS call, and the server logs a loud warning for
        // non-local binds. Users can restrict to "This Mac only" in Settings.
        let body = """
        server:
          addr: "0.0.0.0:3000"
          public_url: ""

        network:
          public_base_url: ""
          verify_tls: true
          preferred_pairing_endpoint: "auto"

        auth:
          token: "\(token)"

        sync:
          interval: "5s"
          update_lookback: "168h0m0s"

        notifications:
          enabled: false
          provider: "none"
          preview: "sender"

        webhook:
          url: ""

        fcm:
          enabled: false
          project_id: ""
          service_account_path: ""

        hms:
          enabled: false
          app_id: ""
          app_secret: ""
          token_cache_path: "~/.micago/hms-token.json"

        firebase:
          public_url_sync: false
          url_collection: "server"
          url_document: "config"

        """
        try body.write(toFile: path, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    var effectiveBindAddress: String {
        Self.normalizedLaunchBind(bindAddress)
    }

    private static func normalizedLaunchBind(_ raw: String?) -> String {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch value.lowercased() {
        case "", "127.0.0.1:3000", "localhost:3000", "[::1]:3000", "::1:3000":
            return defaultLANBindAddress
        default:
            return value
        }
    }

    private static func migrateLegacyLoopbackConfig(path: String) throws {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var section = ""
        var changed = false
        let lines = text.components(separatedBy: "\n").map { raw -> String in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if !raw.hasPrefix(" "), trimmed.hasSuffix(":") {
                section = String(trimmed.dropLast())
                return raw
            }
            guard section == "server" else { return raw }
            let normalized = trimmed.replacingOccurrences(of: "\"", with: "")
            guard normalized.hasPrefix("addr:") else { return raw }
            let value = normalized.dropFirst("addr:".count).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch value {
            case "127.0.0.1:3000", "localhost:3000", "[::1]:3000", "::1:3000":
                changed = true
                let indent = raw.prefix { $0 == " " || $0 == "\t" }
                return "\(indent)addr: \"\(defaultLANBindAddress)\""
            default:
                return raw
            }
        }
        if changed {
            try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
    }

    private static func randomHex(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    func stop() {
        restartWork?.cancel(); restartWork = nil
        nextRestartInfo = nil
        guard let proc = process else { return }
        intentionalStop = true
        processState = .stopping
        appendLog("stopping backend…")
        proc.terminate()
    }

    func restart() {
        if process != nil {
            stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.intentionalStop = false
                self?.start()
            }
        } else {
            start()
        }
    }

    /// Auto-start at companion launch when lifecycle management is enabled, the
    /// binary exists, and no external/unmanaged server already answers.
    func autoStartIfNeeded(externalReachable: Bool) {
        guard manageLifecycleWithApp, process == nil, binaryExists, !externalReachable else { return }
        appendLog("auto-start: launching backend")
        start()
    }

    /// Stop our child cleanly on app quit only when the app owns lifecycle
    /// management. Never affects external processes.
    func shutdownForQuitIfNeeded() {
        guard manageLifecycleWithApp else { return }
        restartWork?.cancel()
        intentionalStop = true
        process?.terminate()
    }

    /// Force-stop our child on explicit user commands such as Stop Server.
    func shutdownForQuit() {
        restartWork?.cancel()
        intentionalStop = true
        process?.terminate()
    }

    // MARK: - Termination handling + auto-restart backoff

    private func handleTermination(code: Int32) {
        process = nil
        lastExitCode = code
        healthyResetWork?.cancel(); healthyResetWork = nil

        if intentionalStop {
            processState = .stopped
            nextRestartInfo = nil
            restartAttempt = 0
            appendLog("backend stopped")
            return
        }

        // Unexpected exit: classify from recent output.
        let kind = classifyFailure()
        failureKind = kind
        let reason = summarize(kind: kind, code: code)
        processState = .failed(reason)
        appendLog("backend exited unexpectedly (code \(code)): \(reason)")
        scheduleRestartIfEnabled(kind: kind)
    }

    private func scheduleRestartIfEnabled(kind: BackendFailureKind) {
        guard autoRestart else { nextRestartInfo = nil; return }
        if kind == .fullDiskAccess {
            nextRestartInfo = "Will not auto-restart: Full Disk Access is required."
            return
        }
        if restartAttempt >= maxConsecutiveCrashes {
            nextRestartInfo = "Stopped after \(maxConsecutiveCrashes) crashes — start manually."
            return
        }
        let delay = backoff[min(restartAttempt, backoff.count - 1)]
        restartAttempt += 1
        nextRestartInfo = "Restarting in \(Int(delay))s (attempt \(restartAttempt) of \(maxConsecutiveCrashes))…"
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.autoRestart, !self.intentionalStop, self.process == nil else { return }
            self.start()
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// If the server stays up for a while, reset the crash counter so a later,
    /// unrelated crash gets a fresh backoff budget.
    private func scheduleHealthyReset() {
        healthyResetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, case .running = self.processState else { return }
            self.restartAttempt = 0
            self.nextRestartInfo = nil
        }
        healthyResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
    }

    // MARK: - Failure classification

    private func classifyFailure() -> BackendFailureKind {
        let recent = logLines.suffix(30).joined(separator: "\n").lowercased()
        if recent.contains("operation not permitted") || recent.contains("unable to open database file") {
            return .fullDiskAccess
        }
        if recent.contains("address already in use") || recent.contains("bind:") || recent.contains("eaddrinuse") {
            return .addressInUse
        }
        if recent.contains("auth token is empty") ||
            recent.contains("read config file") ||
            recent.contains("write config file") ||
            recent.contains("stat config file") ||
            recent.contains("parse sync.") ||
            recent.contains("parse --sync-interval") ||
            recent.contains("invalid notifications.") ||
            recent.contains("invalid network.preferred_pairing_endpoint") ||
            recent.contains("invalid public_base_url") ||
            recent.contains("public_base_url must") {
            return .configInvalid
        }
        if recent.contains("messages") && recent.contains("not running") {
            return .messagesNotRunning
        }
        return .unknown
    }

    private func summarize(kind: BackendFailureKind, code: Int32) -> String {
        switch kind {
        case .fullDiskAccess: return "Full Disk Access is required to read the Messages database."
        case .addressInUse: return "The listen address is already in use (another server may be running)."
        case .configInvalid:
            if let last = lastStderrLine, !last.isEmpty {
                return "Server config error: \(last)"
            }
            return "The server configuration is missing or invalid (~/.micago/config.yaml)."
        case .messagesNotRunning: return "Messages.app is required for sending."
        case .unknown: return lastStderrLine ?? "Backend exited with code \(code)."
        }
    }

    // MARK: - Logs (with token redaction)

    private func appendLog(_ line: String) {
        let safe = Self.redact(line)
        logLines.append(safe)
        lastStderrLine = safe
        if logLines.count > Self.maxLogLines {
            logLines.removeFirst(logLines.count - Self.maxLogLines)
        }
    }

    /// Defensively mask anything that looks like a bearer/auth token so captured
    /// stdout/stderr never shows a secret (the server prints the token on first
    /// run). Replaces long hex runs and `Bearer <x>`.
    static func redact(_ line: String) -> String {
        var out = line
        if let re = try? NSRegularExpression(pattern: "[0-9a-fA-F]{24,}") {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "••••")
        }
        if let re = try? NSRegularExpression(pattern: "(?i)bearer\\s+\\S+") {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "Bearer ••••")
        }
        return out
    }
}

// MARK: - Combined display state (process + reachability)

/// What the UI shows, combining the managed process state with API reachability.
/// "externalUnmanaged" = something answers health but we did not launch it.
enum ServerDisplayState: Equatable {
    case notInstalled
    case stopped
    case starting
    case running           // managed process up + reachable
    case startingUnreachable // managed process up but not yet answering
    case stopping
    case externalUnmanaged // reachable, but not launched by us
    case crashed

    var label: String {
        switch self {
        case .notInstalled: return "No backend installed"
        case .stopped: return "Stopped"
        case .starting, .startingUnreachable: return "Starting…"
        case .running: return "Running"
        case .stopping: return "Stopping…"
        case .externalUnmanaged: return "External server (unmanaged)"
        case .crashed: return "Crashed"
        }
    }

    /// Short label for the compact toolbar status capsule (e.g. "Running",
    /// "Stopped", "External"). The longer `label` is used elsewhere.
    var compactLabel: String {
        switch self {
        case .notInstalled: return "Not installed"
        case .stopped: return "Stopped"
        case .starting, .startingUnreachable: return "Starting…"
        case .running: return "Running"
        case .stopping: return "Stopping…"
        case .externalUnmanaged: return "External"
        case .crashed: return "Crashed"
        }
    }

    var isHealthyDot: Bool {
        switch self {
        case .running, .externalUnmanaged: return true
        default: return false
        }
    }
}

func serverDisplayState(process: BackendProcessState, reachable: Bool) -> ServerDisplayState {
    switch process {
    case .running:
        return reachable ? .running : .startingUnreachable
    case .starting:
        return .starting
    case .stopping:
        return .stopping
    case .notInstalled:
        return reachable ? .externalUnmanaged : .notInstalled
    case .stopped:
        return reachable ? .externalUnmanaged : .stopped
    case .exited, .failed:
        return reachable ? .externalUnmanaged : .crashed
    }
}
