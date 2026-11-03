package relaydb

import (
	"context"
	"testing"

	"micagoserver/internal/store"
)

// C21: the delta endpoint is the catch-up correctness path. It returns
// renderable messages newer than the cursor, the affected chats, and an
// advancing cursor so nothing is missed and quiet periods don't re-scan.
func TestListMessagesSinceDelta(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()

	src := fakeSemanticSource{
		chats: []store.SyncChatRow{
			{GUID: "chatA", ServiceName: strp("iMessage")},
			{GUID: "chatB", ServiceName: strp("iMessage")},
		},
		messages: []store.SyncMessageRow{
			{ChatGUID: "chatA", SourceRowID: 10, GUID: "a1", Text: strp("hi"), DateCreated: intp(1000), Service: strp("iMessage")},
			{ChatGUID: "chatB", SourceRowID: 20, GUID: "b1", Text: strp("yo"), DateCreated: intp(2000), Service: strp("iMessage")},
			// noise row: must be excluded from the delta (debug-only) but still
			// counts toward the change sequence ceiling.
			{ChatGUID: "chatA", SourceRowID: 30, GUID: "noise", DateCreated: intp(3000), Service: strp("iMessage")},
		},
	}
	if _, err := SyncOnce(ctx, src, db, 100, 0); err != nil {
		t.Fatalf("sync: %v", err)
	}

	// since < 0 → seed: no messages, cursor at the current change sequence.
	seed, err := db.ListMessagesSince(ctx, -1, 200)
	if err != nil {
		t.Fatalf("seed: %v", err)
	}
	if len(seed.Messages) != 0 || seed.Cursor <= messageCursorBase {
		t.Fatalf("seed should be empty with a versioned cursor, got %d msgs cursor=%d", len(seed.Messages), seed.Cursor)
	}

	// since=0 → both renderable messages (noise excluded), oldest-first, cursor
	// advanced to the ceiling since nothing remains.
	all, err := db.ListMessagesSince(ctx, 0, 200)
	if err != nil {
		t.Fatalf("delta: %v", err)
	}
	if len(all.Messages) != 2 {
		t.Fatalf("expected 2 renderable msgs, got %d", len(all.Messages))
	}
	if all.Messages[0].GUID != "a1" || all.Messages[1].GUID != "b1" {
		t.Fatalf("delta must be oldest-first: %v", []string{all.Messages[0].GUID, all.Messages[1].GUID})
	}
	if all.Cursor != seed.Cursor {
		t.Fatalf("cursor should advance to seed cursor, got %d", all.Cursor)
	}
	if len(all.ChatGUIDs) != 2 {
		t.Fatalf("expected 2 affected chats, got %v", all.ChatGUIDs)
	}

	// A legacy ROWID cursor starts a replay with the new cursor format.
	page, err := db.ListMessagesSince(ctx, 10, 1)
	if err != nil {
		t.Fatalf("page: %v", err)
	}
	if len(page.Messages) != 1 || page.Messages[0].GUID != "a1" || !page.HasMore || page.Cursor <= messageCursorBase || page.Cursor >= seed.Cursor {
		t.Fatalf("paging wrong: n=%d hasMore=%v cursor=%d", len(page.Messages), page.HasMore, page.Cursor)
	}

	next, err := db.ListMessagesSince(ctx, page.Cursor, 1)
	if err != nil {
		t.Fatal(err)
	}
	if len(next.Messages) != 1 || next.Messages[0].GUID != "b1" || next.HasMore || next.Cursor != seed.Cursor {
		t.Fatalf("unexpected second page: %+v", next)
	}
}
