#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
TASK_TMP=$(mktemp -d)
trap 'rm -rf "$TASK_TMP"' EXIT
cat > "$TASK_TMP/main.swift" <<'SWIFT'
import Foundation

@main
struct Tests {
    @MainActor static func main() {
        let opener = DashboardWindowOpener()
        var opened = 0
        opener.requestOpen()
        opener.requestOpen()
        precondition(opened == 0, "early requests wait for the SwiftUI scene")
        opener.install { opened += 1 }
        precondition(opened == 1, "early requests open exactly one scene when ready")
        opener.install { opened += 10 }
        precondition(opened == 1, "installing an action does not show a silent-launch window")
        opener.requestOpen()
        precondition(opened == 11, "subsequent opens use the current scene action")
        let decoder = JSONDecoder()
        func diagnostics(_ at: Int64) -> SyncDiagnostics {
            try! decoder.decode(SyncDiagnostics.self, from: Data("{\"lastCompletedAt\":\(at)}".utf8))
        }
        precondition(SyncDiagnostics.latest(live: diagnostics(20), manual: diagnostics(10))?.lastCompletedAt == 20,
                     "live polling supersedes the old manual result")
        precondition(SyncDiagnostics.latest(live: diagnostics(10), manual: diagnostics(20))?.lastCompletedAt == 20,
                     "a fresh manual result remains visible until polling catches up")
        precondition(SyncDiagnostics.latest(live: nil, manual: diagnostics(20))?.lastCompletedAt == 20,
                     "manual results work before the first status response")
        let old = NotificationFormValues(enabled: false, preview: "sender", fcmEnabled: false, projectID: "old", publicURLSync: false)
        var remote = old
        remote.preview = "none"
        remote.publicURLSync = true
        remote.projectID = "new"
        precondition(old.merging(server: remote, previousServer: old) == remote,
                     "remote privacy/project/Firestore changes update an unedited form")
        var edited = old
        edited.projectID = "unsaved"
        let merged = edited.merging(server: remote, previousServer: old)
        precondition(merged.projectID == "unsaved" && merged.preview == "none" && merged.publicURLSync,
                     "unsaved edits survive while untouched fields follow the server")
        print("dashboard window request tests passed")
    }
}
SWIFT
xcrun swiftc -parse-as-library MicaGoCompanion/Services/DashboardWindowOpener.swift MicaGoCompanion/Models/StatusModels.swift MicaGoCompanion/Models/NotificationsModels.swift "$TASK_TMP/main.swift" -o "$TASK_TMP/test"
"$TASK_TMP/test"
