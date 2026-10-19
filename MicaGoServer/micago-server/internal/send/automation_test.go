package send

import (
	"strings"
	"testing"
)

// C79: the Automation diagnostic used to be a hardcoded "unknown". These pin the
// classification of what macOS actually returns, so a future refactor cannot
// quietly go back to guessing.
func TestClassifyAutomationOutput(t *testing.T) {
	cases := []struct {
		name   string
		output string
		want   string
	}{
		{
			name:   "denied by OSStatus code",
			output: "execution error: Not authorized to send Apple events to Messages. (-1743)",
			want:   "denied",
		},
		{
			name:   "denied by message text only",
			output: "execution error: not authorized to send apple events",
			want:   "denied",
		},
		{
			name:   "other failures stay unknown, never a false denial",
			output: "execution error: Application isn't running. (-600)",
			want:   "unknown",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			message := strings.ToLower(strings.TrimSpace(tc.output))
			got := "unknown"
			if strings.Contains(message, automationDeniedCode) ||
				strings.Contains(message, automationDeniedText) {
				got = "denied"
			}
			if got != tc.want {
				t.Fatalf("classified %q as %s, want %s", tc.output, got, tc.want)
			}
		})
	}
}
