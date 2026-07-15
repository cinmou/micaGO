package send

import (
	"context"
	"fmt"
	"os/exec"
	"strings"
)

type AppleScriptSender struct{}

func (s AppleScriptSender) SendText(ctx context.Context, chatGUID, message string) error {
	err := runOsascript(ctx, BuildSendToChatScript(chatGUID, message))
	if err == nil {
		return nil
	}
	// C68: Messages' AppleScript `chat id` lookup is unreliable for some 1:1
	// email handles (underscored addresses are a reproducible trigger) even
	// though the chat exists in chat.db. Fall back to sending directly to the
	// participant of the matching account — the BlueBubbles-proven path.
	if handle, service, ok := DirectHandleFromChatGUID(chatGUID); ok {
		if fallbackErr := runOsascript(ctx, BuildSendToParticipantScript(service, handle, message)); fallbackErr == nil {
			return nil
		}
	}
	return err
}

func runOsascript(ctx context.Context, script string) error {
	cmd := exec.CommandContext(ctx, "osascript", "-e", script)
	output, err := cmd.CombinedOutput()
	if err != nil {
		msg := strings.TrimSpace(string(output))
		if msg == "" {
			msg = err.Error()
		}
		return fmt.Errorf("%s", msg)
	}
	return nil
}

func BuildSendToChatScript(chatGUID, message string) string {
	return fmt.Sprintf(`tell application "Messages"
  send "%s" to chat id "%s"
end tell`, escapeAppleScriptString(message), escapeAppleScriptString(chatGUID))
}

// DirectHandleFromChatGUID extracts the participant handle from a 1:1 chat
// guid (`iMessage;-;user@example.com` / `SMS;-;+15551234567`). Group chats
// (`;+;`) and malformed guids return ok=false — the participant fallback is
// only ever valid for direct chats.
func DirectHandleFromChatGUID(chatGUID string) (handle, service string, ok bool) {
	service, rest, found := strings.Cut(chatGUID, ";-;")
	if !found || rest == "" || service == "" {
		return "", "", false
	}
	return rest, service, true
}

// BuildSendToParticipantScript sends to the handle through the matching
// account, bypassing the flaky `chat id` lookup. Messages creates/reuses the
// conversation itself.
func BuildSendToParticipantScript(service, handle, message string) string {
	serviceType := "iMessage"
	if strings.EqualFold(service, "SMS") {
		serviceType = "SMS"
	}
	return fmt.Sprintf(`tell application "Messages"
  set targetAccount to 1st account whose service type = %s
  send "%s" to participant "%s" of targetAccount
end tell`, serviceType, escapeAppleScriptString(message), escapeAppleScriptString(handle))
}

// SendAttachment sends a local file to the chat. Messages accepts a file
// reference; `POSIX file "<path>"` resolves an absolute path to that reference.
func (s AppleScriptSender) SendAttachment(ctx context.Context, chatGUID, filePath string) error {
	err := runOsascript(ctx, BuildSendAttachmentScript(chatGUID, filePath))
	if err == nil {
		return nil
	}
	// C68: same participant fallback as SendText (flaky `chat id` for some
	// 1:1 email handles).
	if handle, service, ok := DirectHandleFromChatGUID(chatGUID); ok {
		if fallbackErr := runOsascript(ctx, BuildSendAttachmentToParticipantScript(service, handle, filePath)); fallbackErr == nil {
			return nil
		}
	}
	return err
}

func BuildSendAttachmentToParticipantScript(service, handle, filePath string) string {
	serviceType := "iMessage"
	if strings.EqualFold(service, "SMS") {
		serviceType = "SMS"
	}
	return fmt.Sprintf(`tell application "Messages"
  set targetAccount to 1st account whose service type = %s
  send (POSIX file "%s") to participant "%s" of targetAccount
end tell`, serviceType, escapeAppleScriptString(filePath), escapeAppleScriptString(handle))
}

// SendAttachments sends several local files in one Messages AppleScript call.
// Messages accepts an AppleScript list of POSIX file references and groups the
// media into one outgoing message when the service supports it.
func (s AppleScriptSender) SendAttachments(ctx context.Context, chatGUID string, filePaths []string) error {
	if len(filePaths) == 0 {
		return nil
	}
	if len(filePaths) == 1 {
		return s.SendAttachment(ctx, chatGUID, filePaths[0])
	}
	script := BuildSendAttachmentsScript(chatGUID, filePaths)
	cmd := exec.CommandContext(ctx, "osascript", "-e", script)
	output, err := cmd.CombinedOutput()
	if err != nil {
		msg := strings.TrimSpace(string(output))
		if msg == "" {
			msg = err.Error()
		}
		return fmt.Errorf("%s", msg)
	}
	return nil
}

func BuildSendAttachmentScript(chatGUID, filePath string) string {
	return fmt.Sprintf(`tell application "Messages"
  send (POSIX file "%s") to chat id "%s"
end tell`, escapeAppleScriptString(filePath), escapeAppleScriptString(chatGUID))
}

func BuildSendAttachmentsScript(chatGUID string, filePaths []string) string {
	parts := make([]string, 0, len(filePaths))
	for _, path := range filePaths {
		parts = append(parts, fmt.Sprintf(`POSIX file "%s"`, escapeAppleScriptString(path)))
	}
	return fmt.Sprintf(`tell application "Messages"
  send {%s} to chat id "%s"
end tell`, strings.Join(parts, ", "), escapeAppleScriptString(chatGUID))
}

func escapeAppleScriptString(value string) string {
	value = strings.ReplaceAll(value, `\`, `\\`)
	value = strings.ReplaceAll(value, `"`, `\"`)
	return value
}
