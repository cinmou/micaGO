import Foundation

/// The values the companion needs from ~/.micago/config.yaml.
struct MicaConfig {
    var addr: String
    var token: String
}

/// 只读取后端生成的地址和凭据，不改写配置。
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
            case ("auth", "token"): token = value
            default: break
            }
        }

        guard !token.isEmpty else { return nil }
        return MicaConfig(addr: addr, token: token)
    }

    /// 自有进程使用实际启动端口，其余情况使用配置中的端口。
    static func baseURL(for config: MicaConfig, launchedAddress: String? = nil) -> URL? {
        let (host, port) = controlHostPort(launchedAddress ?? config.addr)
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = host
        comps.port = port
        return comps.url
    }

    /// 控制接口固定连接 IPv4 loopback；缺失或无效端口回退到 3000。
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

        let port = Int(portText).flatMap { (1...65535).contains($0) ? $0 : nil } ?? 3000
        return ("127.0.0.1", port)
    }
}
