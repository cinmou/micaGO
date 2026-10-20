#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
TASK_TMP=$(mktemp -d)
trap 'rm -rf "$TASK_TMP"' EXIT
cat > "$TASK_TMP/backend" <<'PY'
#!/usr/bin/python3
import os, signal, sys, time
if '--version' in sys.argv:
    print('MicaGoServer v0.88.0 fixture')
    sys.exit(0)
def stop(*args):
    time.sleep(1.3)
    sys.exit(0)
signal.signal(signal.SIGTERM, stop)
with open(os.environ['MICAGO_TEST_STARTS'], 'a') as stream:
    stream.write(str(os.getpid()) + '\n')
while True:
    time.sleep(0.05)
PY
chmod +x "$TASK_TMP/backend"
cat > "$TASK_TMP/main.swift" <<'SWIFT'
import Foundation

// Only needed by the updater resume path, which this process test does not use.
@MainActor final class AppModel {
    static let shared = AppModel()
    var reachable = false
    func refresh() async {}
}

@main struct Tests {
    @MainActor static func main() async {
        let fixture = CommandLine.arguments[1]
        let suite = "micago-backend-restart-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(fixture, forKey: "serverBinaryPath")
        let controller = BackendController(defaults: defaults, prepareConfiguration: {})
        controller.autoRestart = false
        func count() -> Int {
            let path = ProcessInfo.processInfo.environment["MICAGO_TEST_STARTS"]!
            return ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n").count
        }
        func settle(_ condition: () -> Bool) async {
            for _ in 0..<400 {
                if condition() { return }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            preconditionFailure("backend lifecycle did not settle")
        }
        controller.start()
        await settle { count() == 1 }
        controller.restart()
        try? await Task.sleep(nanoseconds: 900_000_000)
        precondition(count() == 1 && controller.processState == .stopping,
                     "slow shutdown must not launch a replacement early")
        await settle { count() == 2 && controller.processState == .running }
        controller.restart()
        controller.restart()
        controller.stop()
        await settle { controller.processState == .stopped }
        try? await Task.sleep(nanoseconds: 900_000_000)
        precondition(count() == 2, "Stop must cancel pending restarts")
        print("backend slow-exit restart and cancellation tests passed")
    }
}
SWIFT
xcrun swiftc -parse-as-library MicaGoCompanion/Services/BackendController.swift MicaGoCompanion/Services/ConfigReader.swift MicaGoCompanion/Localization.swift "$TASK_TMP/main.swift" -o "$TASK_TMP/test"
MICAGO_TEST_STARTS="$TASK_TMP/starts" "$TASK_TMP/test" "$TASK_TMP/backend"
