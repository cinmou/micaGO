package relaydb

import (
	"context"
	"errors"
	"micagoserver/internal/store"
	"path/filepath"
	"testing"
)

func TestReadStateMonotonicScopeAndVisibility(t *testing.T) {
	db, err := Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	ctx := context.Background()
	initial, err := db.ReadState(ctx)
	if err != nil {
		t.Fatal(err)
	}
	patch := func(at int64) store.ReadState {
		state, err := db.AdvanceReadState(ctx, store.ReadStateMutation{ServerID: initial.ServerID, Changes: []store.ReadPosition{{ChatGUID: "a", ReadThrough: at}}})
		if err != nil {
			t.Fatal(err)
		}
		return state
	}
	first := patch(200)
	second := patch(100)
	retry := patch(200)
	if first.Revision != second.Revision || retry.Revision != first.Revision || retry.Data[0].ReadThrough != 200 {
		t.Fatal("older/replayed read changed state")
	}
	if _, err = db.AdvanceReadState(ctx, store.ReadStateMutation{ServerID: "other", Changes: []store.ReadPosition{{ChatGUID: "a", ReadThrough: 999}}}); !errors.Is(err, ErrPreferenceScope) {
		t.Fatal("accepted foreign read")
	}
	_, err = db.AdvanceReadState(ctx, store.ReadStateMutation{ServerID: initial.ServerID, Changes: []store.ReadPosition{{ChatGUID: "b", ReadThrough: 50}}})
	if err != nil {
		t.Fatal(err)
	}
	prefs, err := db.MessagePreferences(ctx, 0)
	if err != nil {
		t.Fatal(err)
	}
	_, err = db.MutateMessagePreferences(ctx, store.MessagePreferenceMutation{ServerID: prefs.ServerID, MutationID: "hide-notification", Changes: []store.MessagePreferenceChange{{MessageKey: "a\x1fhidden", Hidden: true}}})
	if err != nil {
		t.Fatal(err)
	}
	atOld, atNew := int64(100), int64(300)
	events := []NotificationEvent{{ChatGUID: "a", Message: store.MessageJSON{GUID: "old", DateCreated: &atOld}}, {ChatGUID: "a", Message: store.MessageJSON{GUID: "hidden", DateCreated: &atNew}}, {ChatGUID: "a", Message: store.MessageJSON{GUID: "new", DateCreated: &atNew}}, {ChatGUID: "b", Message: store.MessageJSON{GUID: "old", DateCreated: &atOld}}}
	visible, err := db.VisibleNotificationEvents(ctx, events)
	if err != nil {
		t.Fatal(err)
	}
	if len(visible) != 2 || visible[0].Message.GUID != "new" || visible[1].ChatGUID != "b" {
		t.Fatal("notification filtering crossed routes or retained hidden/read messages")
	}
}

func TestManualUnreadCASAndReplay(t *testing.T) {
	db, err := Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	ctx := context.Background()
	initial, _ := db.ReadState(ctx)
	send := func(row store.ReadPosition) store.ReadPosition {
		t.Helper()
		state, err := db.AdvanceReadState(ctx, store.ReadStateMutation{ServerID: initial.ServerID, Changes: []store.ReadPosition{row}})
		if err != nil {
			t.Fatal(err)
		}
		return state.Data[0]
	}
	read := send(store.ReadPosition{ChatGUID: "a", ReadThrough: 200})
	yes, no := true, false
	base := read.UnreadRevision
	request := store.ReadPosition{ChatGUID: "a", MarkedUnread: &yes, BaseUnreadRevision: &base}
	marked := send(request)
	replay := send(request)
	if !*marked.MarkedUnread || marked.ReadThrough != 200 || replay.UnreadRevision != marked.UnreadRevision {
		t.Fatal("unread rewound or replayed")
	}
	next := marked.UnreadRevision
	cleared := send(store.ReadPosition{ChatGUID: "a", ReadThrough: 200, MarkedUnread: &no, BaseUnreadRevision: &next})
	stale := send(request)
	if *cleared.MarkedUnread || *stale.MarkedUnread || stale.ReadThrough != 200 {
		t.Fatal("old unread resurrected")
	}
	request.ReadThrough = 999
	if row := send(request); row.ReadThrough != 200 {
		t.Fatal("stale override advanced read position")
	}
}
