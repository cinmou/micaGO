package send

import (
	"strings"
	"testing"
)

func TestEscapeAppleScriptString(t *testing.T) {
	got := escapeAppleScriptString(`a "quote" and \ slash`)
	if got != `a \"quote\" and \\ slash` {
		t.Fatalf("unexpected escaped string: %q", got)
	}
}

func TestBuildSendToChatScript(t *testing.T) {
	script := BuildSendToChatScript(`iMessage;-;abc"123`, `hello "world"`)
	if !strings.Contains(script, `send "hello \"world\""`) {
		t.Fatalf("expected escaped message in script: %s", script)
	}
	if !strings.Contains(script, `chat id "iMessage;-;abc\"123"`) {
		t.Fatalf("expected escaped chat guid in script: %s", script)
	}
}

func TestBuildSendAttachmentScript(t *testing.T) {
	script := BuildSendAttachmentScript("iMessage;-;+1555", `/tmp/ab cd/photo".jpg`)
	if !strings.Contains(script, `POSIX file "/tmp/ab cd/photo\".jpg"`) {
		t.Fatalf("path not escaped into POSIX file: %s", script)
	}
	if !strings.Contains(script, `to chat id "iMessage;-;+1555"`) {
		t.Fatalf("chat id missing: %s", script)
	}
}

func TestBuildSendAttachmentsScript(t *testing.T) {
	script := BuildSendAttachmentsScript("iMessage;-;+1555", []string{
		`/tmp/one.jpg`,
		`/tmp/two "quoted".mov`,
	})
	if !strings.Contains(script, `{POSIX file "/tmp/one.jpg", POSIX file "/tmp/two \"quoted\".mov"}`) {
		t.Fatalf("expected POSIX file list: %s", script)
	}
	if !strings.Contains(script, `to chat id "iMessage;-;+1555"`) {
		t.Fatalf("chat id missing: %s", script)
	}
}

func TestDirectHandleFromChatGUID(t *testing.T) {
	handle, service, ok := DirectHandleFromChatGUID("iMessage;-;user_name@example.com")
	if !ok || handle != "user_name@example.com" || service != "iMessage" {
		t.Fatalf("direct email guid: got %q %q %v", handle, service, ok)
	}
	handle, service, ok = DirectHandleFromChatGUID("SMS;-;+15551234567")
	if !ok || handle != "+15551234567" || service != "SMS" {
		t.Fatalf("direct sms guid: got %q %q %v", handle, service, ok)
	}
	// Group chats and malformed guids must not use the participant fallback.
	if _, _, ok := DirectHandleFromChatGUID("iMessage;+;chat123456"); ok {
		t.Fatal("group guid must not parse as direct")
	}
	if _, _, ok := DirectHandleFromChatGUID("garbage"); ok {
		t.Fatal("malformed guid must not parse as direct")
	}
}

func TestBuildSendToParticipantScript(t *testing.T) {
	script := BuildSendToParticipantScript("iMessage", `user_name@example.com`, `hi "there"`)
	if !strings.Contains(script, `participant "user_name@example.com"`) {
		t.Fatalf("participant missing: %s", script)
	}
	if !strings.Contains(script, `send "hi \"there\""`) {
		t.Fatalf("message not escaped: %s", script)
	}
	if !strings.Contains(script, "service type = iMessage") {
		t.Fatalf("service type missing: %s", script)
	}
	sms := BuildSendToParticipantScript("SMS", "+15551234567", "x")
	if !strings.Contains(sms, "service type = SMS") {
		t.Fatalf("sms service type missing: %s", sms)
	}
	att := BuildSendAttachmentToParticipantScript("iMessage", "a@b.com", "/tmp/pic.jpg")
	if !strings.Contains(att, `POSIX file "/tmp/pic.jpg"`) {
		t.Fatalf("attachment path missing: %s", att)
	}
}
