import Foundation

/// C26: installs the micaGO IMCore helper (the binary that performs the advanced
/// iMessage actions — edit / unsend / delete) into `~/.micago/bin`, which the
/// backend scans on startup. micaGO controls this end-to-end; users never have
/// to install imsg/imsgbridge by hand.
///
/// The helper is expected to ship inside the app bundle. When a build does not
/// include it, `install()` throws a clear, honest error rather than pretending
/// to succeed — the message-action features stay hidden until a helper is
/// actually present (the backend reports the capability either way).
enum IMCoreHelperInstaller {
    enum InstallError: LocalizedError {
        case notBundled
        case ioFailure(String)

        var errorDescription: String? {
            switch self {
            case .notBundled:
                return "This micaGO build does not include the IMCore helper component yet, "
                    + "so it can’t be installed automatically. Edit, Unsend, and Delete stay "
                    + "hidden until a build that bundles the helper is installed."
            case .ioFailure(let detail):
                return "Could not install the IMCore helper: \(detail)"
            }
        }
    }

    /// The canonical helper filename the backend looks for first.
    static let helperName = "micago-imcore-helper"
    private static let candidateNames = ["micago-imcore-helper", "MicaGoIMCoreHelper"]

    /// Locates a bundled helper binary, copies it into `~/.micago/bin`, marks it
    /// executable, and returns the installed path.
    @discardableResult
    static func install() throws -> String {
        let fm = FileManager.default
        guard let source = bundledHelperURL() else {
            throw InstallError.notBundled
        }

        let dir = installDirectory()
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(helperName)
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: source, to: dest)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
            return dest.path
        } catch {
            throw InstallError.ioFailure(error.localizedDescription)
        }
    }

    /// `~/.micago/bin` — the stable install location the backend also scans.
    static func installDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".micago/bin", isDirectory: true)
    }

    /// True when a helper is already installed in `~/.micago/bin`.
    static var isInstalled: Bool {
        let dest = installDirectory().appendingPathComponent(helperName)
        return FileManager.default.isExecutableFile(atPath: dest.path)
    }

    /// Finds a helper binary shipped inside the app bundle (Resources or the
    /// bundle root), if any.
    private static func bundledHelperURL() -> URL? {
        let fm = FileManager.default
        for name in candidateNames {
            if let url = Bundle.main.url(forResource: name, withExtension: nil),
               fm.isReadableFile(atPath: url.path) {
                return url
            }
        }
        // Also check the bundle's Resources directory directly.
        if let resources = Bundle.main.resourceURL {
            for name in candidateNames {
                let url = resources.appendingPathComponent(name)
                if fm.isReadableFile(atPath: url.path) {
                    return url
                }
            }
        }
        return nil
    }
}
