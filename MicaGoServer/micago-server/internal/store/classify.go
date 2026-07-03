package store

import (
	"sort"
	"strings"
	"unicode"
)

// Message debug classification kinds. Confident kinds (text/image/video/audio/
// voice/file) describe rendered content; "*_candidate" kinds are heuristic
// guesses for rows whose true nature depends on iMessage fields the server may
// not expose. "unsupported_candidate" means nothing renderable was found.
const (
	KindText          = "text"
	KindImage         = "image"
	KindVideo         = "video"
	KindAudio         = "audio"
	KindVoice         = "voice"
	KindFile          = "file"
	KindSticker       = "sticker"
	KindReaction      = "reaction_candidate"
	KindReply         = "reply_candidate"
	KindService       = "service_candidate"
	KindUnsupported   = "unsupported_candidate"
	KindMissingRows   = "missing_attachment_rows"
	KindEmptyEdited   = "empty_edited_residue"
	KindRetracted     = "retracted"
	candidateControl  = "control_like"
	candidateNoConten = "no_content"
)

const (
	SemanticKindNormalText            = "normal_text"
	SemanticKindAttributedBodyText    = "attributed_body_text"
	SemanticKindAttachment            = "attachment"
	SemanticKindMissingAttachmentRows = "missing_attachment_rows"
	SemanticKindTapback               = "tapback"
	SemanticKindReply                 = "reply"
	SemanticKindServiceEvent          = "service_event"
	SemanticKindEffect                = "effect"
	SemanticKindEmptyEditedResidue    = "empty_edited_residue"
	SemanticKindRetracted             = "retracted"
	SemanticKindDeleted               = "deleted"
	SemanticKindUnavailable           = "unavailable"
	SemanticKindSticker               = "sticker"
	SemanticKindSyncNoise             = "sync_noise"
	SemanticKindUnknown               = "unknown"

	RenderRecommendationBubble      = "bubble"
	RenderRecommendationSystem      = "system"
	RenderRecommendationMerge       = "merge"
	RenderRecommendationDebugOnly   = "debug_only"
	RenderRecommendationUnsupported = "unsupported"

	UnsupportedReasonNone                  = ""
	UnsupportedReasonControlText           = "control_text"
	UnsupportedReasonNoContent             = "no_content"
	UnsupportedReasonMissingAttachmentRows = "missing_attachment_rows"
	UnsupportedReasonEmptyEditedResidue    = "empty_edited_residue"
	UnsupportedReasonUnknownAttachment     = "unknown_attachment"
)

// IsControlLikeText reports whether text is a control/typedstream artifact that
// must not be shown as a normal message — e.g. the "+!"/"+$" attributedBody
// leak, or a string with no letters/digits at all. Conservative: any letter or
// digit (incl. CJK) means it is real content.
func IsControlLikeText(text string) bool {
	t := strings.TrimSpace(strings.ReplaceAll(text, "￼", ""))
	if t == "" {
		return true
	}
	if t == "+" {
		return false
	}
	for _, r := range t {
		// Letters/digits (incl. CJK, accented) are content; so is any non-ASCII
		// rune (emoji, symbols, other scripts). Real artifacts ("+!", "+$") are
		// pure ASCII punctuation — never strip a real emoji-only message.
		if unicode.IsLetter(r) || unicode.IsDigit(r) || r > unicode.MaxASCII {
			return false
		}
	}
	return true
}

func attachmentKindOf(m DebugMessageJSON) string {
	// Voice wins; otherwise first media kind; otherwise file.
	hasFile := false
	for _, a := range m.Attachments {
		if a.IsVoiceMessage {
			return KindVoice
		}
	}
	for _, a := range m.Attachments {
		switch a.AttachmentKind {
		case AttachmentKindImage:
			return KindImage
		case AttachmentKindVideo:
			return KindVideo
		case AttachmentKindAudio:
			return KindAudio
		default:
			hasFile = true
		}
	}
	if hasFile {
		return KindFile
	}
	return KindFile
}

// ClassifyDebugMessage returns the best single kind plus any additional
// candidate signals. It is heuristic and intended for debugging only.
func ClassifyDebugMessage(m DebugMessageJSON) (kind string, candidates []string) {
	candidates = []string{}

	// Reaction / reply association (depends on optional columns).
	if m.AssociatedMessageType != nil && *m.AssociatedMessageType != 0 {
		candidates = append(candidates, KindReaction)
	}
	// Replies are identified by thread_originator_guid (BlueBubbles semantics),
	// distinct from the associated_message_guid used by reactions.
	if m.ThreadOriginatorGUID != nil && strings.TrimSpace(*m.ThreadOriginatorGUID) != "" {
		candidates = append(candidates, KindReply)
	}
	if (m.ItemType != nil && *m.ItemType != 0) ||
		(m.GroupActionType != nil && *m.GroupActionType != 0) ||
		(m.GroupTitle != nil && strings.TrimSpace(*m.GroupTitle) != "") {
		candidates = append(candidates, KindService)
	}
	if m.BalloonBundleID != nil && strings.TrimSpace(*m.BalloonBundleID) != "" {
		candidates = append(candidates, "interactive_candidate")
	}

	semantic, _, _, reason := ClassifyMessageJSON(debugAsMessageJSON(m))

	// Primary kind precedence mirrors the normal API classifier. Debug-specific
	// candidates above remain available for filtering/explanation.
	switch semantic {
	case SemanticKindRetracted:
		kind = KindRetracted
	case SemanticKindTapback:
		kind = KindReaction
	case SemanticKindReply:
		kind = KindReply
	case SemanticKindServiceEvent:
		kind = KindService
	case SemanticKindAttachment:
		kind = attachmentKindOf(m)
	case SemanticKindSticker:
		kind = KindSticker
	case SemanticKindNormalText, SemanticKindAttributedBodyText, SemanticKindEffect:
		kind = KindText
	case SemanticKindMissingAttachmentRows:
		kind = KindMissingRows
	case SemanticKindEmptyEditedResidue:
		kind = KindEmptyEdited
	default:
		kind = KindUnsupported
		if reason == UnsupportedReasonControlText {
			candidates = append(candidates, candidateControl)
		} else {
			candidates = append(candidates, candidateNoConten)
		}
	}

	// A row flagged cache_has_attachments but with none materialized is itself a
	// useful unsupported signal (server didn't surface the attachment row).
	if kind != KindUnsupported && m.CacheHasAttachments && len(m.Attachments) == 0 {
		candidates = append(candidates, "missing_attachment_rows")
	}
	return kind, candidates
}

func debugAsMessageJSON(m DebugMessageJSON) MessageJSON {
	attachments := make([]AttachmentJSON, 0, len(m.Attachments))
	for _, a := range m.Attachments {
		attachments = append(attachments, AttachmentJSON{
			GUID:                   a.GUID,
			Filename:               a.Filename,
			TransferName:           a.TransferName,
			MimeType:               a.MimeType,
			Uti:                    a.Uti,
			AttachmentKind:         a.AttachmentKind,
			IsVoiceMessage:         a.IsVoiceMessage,
			DisplayKind:            a.DisplayKind,
			IsPreviewableImage:     a.IsPreviewableImage,
			NeedsPreviewConversion: a.NeedsPreviewConversion,
			TotalBytes:             a.TotalBytes,
		})
	}
	return MessageJSON{
		GUID:                  m.GUID,
		Text:                  m.Text,
		CacheHasAttachments:   m.CacheHasAttachments,
		Attachments:           attachments,
		HasAttributedBody:     m.HasAttributedBody,
		AssociatedMessageType: m.AssociatedMessageType,
		AssociatedMessageGUID: m.AssociatedMessageGUID,
		ThreadOriginatorGUID:  m.ThreadOriginatorGUID,
		ItemType:              m.ItemType,
		GroupActionType:       m.GroupActionType,
		GroupTitle:            m.GroupTitle,
		BalloonBundleID:       m.BalloonBundleID,
		ExpressiveSendStyleID: m.ExpressiveSendStyleID,
		DateRetracted:         m.DateRetracted,
		DateEdited:            m.DateEdited,
		IsRetracted:           m.IsRetracted,
		IsEdited:              m.IsEdited,
	}
}

// AnnotateDebugMessage fills Kind/Candidates in place.
func AnnotateDebugMessage(m *DebugMessageJSON) {
	m.Kind, m.Candidates = ClassifyDebugMessage(*m)
}

// FilterRenderableMessages returns only the messages a normal client should
// render — i.e. excludes debug-only/noise rows. Messages must be annotated
// (IsDebugOnly populated) first; reads already annotate on the way out.
func FilterRenderableMessages(in []MessageJSON) []MessageJSON {
	out := make([]MessageJSON, 0, len(in))
	for _, m := range in {
		if m.IsDebugOnly {
			continue
		}
		out = append(out, m)
	}
	return out
}

func AnnotateMessageJSON(m *MessageJSON) {
	if m == nil {
		return
	}
	m.SemanticKind, m.RenderRecommendation, m.IsDebugOnly, m.UnsupportedReason = ClassifyMessageJSON(*m)
}

// IsReactionForSyncRow reports whether a synced row is a tapback/reaction
// (associated_message_type in the 2000–3006 range with an associated target).
// Mirrors IMSG's reaction filter: reaction rows are real content the client
// merges onto a target, but they must NOT drive chat-list preview/ordering, so
// the chat-list aggregate excludes them (see relaydb.ListChats). Depends only on
// SyncMessageRow fields, so it is safe to compute at sync time.
func IsReactionForSyncRow(r SyncMessageRow) bool {
	if r.AssociatedMessageType == nil {
		return false
	}
	t := *r.AssociatedMessageType
	if t < 2000 || t > 3006 {
		return false
	}
	return r.AssociatedMessageGUID != nil && strings.TrimSpace(*r.AssociatedMessageGUID) != ""
}

// DebugOnlyForSyncRow reports whether a synced row is debug-only (sync noise).
// This depends only on fields present on SyncMessageRow (text, cacheHasAttachments,
// associated/item/thread/effect fields) — not the materialized attachment list —
// so it is safe to compute at sync time. Used to persist is_debug_only.
func DebugOnlyForSyncRow(r SyncMessageRow) bool {
	m := MessageJSON{
		Text:                  r.Text,
		HasAttributedBody:     r.HasAttributedBody,
		CacheHasAttachments:   r.CacheHasAttachments,
		AssociatedMessageType: r.AssociatedMessageType,
		AssociatedMessageGUID: r.AssociatedMessageGUID,
		ThreadOriginatorGUID:  r.ThreadOriginatorGUID,
		ItemType:              r.ItemType,
		GroupActionType:       r.GroupActionType,
		GroupTitle:            r.GroupTitle,
		BalloonBundleID:       r.BalloonBundleID,
		ExpressiveSendStyleID: r.ExpressiveSendStyleID,
	}
	_, _, isDebugOnly, _ := ClassifyMessageJSON(m)
	return isDebugOnly
}

func ClassifyMessageJSON(m MessageJSON) (semanticKind, renderRecommendation string, isDebugOnly bool, unsupportedReason string) {
	text := strings.TrimSpace(deref(m.Text))
	hasText := text != "" && !IsControlLikeText(text)
	hasControlText := text != "" && IsControlLikeText(text)
	hasAttachments := len(m.Attachments) > 0

	switch {
	case m.IsRetracted || m.DateRetracted != nil:
		return SemanticKindRetracted, RenderRecommendationSystem, false, UnsupportedReasonNone
	case m.AssociatedMessageType != nil && *m.AssociatedMessageType >= 2000 && *m.AssociatedMessageType <= 3005 &&
		m.AssociatedMessageGUID != nil && strings.TrimSpace(*m.AssociatedMessageGUID) != "":
		return SemanticKindTapback, RenderRecommendationMerge, false, UnsupportedReasonNone
	case m.AssociatedMessageType != nil && *m.AssociatedMessageType == 1000 &&
		m.AssociatedMessageGUID != nil && strings.TrimSpace(*m.AssociatedMessageGUID) != "":
		return SemanticKindSticker, RenderRecommendationBubble, false, UnsupportedReasonNone
	case m.ItemType != nil && *m.ItemType != 0:
		return SemanticKindServiceEvent, RenderRecommendationSystem, false, UnsupportedReasonNone
	case m.GroupActionType != nil && *m.GroupActionType != 0:
		return SemanticKindServiceEvent, RenderRecommendationSystem, false, UnsupportedReasonNone
	case m.GroupTitle != nil && strings.TrimSpace(*m.GroupTitle) != "":
		return SemanticKindServiceEvent, RenderRecommendationSystem, false, UnsupportedReasonNone
	case m.ThreadOriginatorGUID != nil && strings.TrimSpace(*m.ThreadOriginatorGUID) != "":
		return SemanticKindReply, RenderRecommendationBubble, false, UnsupportedReasonNone
	case m.ExpressiveSendStyleID != nil && strings.TrimSpace(*m.ExpressiveSendStyleID) != "":
		return SemanticKindEffect, RenderRecommendationBubble, false, UnsupportedReasonNone
	case hasAttachments:
		if anyJSONAttachmentKind(m, AttachmentKindUnknown) {
			return SemanticKindAttachment, RenderRecommendationBubble, false, UnsupportedReasonUnknownAttachment
		}
		return SemanticKindAttachment, RenderRecommendationBubble, false, UnsupportedReasonNone
	case hasText:
		if m.HasAttributedBody {
			return SemanticKindAttributedBodyText, RenderRecommendationBubble, false, UnsupportedReasonNone
		}
		return SemanticKindNormalText, RenderRecommendationBubble, false, UnsupportedReasonNone
	case m.CacheHasAttachments:
		return SemanticKindMissingAttachmentRows, RenderRecommendationSystem, false, UnsupportedReasonMissingAttachmentRows
	case m.DateEdited != nil || m.IsEdited:
		return SemanticKindEmptyEditedResidue, RenderRecommendationSystem, false, UnsupportedReasonEmptyEditedResidue
	case hasControlText:
		return SemanticKindSyncNoise, RenderRecommendationDebugOnly, true, UnsupportedReasonControlText
	default:
		return SemanticKindSyncNoise, RenderRecommendationDebugOnly, true, UnsupportedReasonNoContent
	}
}

func anyJSONAttachmentKind(m MessageJSON, kind string) bool {
	for _, a := range m.Attachments {
		if a.AttachmentKind == kind {
			return true
		}
	}
	return false
}

// DebugFilter is the post-fetch, in-Go refinement of debug rows.
type DebugFilter struct {
	Query          string // substring (case-insensitive) over text/chat/sender/attachment names
	Type           string // "" or one of the kinds / "attachment"
	HasAttachments string // "all" | "has" | "none" | "image" | "audio" | "unsupported"
}

// FilterDebugMessages applies the query/type/attachment filters to already
// annotated rows (call AnnotateDebugMessage first).
func FilterDebugMessages(in []DebugMessageJSON, f DebugFilter) []DebugMessageJSON {
	out := make([]DebugMessageJSON, 0, len(in))
	q := strings.ToLower(strings.TrimSpace(f.Query))
	for _, m := range in {
		if q != "" && !debugMatchesQuery(m, q) {
			continue
		}
		if !debugMatchesType(m, f.Type) {
			continue
		}
		if !debugMatchesAttachments(m, f.HasAttachments) {
			continue
		}
		out = append(out, m)
	}
	return out
}

func debugMatchesQuery(m DebugMessageJSON, q string) bool {
	hay := strings.Builder{}
	add := func(s *string) {
		if s != nil {
			hay.WriteString(strings.ToLower(*s))
			hay.WriteByte('\n')
		}
	}
	add(m.Text)
	add(m.ChatDisplayName)
	add(m.ChatIdentifier)
	add(m.ChatGUID)
	add(m.HandleID)
	for _, a := range m.Attachments {
		add(a.Filename)
		add(a.TransferName)
	}
	return strings.Contains(hay.String(), q)
}

func debugMatchesType(m DebugMessageJSON, t string) bool {
	switch t {
	case "", "all":
		return true
	case "attachment":
		return len(m.Attachments) > 0
	case "reaction":
		return m.Kind == KindReaction || contains(m.Candidates, KindReaction)
	case "reply":
		return m.Kind == KindReply || contains(m.Candidates, KindReply)
	case "service":
		return m.Kind == KindService || contains(m.Candidates, KindService)
	case "unknown", "unsupported":
		return m.Kind == KindUnsupported || m.Kind == KindMissingRows || m.Kind == KindEmptyEdited
	default:
		// text / image / video / audio / voice / file
		return m.Kind == t
	}
}

func debugMatchesAttachments(m DebugMessageJSON, mode string) bool {
	switch mode {
	case "", "all":
		return true
	case "has":
		return len(m.Attachments) > 0
	case "none":
		return len(m.Attachments) == 0
	case "image":
		return anyAttachment(m, AttachmentKindImage)
	case "audio":
		return anyAttachment(m, AttachmentKindAudio) || anyVoice(m)
	case "unsupported":
		return anyAttachment(m, AttachmentKindUnknown)
	default:
		return true
	}
}

func anyAttachment(m DebugMessageJSON, kind string) bool {
	for _, a := range m.Attachments {
		if a.AttachmentKind == kind {
			return true
		}
	}
	return false
}

func anyVoice(m DebugMessageJSON) bool {
	for _, a := range m.Attachments {
		if a.IsVoiceMessage {
			return true
		}
	}
	return false
}

// DebugGroup summarizes a set of messages sharing a grouping key.
type DebugGroup struct {
	Key              string `json:"key"`
	Label            string `json:"label"`
	Count            int    `json:"count"`
	UnsupportedCount int    `json:"unsupportedCount"`
	AttachmentCount  int    `json:"attachmentCount"`
	LatestTimestamp  *int64 `json:"latestTimestamp"`
}

// GroupDebugMessages aggregates rows by mode: "sender" | "chat" | "type" |
// "unsupported". Any other value returns nil (flat view). Groups are sorted by
// descending message count, then label.
func GroupDebugMessages(in []DebugMessageJSON, mode string) []DebugGroup {
	keyFn, labelFn, ok := groupKeyFns(mode)
	if !ok {
		return nil
	}
	order := []string{}
	groups := map[string]*DebugGroup{}
	for _, m := range in {
		key := keyFn(m)
		g, exists := groups[key]
		if !exists {
			g = &DebugGroup{Key: key, Label: labelFn(m, key)}
			groups[key] = g
			order = append(order, key)
		}
		g.Count++
		if m.Kind == KindUnsupported {
			g.UnsupportedCount++
		}
		g.AttachmentCount += len(m.Attachments)
		if m.DateCreated != nil {
			if g.LatestTimestamp == nil || *m.DateCreated > *g.LatestTimestamp {
				v := *m.DateCreated
				g.LatestTimestamp = &v
			}
		}
	}
	out := make([]DebugGroup, 0, len(order))
	for _, k := range order {
		out = append(out, *groups[k])
	}
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].Count != out[j].Count {
			return out[i].Count > out[j].Count
		}
		return out[i].Label < out[j].Label
	})
	return out
}

func groupKeyFns(mode string) (func(DebugMessageJSON) string, func(DebugMessageJSON, string) string, bool) {
	switch mode {
	case "sender":
		return func(m DebugMessageJSON) string {
				if m.IsFromMe {
					return "me"
				}
				if m.HandleID != nil && strings.TrimSpace(*m.HandleID) != "" {
					return *m.HandleID
				}
				return "unknown"
			}, func(m DebugMessageJSON, key string) string {
				switch key {
				case "me":
					return "You"
				case "unknown":
					return "Unknown sender"
				default:
					return key
				}
			}, true
	case "chat":
		return func(m DebugMessageJSON) string {
				if m.ChatGUID != nil {
					return *m.ChatGUID
				}
				return "unknown"
			}, func(m DebugMessageJSON, key string) string {
				if m.ChatDisplayName != nil && strings.TrimSpace(*m.ChatDisplayName) != "" {
					return *m.ChatDisplayName
				}
				if m.ChatIdentifier != nil && strings.TrimSpace(*m.ChatIdentifier) != "" {
					return *m.ChatIdentifier
				}
				return key
			}, true
	case "type":
		return func(m DebugMessageJSON) string { return m.Kind },
			func(m DebugMessageJSON, key string) string { return key }, true
	case "unsupported":
		return func(m DebugMessageJSON) string {
				if m.Kind != KindUnsupported {
					return "supported"
				}
				if contains(m.Candidates, candidateControl) {
					return candidateControl
				}
				if contains(m.Candidates, candidateNoConten) {
					return candidateNoConten
				}
				return "unsupported_other"
			}, func(m DebugMessageJSON, key string) string {
				switch key {
				case "supported":
					return "Supported"
				case candidateControl:
					return "Control-like payload"
				case candidateNoConten:
					return "No content"
				default:
					return "Unsupported (other)"
				}
			}, true
	default:
		return nil, nil, false
	}
}

func contains(s []string, v string) bool {
	for _, x := range s {
		if x == v {
			return true
		}
	}
	return false
}
