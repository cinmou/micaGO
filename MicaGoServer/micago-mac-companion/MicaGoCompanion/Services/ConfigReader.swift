import Foundation

/// The values the companion needs from ~/.micago/config.yaml.
struct MicaConfig {
    var addr: String
    var token: String
    var publicURL: String?
    var configPath: String
}

/// Reads ~/.micago/config.yaml using the same lightweight line parsing the
/// smoke scripts use. The server writes a flat, predictable YAML, so a full
/// YAML parser is unnecessary (and avoids a dependency).
enum ConfigReader {
    static var configPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".micago/config.yaml")
    }

    static func read() -> MicaConfig? {
        let path = configPath
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }

        var addr = "0.0.0.0:3000"
        var token = ""
        var publicURL: String?
        var publicBaseURL: String?
        var section = ""

        for rawLine in text.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            if !rawLine.hasPrefix(" ") && trimmed.hasSuffix(":") {
                section = String(trimmed.dropLast())
                continue
            }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))

            switch (section, key) {
            case ("server", "addr"): addr = value
            case ("server", "public_url"): if !value.isEmpty { publicURL = value }
            case ("network", "public_base_url"): if !value.isEmpty { publicBaseURL = value }
            case ("auth", "token"): token = value
            default: break
            }
        }

        guard !token.isEmpty else { return nil }
        return MicaConfig(addr: addr, token: token, publicURL: publicBaseURL ?? publicURL, configPath: path)
    }

    /// Safe local control URL. Built with URLComponents from a validated
    /// host/port — never by string concatenation — so a host-less Go listen
    /// address like ":3000" can never produce a malformed "http://:3000"
    /// request (the C18 ":3000/api/health" bug).
    static func baseURL(for config: MicaConfig) -> URL? {
        let (host, port) = controlHostPort(config.addr)
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = host
        comps.port = port
        return comps.url
    }

    /// Back-compat string form of the control endpoint ("host:port").
    static func controlAddress(_ addr: String) -> String {
        let (host, port) = controlHostPort(addr)
        return "\(host):\(port)"
    }

    /// The Companion's control API must always talk to the local backend, never
    /// to the optional public/tunnel URL. Any-address binds (0.0.0.0, ::, [::],
    /// and Go's host-less ":3000") mean "listen everywhere"; the companion
    /// connects via IPv4 loopback for every bind. The result has a non-empty host and a
    /// valid port (default 3000), so URL construction cannot fail.
    static func controlHostPort(_ addr: String) -> (host: String, port: Int) {
        let trimmed = addr.trimmingCharacters(in: .whitespacesAndNewlines)

        var portText = ""
        if trimmed.hasPrefix("[") {
            // Bracketed IPv6: "[::1]:3000" or "[::1]".
            if let close = trimmed.firstIndex(of: "]") {
                let rest = trimmed[trimmed.index(after: close)...]
                if rest.hasPrefix(":") { portText = String(rest.dropFirst()) }
            }
        } else {
            let colonCount = trimmed.filter { $0 == ":" }.count
            if colonCount == 1, let colon = trimmed.firstIndex(of: ":") {
                // "host:port" — including ":3000" with an empty host.
                portText = String(trimmed[trimmed.index(after: colon)...])
            }
        }

        // The backend keeps the control listener on IPv4 loopback even when
        // its encrypted client listener binds to a specific LAN address.
        let port = Int(portText).flatMap { (1...65535).contains($0) ? $0 : nil } ?? 3000
        return ("127.0.0.1", port)
    }
}
