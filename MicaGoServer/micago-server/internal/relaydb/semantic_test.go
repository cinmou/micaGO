package relaydb

import (
	"context"
	"testing"

	"micagoserver/internal/store"
)

// fakeSemanticSource feeds one chat + one reaction message carrying the
// BlueBubbles-compatible semantic fields through SyncOnce.
type fakeSemanticSource struct {
	chats       []store.SyncChatRow
	messages    []store.SyncMessageRow
	attachments []store.SyncAttachmentRow
}

func (f fakeSemanticSource) ListSyncChats(context.Context) ([]store.SyncChatRow, error) {
	return f.chats, nil
}
func (f fakeSemanticSource) ListSyncRecentMessages(context.Context, int) ([]store.SyncMessageRow, error) {
	return f.messages, nil
}
func (f fakeSemanticSource) ListSyncRecentMessagesSince(context.Context, int64, int) ([]store.SyncMessageRow, error) {
	return f.messages, nil
}
func (f fakeSemanticSource) ListSyncAttachmentsForMessages(context.Context, []string) ([]store.SyncAttachmentRow, error) {
	return f.attachments, nil
}

func strp(s string) *string { return &s }
func intp(n int64) *int64   { return &n }

// TestRenderableChatHiding verifies a chat whose only content is debug-only
// (control-like "noise") is hidden from the normal chat list and revealed with
// the debug flag, with the right summary fields.
func TestRenderableChatHiding(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()

	src := fakeSemanticSource{
		chats: []store.SyncChatRow{
			{GUID: "good", ServiceName: strp("iMessage")},
			{GUID: "noise", ServiceName: strp("iMessage")},
		},
		messages: []store.SyncMessageRow{
			{ChatGUID: "good", SourceRowID: 1, GUID: "g1", Text: strp("hello there"), DateCreated: intp(2000)},
			// Control-like text is synced (has text) but classified debug-only.
			{ChatGUID: "noise", SourceRowID: 2, GUID: "n1", Text: strp("+!"), DateCreated: intp(1000)},
		},
	}
	if _, err := SyncOnce(ctx, src, db, 100, 0); err != nil {
		t.Fatalf("sync: %v", err)
	}

	// Default (renderable) list hides the noise-only chat.
	visible, err := db.ListChats(ctx, 50, 0, true, "all", false)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(visible) != 1 || visible[0].GUID != "good" {
		t.Fatalf("default list = %+v, want only [good]", guids(visible))
	}
	good := visible[0]
	if !good.HasRenderableMessages || good.UnsupportedOnly {
		t.Fatalf("good chat flags wrong: %+v", good)
	}
	if good.LatestRenderablePreview == nil || *good.LatestRenderablePreview != "hello there" {
		t.Fatalf("good preview = %v", good.LatestRenderablePreview)
	}

	// Debug list reveals the hidden chat with the right reason.
	all, err := db.ListChats(ctx, 50, 0, true, "all", true)
	if err != nil {
		t.Fatalf("list debug: %v", err)
	}
	if len(all) != 2 {
		t.Fatalf("debug list = %v, want 2", guids(all))
	}
	var noise *store.ChatJSON
	for i := range all {
		if all[i].GUID == "noise" {
			noise = &all[i]
		}
	}
	if noise == nil || noise.HasRenderableMessages || !noise.UnsupportedOnly || noise.HiddenReason != "debug_only" {
		t.Fatalf("noise chat flags wrong: %+v", noise)
	}
}

func guids(chats []store.ChatJSON) []string {
	out := make([]string, len(chats))
	for i, c := range chats {
		out[i] = c.GUID
	}
	return out
}

func TestSemanticFieldsRoundTripThroughRelay(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()

	src := fakeSemanticSource{
		chats: []store.SyncChatRow{
			{GUID: "chatA", ServiceName: strp("iMessage")},
		},
		messages: []store.SyncMessageRow{
			{
				ChatGUID:               "chatA",
				SourceRowID:            10,
				GUID:                   "m-react",
				Text:                   strp("loved"),
				DateCreated:            intp(1000),
				AssociatedMessageType:  intp(2006),
				AssociatedMessageEmoji: strp("👩‍💻"),
				AssociatedMessageGUID:  strp("p:0/m-target"),
				PayloadDataPresent:     true,
			},
			{
				ChatGUID:             "chatA",
				SourceRowID:          11,
				GUID:                 "m-reply",
				Text:                 strp("sure"),
				DateCreated:          intp(2000),
				ThreadOriginatorGUID: strp("m-target"),
			},
		},
	}

	if _, err := SyncOnce(ctx, src, db, 100, 0); err != nil {
		t.Fatalf("sync: %v", err)
	}

	msgs, err := db.ListChatMessages(ctx, "chatA", 50, 0, false)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(msgs) != 2 {
		t.Fatalf("expected 2 messages, got %d", len(msgs))
	}

	byGUID := map[string]store.MessageJSON{}
	for _, m := range msgs {
		byGUID[m.GUID] = m
	}

	react := byGUID["m-react"]
	if react.ChatGUID == nil || *react.ChatGUID != "chatA" {
		t.Fatalf("chatGuid not exposed: %+v", react.ChatGUID)
	}
	if react.SemanticKind != store.SemanticKindTapback || react.RenderRecommendation != store.RenderRecommendationMerge {
		t.Fatalf("reaction classification = %q/%q", react.SemanticKind, react.RenderRecommendation)
	}
	if react.AssociatedMessageType == nil || *react.AssociatedMessageType != 2006 {
		t.Fatalf("associatedMessageType = %v, want 2006", react.AssociatedMessageType)
	}
	if react.AssociatedMessageEmoji == nil || *react.AssociatedMessageEmoji != "👩‍💻" {
		t.Fatalf("associatedMessageEmoji = %v", react.AssociatedMessageEmoji)
	}
	if react.AssociatedMessageGUID == nil || *react.AssociatedMessageGUID != "p:0/m-target" {
		t.Fatalf("associatedMessageGuid = %v", react.AssociatedMessageGUID)
	}
	if !react.PayloadDataPresent {
		t.Fatalf("payloadDataPresent should be true")
	}

	reply := byGUID["m-reply"]
	if reply.ThreadOriginatorGUID == nil || *reply.ThreadOriginatorGUID != "m-target" {
		t.Fatalf("threadOriginatorGuid = %v, want m-target", reply.ThreadOriginatorGUID)
	}
	if reply.SemanticKind != store.SemanticKindReply {
		t.Fatalf("reply semanticKind = %q, want reply", reply.SemanticKind)
	}
}

func TestRetractedStateFromMessageState(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()

	src := fakeSemanticSource{
		chats:    []store.SyncChatRow{{GUID: "chatB", ServiceName: strp("iMessage")}},
		messages: []store.SyncMessageRow{{ChatGUID: "chatB", SourceRowID: 1, GUID: "m-unsent", Text: strp("oops"), DateCreated: intp(500)}},
	}
	if _, err := SyncOnce(ctx, src, db, 100, 0); err != nil {
		t.Fatalf("sync: %v", err)
	}

	// Simulate the lookback update pass recording a retraction in message_state.
	if _, err := db.sqlDB.ExecContext(ctx, `
INSERT INTO message_state (guid, date_retracted, fingerprint, updated_at)
VALUES ('m-unsent', 1234, 'fp', 1)
ON CONFLICT(guid) DO UPDATE SET date_retracted = excluded.date_retracted;`); err != nil {
		t.Fatalf("seed message_state: %v", err)
	}

	msgs, err := db.ListChatMessages(ctx, "chatB", 50, 0, false)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(msgs) != 1 {
		t.Fatalf("expected 1 message, got %d", len(msgs))
	}
	m := msgs[0]
	if !m.IsRetracted || m.DateRetracted == nil || *m.DateRetracted != 1234 {
		t.Fatalf("retracted state not surfaced: isRetracted=%v dateRetracted=%v", m.IsRetracted, m.DateRetracted)
	}
}

func TestRetractedMessageStripsAttachments(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()

	src := fakeSemanticSource{
		chats: []store.SyncChatRow{{GUID: "chatB", ServiceName: strp("iMessage")}},
		messages: []store.SyncMessageRow{{
			ChatGUID:            "chatB",
			SourceRowID:         1,
			GUID:                "m-unsent-img",
			DateCreated:         intp(500),
			CacheHasAttachments: true,
		}},
		attachments: []store.SyncAttachmentRow{{
			GUID:        "att-1",
			MessageGUID: "m-unsent-img",
			Filename:    strp("/tmp/photo.jpg"),
			MimeType:    strp("image/jpeg"),
			TotalBytes:  2048,
		}},
	}
	if _, err := SyncOnce(ctx, src, db, 100, 0); err != nil {
		t.Fatalf("sync: %v", err)
	}

	if _, err := db.sqlDB.ExecContext(ctx, `
INSERT INTO message_state (guid, date_retracted, fingerprint, updated_at)
VALUES ('m-unsent-img', 1234, 'fp', 1)
ON CONFLICT(guid) DO UPDATE SET date_retracted = excluded.date_retracted;`); err != nil {
		t.Fatalf("seed message_state: %v", err)
	}

	msgs, err := db.ListChatMessages(ctx, "chatB", 50, 0, false)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(msgs) != 1 {
		t.Fatalf("expected 1 message, got %d", len(msgs))
	}
	m := msgs[0]
	if !m.IsRetracted {
		t.Fatalf("expected retracted message, got isRetracted=%v", m.IsRetracted)
	}
	if len(m.Attachments) != 0 || m.CacheHasAttachments {
		t.Fatalf("expected retracted message attachments stripped, got len=%d cacheHasAttachments=%v", len(m.Attachments), m.CacheHasAttachments)
	}
	if m.SemanticKind != store.SemanticKindRetracted {
		t.Fatalf("expected semanticKind=retracted, got %q", m.SemanticKind)
	}
}
