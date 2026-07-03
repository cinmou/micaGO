package store

import (
	"encoding/json"
	"strings"
	"testing"
)

func ip(n int64) *int64 { return &n }

func TestIsControlLikeText(t *testing.T) {
	cases := map[string]bool{
		"+!":       true,
		"+$":       true,
		"":         true,
		"￼":        true,
		"   ":      true,
		"Hello":    false,
		"+":        false,
		"+1":       false,
		"你好":       false,
		"see ya 👋": false,
	}
	for in, want := range cases {
		if got := IsControlLikeText(in); got != want {
			t.Errorf("IsControlLikeText(%q) = %v, want %v", in, got, want)
		}
	}
}

func TestClassifyDebugMessage(t *testing.T) {
	tests := []struct {
		name     string
		msg      DebugMessageJSON
		wantKind string
		wantCand string // a candidate that must be present ("" = none required)
	}{
		{"plain text", DebugMessageJSON{Text: sp("Hello")}, KindText, ""},
		{"literal plus text", DebugMessageJSON{Text: sp("+")}, KindText, ""},
		{"control text", DebugMessageJSON{Text: sp("+!")}, KindUnsupported, candidateControl},
		{"empty", DebugMessageJSON{}, KindUnsupported, candidateNoConten},
		{
			"reaction",
			DebugMessageJSON{AssociatedMessageType: ip(2000), AssociatedMessageGUID: sp("p:0/abc")},
			KindReaction, KindReaction,
		},
		{
			"reply candidate",
			DebugMessageJSON{ThreadOriginatorGUID: sp("m-target"), Text: sp("ok")},
			KindReply, KindReply,
		},
		{
			"service event",
			DebugMessageJSON{ItemType: ip(2), GroupActionType: ip(1)},
			KindService, KindService,
		},
		{
			"image attachment",
			DebugMessageJSON{Attachments: []DebugAttachmentJSON{{AttachmentKind: AttachmentKindImage}}},
			KindImage, "",
		},
		{
			"voice attachment",
			DebugMessageJSON{Attachments: []DebugAttachmentJSON{{AttachmentKind: AttachmentKindAudio, IsVoiceMessage: true}}},
			KindVoice, "",
		},
		{
			"file attachment",
			DebugMessageJSON{Attachments: []DebugAttachmentJSON{{AttachmentKind: AttachmentKindFile}}},
			KindFile, "",
		},
		{
			"associated sticker",
			DebugMessageJSON{
				AssociatedMessageType: ip(1000),
				AssociatedMessageGUID: sp("p:0/target"),
				Attachments:           []DebugAttachmentJSON{{AttachmentKind: AttachmentKindSticker}},
			},
			KindSticker, KindReaction,
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			kind, cand := ClassifyDebugMessage(tc.msg)
			if kind != tc.wantKind {
				t.Errorf("kind = %q, want %q", kind, tc.wantKind)
			}
			if tc.wantCand != "" && !contains(cand, tc.wantCand) {
				t.Errorf("candidates %v missing %q", cand, tc.wantCand)
			}
		})
	}
}

func TestClassifyFlagsMissingAttachmentRows(t *testing.T) {
	m := DebugMessageJSON{Text: sp("hi"), CacheHasAttachments: true}
	_, cand := ClassifyDebugMessage(m)
	if !contains(cand, "missing_attachment_rows") {
		t.Fatalf("expected missing_attachment_rows candidate, got %v", cand)
	}
}

func TestClassifyMessageJSONForNormalAPI(t *testing.T) {
	cases := []struct {
		name       string
		msg        MessageJSON
		wantKind   string
		wantRec    string
		debugOnly  bool
		wantReason string
	}{
		{
			name:     "normal text",
			msg:      MessageJSON{Text: sp("hello")},
			wantKind: SemanticKindNormalText,
			wantRec:  RenderRecommendationBubble,
		},
		{
			name:     "attributed body text",
			msg:      MessageJSON{Text: sp("hello"), HasAttributedBody: true},
			wantKind: SemanticKindAttributedBodyText,
			wantRec:  RenderRecommendationBubble,
		},
		{
			name:     "attachment",
			msg:      MessageJSON{Attachments: []AttachmentJSON{{AttachmentKind: AttachmentKindImage}}},
			wantKind: SemanticKindAttachment,
			wantRec:  RenderRecommendationBubble,
		},
		{
			name:       "missing attachment rows",
			msg:        MessageJSON{CacheHasAttachments: true},
			wantKind:   SemanticKindMissingAttachmentRows,
			wantRec:    RenderRecommendationSystem,
			wantReason: UnsupportedReasonMissingAttachmentRows,
		},
		{
			name: "tapback",
			msg: MessageJSON{
				AssociatedMessageType: ip(2000),
				AssociatedMessageGUID: sp("p:0/target"),
			},
			wantKind: SemanticKindTapback,
			wantRec:  RenderRecommendationMerge,
		},
		{
			name:     "reply",
			msg:      MessageJSON{ThreadOriginatorGUID: sp("target"), Text: sp("ok")},
			wantKind: SemanticKindReply,
			wantRec:  RenderRecommendationBubble,
		},
		{
			name: "associated sticker",
			msg: MessageJSON{
				AssociatedMessageType: ip(1000),
				AssociatedMessageGUID: sp("p:0/target"),
				Attachments:           []AttachmentJSON{{AttachmentKind: AttachmentKindSticker, IsSticker: true}},
			},
			wantKind: SemanticKindSticker,
			wantRec:  RenderRecommendationBubble,
		},
		{
			name:     "service event",
			msg:      MessageJSON{ItemType: ip(1)},
			wantKind: SemanticKindServiceEvent,
			wantRec:  RenderRecommendationSystem,
		},
		{
			name:     "effect",
			msg:      MessageJSON{ExpressiveSendStyleID: sp("effect"), Text: sp("boom")},
			wantKind: SemanticKindEffect,
			wantRec:  RenderRecommendationBubble,
		},
		{
			name:     "normal edited text",
			msg:      MessageJSON{Text: sp("new"), IsEdited: true},
			wantKind: SemanticKindNormalText,
			wantRec:  RenderRecommendationBubble,
		},
		{
			name:     "normal edited attachment",
			msg:      MessageJSON{Attachments: []AttachmentJSON{{AttachmentKind: AttachmentKindImage}}, DateEdited: ip(42)},
			wantKind: SemanticKindAttachment,
			wantRec:  RenderRecommendationBubble,
		},
		{
			name:       "empty edited residue",
			msg:        MessageJSON{IsEdited: true},
			wantKind:   SemanticKindEmptyEditedResidue,
			wantRec:    RenderRecommendationSystem,
			wantReason: UnsupportedReasonEmptyEditedResidue,
		},
		{
			name:       "empty edited missing attachment rows",
			msg:        MessageJSON{IsEdited: true, CacheHasAttachments: true},
			wantKind:   SemanticKindMissingAttachmentRows,
			wantRec:    RenderRecommendationSystem,
			wantReason: UnsupportedReasonMissingAttachmentRows,
		},
		{
			name:     "retracted",
			msg:      MessageJSON{IsRetracted: true, Text: sp("old")},
			wantKind: SemanticKindRetracted,
			wantRec:  RenderRecommendationSystem,
		},
		{
			name:     "retracted priority over empty edited residue",
			msg:      MessageJSON{IsRetracted: true, IsEdited: true},
			wantKind: SemanticKindRetracted,
			wantRec:  RenderRecommendationSystem,
		},
		{
			name:       "sync noise",
			msg:        MessageJSON{Text: sp("+!")},
			wantKind:   SemanticKindSyncNoise,
			wantRec:    RenderRecommendationDebugOnly,
			debugOnly:  true,
			wantReason: UnsupportedReasonControlText,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			kind, rec, debugOnly, reason := ClassifyMessageJSON(tc.msg)
			if kind != tc.wantKind || rec != tc.wantRec || debugOnly != tc.debugOnly || reason != tc.wantReason {
				t.Fatalf("got kind=%q rec=%q debug=%v reason=%q", kind, rec, debugOnly, reason)
			}
		})
	}
}

func TestDebugClassificationMatchesNormalForEditedResidues(t *testing.T) {
	cases := []struct {
		name     string
		debug    DebugMessageJSON
		normal   MessageJSON
		wantKind string
	}{
		{
			name:     "empty edited residue",
			debug:    DebugMessageJSON{IsEdited: true},
			normal:   MessageJSON{IsEdited: true},
			wantKind: KindEmptyEdited,
		},
		{
			name:     "empty edited missing attachment rows",
			debug:    DebugMessageJSON{IsEdited: true, CacheHasAttachments: true},
			normal:   MessageJSON{IsEdited: true, CacheHasAttachments: true},
			wantKind: KindMissingRows,
		},
		{
			name: "normal edited attachment",
			debug: DebugMessageJSON{
				DateEdited:  ip(99),
				Attachments: []DebugAttachmentJSON{{AttachmentKind: AttachmentKindImage}},
			},
			normal:   MessageJSON{DateEdited: ip(99), Attachments: []AttachmentJSON{{AttachmentKind: AttachmentKindImage}}},
			wantKind: KindImage,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			debugKind, _ := ClassifyDebugMessage(tc.debug)
			normalKind, normalRec, normalDebugOnly, normalReason := ClassifyMessageJSON(tc.normal)
			convertedKind, convertedRec, convertedDebugOnly, convertedReason := ClassifyMessageJSON(debugAsMessageJSON(tc.debug))
			if debugKind != tc.wantKind {
				t.Fatalf("debug kind = %q, want %q", debugKind, tc.wantKind)
			}
			if convertedKind != normalKind || convertedRec != normalRec || convertedDebugOnly != normalDebugOnly || convertedReason != normalReason {
				t.Fatalf("debug/normal mismatch: converted=%q/%q/%v/%q normal=%q/%q/%v/%q",
					convertedKind, convertedRec, convertedDebugOnly, convertedReason,
					normalKind, normalRec, normalDebugOnly, normalReason)
			}
		})
	}
}

// C12 (req #8): an IMSG/imsgweb-style attachment message — a real attachment row
// with empty text — must render as a proper bubble, not be dropped as noise nor
// shown as a broken/empty bubble. It survives FilterRenderableMessages; an
// attachment placeholder with no real rows (cache_has_attachments but zero
// attachments) is flagged unsupported (system), never a silent broken bubble.
func TestAttachmentOnlyMessageIsRenderableNotBrokenBubble(t *testing.T) {
	image := MessageJSON{
		GUID:                "att-1",
		Attachments:         []AttachmentJSON{{GUID: "a1", AttachmentKind: AttachmentKindImage, MimeType: sp("image/jpeg")}},
		CacheHasAttachments: true,
	}
	AnnotateMessageJSON(&image)
	if image.IsDebugOnly {
		t.Fatal("an attachment-only message must not be debug-only")
	}
	if image.SemanticKind != SemanticKindAttachment {
		t.Fatalf("kind = %q, want attachment", image.SemanticKind)
	}
	if image.RenderRecommendation != RenderRecommendationBubble {
		t.Fatalf("rec = %q, want bubble", image.RenderRecommendation)
	}

	// It must survive the renderable filter (the normal timeline keeps it).
	kept := FilterRenderableMessages([]MessageJSON{image})
	if len(kept) != 1 || kept[0].GUID != "att-1" {
		t.Fatalf("attachment message dropped by renderable filter: %v", kept)
	}

	// A placeholder with cache_has_attachments but no real rows is surfaced as an
	// unsupported/system message, not a silent broken bubble.
	placeholder := MessageJSON{GUID: "ph-1", CacheHasAttachments: true}
	AnnotateMessageJSON(&placeholder)
	if placeholder.SemanticKind != SemanticKindMissingAttachmentRows {
		t.Fatalf("placeholder kind = %q, want missing_attachment_rows", placeholder.SemanticKind)
	}
}

func annotate(in []DebugMessageJSON) []DebugMessageJSON {
	for i := range in {
		AnnotateDebugMessage(&in[i])
	}
	return in
}

func sampleMessages() []DebugMessageJSON {
	return annotate([]DebugMessageJSON{
		{GUID: "1", Text: sp("Hello world"), HandleID: sp("+15550001"), ChatGUID: sp("cA"), ChatDisplayName: sp("Alice"), DateCreated: ip(100)},
		{GUID: "2", Text: sp("+!"), HandleID: sp("+15550001"), ChatGUID: sp("cA"), ChatDisplayName: sp("Alice"), DateCreated: ip(200)},
		{GUID: "3", IsFromMe: true, Text: sp("from me"), ChatGUID: sp("cA"), ChatDisplayName: sp("Alice"), DateCreated: ip(300)},
		{GUID: "4", HandleID: sp("+15550002"), ChatGUID: sp("cB"), ChatDisplayName: sp("Bob"),
			Attachments: []DebugAttachmentJSON{{GUID: "att1", AttachmentKind: AttachmentKindImage, Filename: sp("photo.jpg")}}, DateCreated: ip(400)},
		{GUID: "5", HandleID: sp("+15550002"), ChatGUID: sp("cB"), DateCreated: ip(500)}, // empty -> unsupported
	})
}

func TestFilterByQuery(t *testing.T) {
	msgs := sampleMessages()
	// matches chat display name "Alice"
	got := FilterDebugMessages(msgs, DebugFilter{Query: "alice"})
	if len(got) != 3 {
		t.Fatalf("query alice = %d rows, want 3 (chat cA)", len(got))
	}
	// matches attachment filename
	got = FilterDebugMessages(msgs, DebugFilter{Query: "photo.jpg"})
	if len(got) != 1 || got[0].GUID != "4" {
		t.Fatalf("query photo.jpg = %+v, want only guid 4", got)
	}
}

func TestFilterByType(t *testing.T) {
	msgs := sampleMessages()
	if got := FilterDebugMessages(msgs, DebugFilter{Type: "text"}); len(got) != 2 {
		t.Fatalf("type text = %d, want 2", len(got))
	}
	if got := FilterDebugMessages(msgs, DebugFilter{Type: "image"}); len(got) != 1 {
		t.Fatalf("type image = %d, want 1", len(got))
	}
	if got := FilterDebugMessages(msgs, DebugFilter{Type: "unsupported"}); len(got) != 2 {
		t.Fatalf("type unsupported = %d, want 2 (control + empty)", len(got))
	}
}

func TestFilterByAttachments(t *testing.T) {
	msgs := sampleMessages()
	if got := FilterDebugMessages(msgs, DebugFilter{HasAttachments: "has"}); len(got) != 1 {
		t.Fatalf("has = %d, want 1", len(got))
	}
	if got := FilterDebugMessages(msgs, DebugFilter{HasAttachments: "none"}); len(got) != 4 {
		t.Fatalf("none = %d, want 4", len(got))
	}
	if got := FilterDebugMessages(msgs, DebugFilter{HasAttachments: "image"}); len(got) != 1 {
		t.Fatalf("image = %d, want 1", len(got))
	}
}

func TestGroupBySender(t *testing.T) {
	groups := GroupDebugMessages(sampleMessages(), "sender")
	byKey := map[string]DebugGroup{}
	for _, g := range groups {
		byKey[g.Key] = g
	}
	if byKey["+15550001"].Count != 2 {
		t.Fatalf("+15550001 count = %d, want 2", byKey["+15550001"].Count)
	}
	if byKey["+15550001"].UnsupportedCount != 1 {
		t.Fatalf("+15550001 unsupported = %d, want 1", byKey["+15550001"].UnsupportedCount)
	}
	if byKey["me"].Label != "You" {
		t.Fatalf("me label = %q, want You", byKey["me"].Label)
	}
	bob := byKey["+15550002"]
	if bob.AttachmentCount != 1 {
		t.Fatalf("bob attachment count = %d, want 1", bob.AttachmentCount)
	}
	if bob.LatestTimestamp == nil || *bob.LatestTimestamp != 500 {
		t.Fatalf("bob latest = %v, want 500", bob.LatestTimestamp)
	}
}

func TestGroupByUnsupportedReason(t *testing.T) {
	groups := GroupDebugMessages(sampleMessages(), "unsupported")
	byKey := map[string]int{}
	for _, g := range groups {
		byKey[g.Key] = g.Count
	}
	if byKey[candidateControl] != 1 {
		t.Fatalf("control group = %d, want 1", byKey[candidateControl])
	}
	if byKey[candidateNoConten] != 1 {
		t.Fatalf("no-content group = %d, want 1", byKey[candidateNoConten])
	}
}

func TestGroupFlatReturnsNil(t *testing.T) {
	if g := GroupDebugMessages(sampleMessages(), "flat"); g != nil {
		t.Fatalf("flat groupBy should return nil, got %v", g)
	}
}

// TestDebugPayloadRedactionByConstruction asserts the debug JSON never carries
// a local file path or a tokenized download URL — only a boolean presence flag.
func TestDebugPayloadRedactionByConstruction(t *testing.T) {
	msg := DebugMessageJSON{
		GUID:     "g1",
		HandleID: sp("+15550001"),
		Text:     sp("hello"),
		Attachments: []DebugAttachmentJSON{{
			GUID:           "att1",
			Filename:       sp("/Users/cinmou/Library/Messages/Attachments/secret.jpg"),
			AttachmentKind: AttachmentKindImage,
			HasDownloadURL: true,
		}},
	}
	AnnotateDebugMessage(&msg)
	raw, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	s := string(raw)
	if strings.Contains(s, "localPath") || strings.Contains(s, "downloadUrl\"") {
		t.Fatalf("debug JSON leaked a path/url field: %s", s)
	}
	if !strings.Contains(s, "\"hasDownloadUrl\":true") {
		t.Fatalf("expected hasDownloadUrl flag, got %s", s)
	}
	if strings.Contains(strings.ToLower(s), "bearer ") || strings.Contains(s, "\"token\"") {
		t.Fatalf("debug JSON leaked a token: %s", s)
	}
}

func TestFilterRenderableMessages(t *testing.T) {
	in := []MessageJSON{
		{GUID: "a", IsDebugOnly: false},
		{GUID: "b", IsDebugOnly: true},
		{GUID: "c", IsDebugOnly: false},
	}
	out := FilterRenderableMessages(in)
	if len(out) != 2 || out[0].GUID != "a" || out[1].GUID != "c" {
		t.Fatalf("expected [a c], got %d rows", len(out))
	}
}

func TestDebugOnlyForSyncRow(t *testing.T) {
	ctrl := "+!"
	real := "hello"
	if !DebugOnlyForSyncRow(SyncMessageRow{Text: &ctrl}) {
		t.Fatal("control-like text should be debug-only")
	}
	if DebugOnlyForSyncRow(SyncMessageRow{Text: &real}) {
		t.Fatal("real text should not be debug-only")
	}
	if DebugOnlyForSyncRow(SyncMessageRow{CacheHasAttachments: true}) {
		t.Fatal("cacheHasAttachments row is system (missing rows), not debug-only")
	}
}
