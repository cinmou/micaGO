import Foundation
import Combine

/// Lifecycle of the *companion-launched* cloudflared tunnel.
enum TunnelState: Equatable {
    case stopped
    case starting
    case running
    case failed(String)
    case runningExternally // a cloudflared we did not launch is already up
    case unknown
}

/// Optional integration with an **already-configured** Cloudflare Tunnel.
///
/// micaGO never logs into Cloudflare, creates tunnels/DNS, or bundles/downloads
/// cloudflared. It only runs an existing local `cloudflared tunnel run <name>`
/// if the user enables it, so the public URL keeps working without Terminal.
@MainActor
final class TunnelController: ObservableObject {
    static let shared = TunnelController()

    // Discovery
    @Published private(set) var installed = false
    @Published private(set) var configFound = false
    @Published private(set) var tunnelName = "micago-server"
    @Published private(set) var publicHostname = ""
    @Published private(set) var cloudflaredPath: String?

    // Runtime
    @Published private(set) var state: TunnelState = .stopped
    @Published private(set) var logLines: [String] = []
    @Published private(set) var lastError: String?
    @Published private(set) var retryDelay: TimeInterval?

    // Persisted settings
    @Published var startWithServer: Bool {
        didSet {
            defaults.set(startWithServer, forKey: K.startWithServer)
            if !startWithServer { cancelRecovery() }
        }
    }
    @Published var stopWithServer: Bool {
        didSet {
            defaults.set(stopWithServer, forKey: K.stopWithServer)
            if stopWithServer && lastObservedServerHealthy == false { stop() }
        }
    }

    var publicURL: String { publicHostname.isEmpty ? "" : "https://\(publicHostname)" }

    private var process: Process?
    private var intentionalStop = false
    private let defaults: UserDefaults
    private let externalProbe: () -> Bool
    private let makeProcess: (String, String) -> Process
    private let sleep: (TimeInterval) async throws -> Void
    private let uptime: () -> TimeInterval
    private var recovery = TunnelRecovery()
    private var retryTask: Task<Void, Never>?
    private var retryGeneration = UUID()
    private var processGeneration: UUID?
    private var outputHandle: FileHandle?
    private var connectedAt: TimeInterval?
    private var restartAfterTermination = false
    private var quitting = false
    private var lifecycleGeneration = UUID()
    private var discoveryGeneration = UUID()
    private var processOutput = ""
    private static let maxLogLines = 200

    private enum K {
        static let startWithServer = "tunnelStartWithServer"
        static let stopWithServer = "tunnelStopWithServer"
    }

    init(
        defaults: UserDefaults = .standard,
        configuration: (path: String, tunnelName: String)? = nil,
        externalProbe: @escaping () -> Bool = { TunnelController.externalTunnelRunning() },
        makeProcess: @escaping (String, String) -> Process = { path, name in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: path)
            proc.arguments = ["tunnel", "run", name]
            return proc
        },
        sleep: @escaping (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        },
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.defaults = defaults
        self.externalProbe = externalProbe
        self.makeProcess = makeProcess
        self.sleep = sleep
        self.uptime = uptime
        startWithServer = defaults.bool(forKey: K.startWithServer)
        stopWithServer = defaults.bool(forKey: K.stopWithServer)
        // C18: discovery is async, off the main thread. The old synchronous init
        // (login-shell `command -v` + pgrep, each with waitUntilExit) ran during
        // app bootstrap and could delay backend auto-start. The backend never
        // waits on tunnel discovery; the tunnel is purely optional.
        if let configuration {
            cloudflaredPath = configuration.path
            tunnelName = configuration.tunnelName
            installed = true
            configFound = true
        } else {
            refreshDiscovery()
        }
    }

    var isProcessAlive: Bool {
        switch state {
        case .starting, .running: return true
        default: return false
        }
    }

    // MARK: - Discovery (async, never blocks the main thread)

    /// Result bundle produced by the background probes.
    private struct Discovery: Sendable {
        let cloudflaredPath: String?
        let configFound: Bool
        let tunnelName: String?
        let publicHostname: String?
        let externalRunning: Bool
    }

    /// Re-detects cloudflared, the config file, tunnel name + hostname, and any
    /// externally-running tunnel. All probes (file stats, login shell, pgrep)
    /// run detached; only the published-state update touches the main actor.
    func refreshDiscovery() {
        let generation = UUID()
        discoveryGeneration = generation
        let observedLifecycle = lifecycleGeneration
        Task.detached(priority: .utility) { [weak self] in
            let path = Self.findCloudflared()
            let config = Self.readConfigFile()
            let external = Self.externalTunnelRunning()
            let discovery = Discovery(
                cloudflaredPath: path,
                configFound: config != nil,
                tunnelName: config?.tunnelName,
                publicHostname: config?.hostname,
                externalRunning: external
            )
            await self?.apply(discovery, generation: generation, observedLifecycle: observedLifecycle)
        }
    }

    private func apply(_ d: Discovery, generation: UUID, observedLifecycle: UUID) {
        guard discoveryGeneration == generation, !quitting else { return }
        cloudflaredPath = d.cloudflaredPath
        installed = d.cloudflaredPath != nil
        configFound = d.configFound
        if let name = d.tunnelName, !name.isEmpty { tunnelName = name }
        if let host = d.publicHostname, !host.isEmpty, publicHostname.isEmpty {
            publicHostname = host
        }
        if process == nil && lifecycleGeneration == observedLifecycle {
            if d.externalRunning {
                cancelRecovery()
                lastError = nil
                state = .runningExternally
            } else if state == .runningExternally {
                state = .stopped
            }
        }
    }

    private nonisolated static func readConfigFile() -> (tunnelName: String?, hostname: String?)? {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".cloudflared/config.yml")
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        var name: String?
        var hostname: String?
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("tunnel:") {
                let v = line.dropFirst("tunnel:".count).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                if !v.isEmpty { name = v }
            } else if line.hasPrefix("- hostname:") || line.hasPrefix("hostname:") {
                let v = line.replacingOccurrences(of: "- hostname:", with: "")
                    .replacingOccurrences(of: "hostname:", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                if !v.isEmpty && hostname == nil { hostname = v }
            }
        }
        return (name, hostname)
    }

    /// Locates cloudflared in common install paths, then the login-shell PATH.
    /// nonisolated: must only run from the detached discovery task (the login
    /// shell can take seconds and must never block the main actor).
    private nonisolated static func findCloudflared() -> String? {
        let fm = FileManager.default
        let candidates = [
            "/opt/homebrew/bin/cloudflared",
            "/usr/local/bin/cloudflared",
            "/usr/bin/cloudflared",
        ]
        for c in candidates where fm.isExecutableFile(atPath: c) {
            return c
        }
        // Fall back to the user's PATH via a login shell.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", "command -v cloudflared"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !out.isEmpty, fm.isExecutableFile(atPath: out) { return out }
        } catch {}
        return nil
    }

    /// True if a `cloudflared tunnel run` process is already running.
    private nonisolated static func externalTunnelRunning() -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        proc.arguments = ["-f", "cloudflared tunnel run"]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard !quitting, process == nil else { return }
        lifecycleGeneration = UUID()
        cancelRecovery()
        recovery.arm()
        launch()
    }

    /// Only our child-process lifetime is supervised. cloudflared itself owns
    /// connection retries while alive; never spawn a second copy for a 530.
    private func launch() {
        guard !quitting, process == nil, recovery.enabled else { return }
        lifecycleGeneration = UUID()
        guard let path = cloudflaredPath, configFound else {
            cancelRecovery()
            let reason = cloudflaredPath == nil
                ? "cloudflared is not installed." : "No ~/.cloudflared/config.yml found."
            state = .failed(reason)
            lastError = reason
            return
        }
        if externalProbe() {
            cancelRecovery()
            lastError = nil
            state = .runningExternally
            appendLog("a cloudflared tunnel is already running (not launched by micaGO)")
            return
        }

        intentionalStop = false
        lastError = nil
        connectedAt = nil
        processOutput = ""
        state = .starting
        let generation = UUID()
        processGeneration = generation
        let proc = makeProcess(path, tunnelName)
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        outputHandle = pipe.fileHandleForReading
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                guard let self, self.processGeneration == generation, !self.intentionalStop else { return }
                self.processOutput += text
                while let end = self.processOutput.firstIndex(of: "\n") {
                    let line = String(self.processOutput[..<end])
                    self.processOutput.removeSubrange(...end)
                    self.appendLog(line)
                    if line.contains("Registered tunnel connection") { self.markRunning() }
                }
            }
        }
        proc.terminationHandler = { [weak self] p in
            let code = p.terminationStatus
            Task { @MainActor in self?.handleTermination(code: code, generation: generation) }
        }
        do {
            try proc.run()
            process = proc
            appendLog("started cloudflared tunnel run \(tunnelName)")
        } catch {
            releaseProcess()
            state = .failed("could not launch cloudflared: \(error.localizedDescription)")
            lastError = error.localizedDescription
            appendLog("error: \(error.localizedDescription)")
            scheduleRecovery()
        }
    }

    func stop() {
        lifecycleGeneration = UUID()
        cancelRecovery()
        restartAfterTermination = false
        intentionalStop = true
        guard let proc = process else {
            if state != .runningExternally { state = .stopped; lastError = nil }
            return
        }
        appendLog("stopping tunnel…")
        if proc.isRunning { proc.terminate() }
    }

    func restart() {
        guard !quitting else { return }
        stop()
        if process != nil {
            // Restart after this exact child exits, rather than guessing how
            // long terminate() takes. A later Stop/quit cancels this intent.
            restartAfterTermination = true
        } else {
            start()
        }
    }

    private var lastObservedServerHealthy: Bool?

    /// The tunnel optionally FOLLOWS server health ("start/stop tunnel with
    /// server"); the backend never depends on the tunnel. Decisions come from
    /// the pure TunnelAutopilot and fire only on health transitions, so a
    /// steady poll loop cannot repeatedly retry a failed tunnel, and a backend
    /// that is simply down at app launch never kills anything.
    func serverHealthChanged(healthy: Bool) {
        let action = TunnelAutopilot.decide(
            previousHealthy: lastObservedServerHealthy,
            healthy: healthy,
            startWithServer: startWithServer,
            stopWithServer: stopWithServer,
            tunnelUsable: installed && configFound,
            tunnelStopped: state == .stopped,
            tunnelProcessAlive: process != nil
        )
        let previousHealthy = lastObservedServerHealthy
        lastObservedServerHealthy = healthy
        // A failed child has no Process, but may still have a pending restart.
        if previousHealthy == true && !healthy && stopWithServer && recovery.enabled {
            stop()
            return
        }
        switch action {
        case .none: break
        case .start: start()
        case .stop: stop()
        }
    }

    /// Stop our child on app quit (never affects external processes).
    func shutdownForQuit() {
        quitting = true
        stop()
    }

    private func markRunning() {
        if state == .starting {
            connectedAt = uptime()
            state = .running
            appendLog("tunnel connected")
        }
    }

    private func releaseProcess() {
        lifecycleGeneration = UUID()
        outputHandle?.readabilityHandler = nil
        outputHandle = nil
        process = nil
        processGeneration = nil
    }

    private func handleTermination(code: Int32, generation: UUID) {
        guard processGeneration == generation else { return }
        let stableFor = connectedAt.map { uptime() - $0 } ?? 0
        connectedAt = nil
        releaseProcess()
        if intentionalStop {
            state = .stopped
            lastError = nil
            appendLog("tunnel stopped")
            if restartAfterTermination && !quitting {
                restartAfterTermination = false
                start()
            }
            return
        }
        let reason = code == 0 ? "tunnel exited" : "tunnel exited (code \(code))"
        state = .failed(reason)
        lastError = reason
        appendLog(reason)
        recovery.didDisconnect(stableFor: stableFor)
        scheduleRecovery()
    }

    private func cancelRecovery() {
        retryTask?.cancel()
        retryTask = nil
        retryGeneration = UUID()
        retryDelay = nil
        restartAfterTermination = false
        recovery.cancel()
    }

    private func scheduleRecovery() {
        guard !quitting, process == nil, retryTask == nil,
              let delay = recovery.nextDelay() else { return }
        retryDelay = delay
        let generation = UUID()
        retryGeneration = generation
        appendLog("retrying tunnel in \(Int(delay))s")
        retryTask = Task { [weak self, sleep] in
            do { try await sleep(delay) } catch { return }
            guard let self, !Task.isCancelled, self.retryGeneration == generation else { return }
            self.retryTask = nil
            self.retryDelay = nil
            self.launch()
        }
    }

    private func appendLog(_ line: String) {
        // Defensive redaction — cloudflared logs are normally safe, but never
        // surface anything token-like.
        var safe = line
        if safe.lowercased().contains("token") { safe = "<redacted line>" }
        logLines.append(safe)
        if logLines.count > Self.maxLogLines {
            logLines.removeFirst(logLines.count - Self.maxLogLines)
        }
    }
}
