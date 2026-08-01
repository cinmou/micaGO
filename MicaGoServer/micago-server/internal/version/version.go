// Package version is the single source of truth for the backend build
// identity. It exists so the companion (and a human with --version) can prove
// WHICH binary is actually running — C17's root problem was a stale cached
// binary at ~/.micago/bin/micago silently shadowing newer builds.
package version

import (
	"fmt"
	"runtime"
	"runtime/debug"
)

// Version is the semantic version of the backend. Bumped per milestone.
var Version = "v0.68.0"

// Commit and BuildTime are injected at build time via:
//
//	go build -ldflags "-X micagoserver/internal/version.Commit=<sha> \
//	                   -X micagoserver/internal/version.BuildTime=<RFC3339>"
//
// (see scripts/build-backend.sh). When absent — e.g. a plain `go build` or
// `go run` — they fall back to the VCS stamp Go embeds automatically, and to
// "unknown" as the last resort, never an empty string.
var (
	Commit    = ""
	BuildTime = ""
)

// resolved returns commit and build time, preferring ldflags, then the
// debug.BuildInfo VCS stamp, then "unknown".
func resolved() (commit, buildTime string) {
	commit, buildTime = Commit, BuildTime
	if commit != "" && buildTime != "" {
		return commit, buildTime
	}
	if info, ok := debug.ReadBuildInfo(); ok {
		for _, s := range info.Settings {
			switch s.Key {
			case "vcs.revision":
				if commit == "" && len(s.Value) >= 7 {
					commit = s.Value[:7]
				}
			case "vcs.time":
				if buildTime == "" {
					buildTime = s.Value
				}
			}
		}
	}
	if commit == "" {
		commit = "unknown"
	}
	if buildTime == "" {
		buildTime = "unknown"
	}
	return commit, buildTime
}

// ResolvedCommit returns the short commit hash (ldflags → VCS stamp → "unknown").
func ResolvedCommit() string { c, _ := resolved(); return c }

// ResolvedBuildTime returns the build timestamp (ldflags → VCS stamp → "unknown").
func ResolvedBuildTime() string { _, b := resolved(); return b }

// GoVersion returns the Go toolchain that built this binary.
func GoVersion() string { return runtime.Version() }

// OSArch returns the target platform, e.g. "darwin/arm64".
func OSArch() string { return runtime.GOOS + "/" + runtime.GOARCH }

// String is the one-line identity printed by --version and logged at startup:
//
//	MicaGoServer v0.26.0 commit=abc1234 buildTime=2026-06-12T04:00:00Z go=go1.22.1 darwin/arm64
func String() string {
	commit, buildTime := resolved()
	return fmt.Sprintf("MicaGoServer %s commit=%s buildTime=%s go=%s %s",
		Version, commit, buildTime, GoVersion(), OSArch())
}
