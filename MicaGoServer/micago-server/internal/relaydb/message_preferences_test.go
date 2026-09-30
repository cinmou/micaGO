package relaydb

import (
	"context"
	"errors"
	"micagoserver/internal/store"
	"reflect"
	"testing"
)

func TestMessagePreferencesAtomicReplayAndConflict(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()
	initial, err := db.MessagePreferences(ctx, 0)
	must(t, err)
	request := store.MessagePreferenceMutation{ServerID: initial.ServerID, MutationID: "first-operation", Changes: []store.MessagePreferenceChange{{MessageKey: "a\x1fsame", Hidden: true}, {MessageKey: "b\x1fsame", Hidden: true}}}
	first, err := db.MutateMessagePreferences(ctx, request)
	must(t, err)
	if first.Revision != 1 || len(first.Data) != 2 {
		t.Fatalf("unexpected result: %+v", first)
	}
	restore := store.MessagePreferenceMutation{ServerID: initial.ServerID, MutationID: "restore-operation", Changes: []store.MessagePreferenceChange{{MessageKey: "a\x1fsame", Hidden: false, BaseRevision: 1}}}
	_, err = db.MutateMessagePreferences(ctx, restore)
	must(t, err)
	replay, err := db.MutateMessagePreferences(ctx, request)
	must(t, err)
	if !reflect.DeepEqual(first, replay) {
		t.Fatal("replay changed the response")
	}
	delta, err := db.MessagePreferences(ctx, 1)
	must(t, err)
	if delta.Revision != 2 || len(delta.Data) != 1 || delta.Data[0].Hidden {
		t.Fatalf("restore tombstone lost: %+v", delta)
	}
	stale := store.MessagePreferenceMutation{ServerID: initial.ServerID, MutationID: "stale-operation", Changes: []store.MessagePreferenceChange{{MessageKey: "b\x1fsame", Hidden: false, BaseRevision: 1}, {MessageKey: "a\x1fsame", Hidden: true, BaseRevision: 1}}}
	_, err = db.MutateMessagePreferences(ctx, stale)
	if !errors.Is(err, ErrPreferenceConflict) {
		t.Fatalf("expected conflict: %v", err)
	}
	current, err := db.MessagePreferences(ctx, 0)
	must(t, err)
	if current.Revision != 2 {
		t.Fatal("conflicting batch partially committed")
	}
	for _, row := range current.Data {
		if row.MessageKey == "b\x1fsame" && !row.Hidden {
			t.Fatal("conflicting batch changed b")
		}
	}
	request.Changes[0].Hidden = false
	_, err = db.MutateMessagePreferences(ctx, request)
	if !errors.Is(err, ErrPreferenceMutation) {
		t.Fatalf("expected mutation reuse rejection: %v", err)
	}
	request.ServerID = "another-server"
	_, err = db.MutateMessagePreferences(ctx, request)
	if !errors.Is(err, ErrPreferenceScope) {
		t.Fatalf("expected scope rejection: %v", err)
	}
}

func TestMessagePreferencesShareServerIdentity(t *testing.T) {
	db := openTestDB(t)
	chats, err := db.ChatPreferences(context.Background(), 0)
	must(t, err)
	messages, err := db.MessagePreferences(context.Background(), 0)
	must(t, err)
	if chats.ServerID != messages.ServerID {
		t.Fatal("message and chat identity differ")
	}
}
