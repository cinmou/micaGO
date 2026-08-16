/// Client-side message + attachment models for the thread.
///
/// Mirrors the MicaGo `Message`/`Attachment` (v0.9 + v0.11.5) JSON, with extra
/// **optional** fields kept ready for future iMessage features (reactions,
/// replies) and local-only fields for optimistic sending. The server does not
/// yet expose reactions/replies or a `chatGuid` on messages — those stay
/// empty/null and the UI degrades gracefully.
library;

/// Identifies the underlying file an attachment points at, so duplicate records
/// for the same file collapse to one (C49). Mirrors the server's dedup key:
/// transfer/file name + byte size + MIME type, falling back to the unique guid
/// when there's no name to key on.
String _attachmentIdentityKey(AttachmentModel a) {
  final name = (a.transferName != null && a.transferName!.isNotEmpty)
      ? a.transferName!
      : (a.filename ?? '');
  if (name.isEmpty) return 'guid:${a.guid}';
  return 'file:$name\u0000${a.totalBytes}\u0000${a.mimeType ?? ''}';
}

/// Local delivery state for an outgoing message we sent from this client.
enum LocalSendState {
  none,
  sending,
  pending,
  sentUnconfirmed,
  confirmed,
  failed,
}

class AttachmentModel {
  final String guid;
  final String? filename;
  final String? mimeType;
  final String? originalMimeType;
  final String? transferName;
  final int totalBytes;
  final String downloadUrl; // server-relative, e.g. /api/attachments/<guid>
  final String? uti;
  final bool isSticker;
  final String attachmentKind; // image|video|audio|file|sticker|unknown
  final bool isVoiceMessage;
  final String displayKind;
  final bool isPreviewableImage;
  final bool needsPreviewConversion;

  /// Future: a server-generated bounded preview/thumbnail URL (e.g. a converted
  /// JPEG for TIFF/HEIC). Null today; when present, the inline image row and the
  /// chat-list thumbnail should prefer it over the full-size [downloadUrl].
  final String? previewUrl;

  const AttachmentModel({
    required this.guid,
    required this.downloadUrl,
    this.filename,
    this.mimeType,
    this.originalMimeType,
    this.transferName,
    this.totalBytes = 0,
    this.uti,
    this.isSticker = false,
    this.attachmentKind = 'unknown',
    this.isVoiceMessage = false,
    this.displayKind = 'unknown',
    this.isPreviewableImage = false,
    this.needsPreviewConversion = false,
    this.previewUrl,
  });

  bool get isImage =>
      !isVideo &&
      (attachmentKind == 'image' ||
          (isSticker && displayKind == 'sticker') ||
          (mimeType?.startsWith('image/') ?? false) ||
          (originalMimeType?.startsWith('image/') ?? false) ||
          _hasKnownImageExtension(displayName) ||
          _isImageUti(uti));

  /// C32: anything the server marks as a sticker, however it was flagged. Used
  /// to route stickers (incl. third-party sticker packs) to the sticker renderer
  /// so they never fall through to a generic/broken file card.
  bool get isStickerLike =>
      isSticker || displayKind == 'sticker' || attachmentKind == 'sticker';
  bool get canRenderSticker =>
      isSticker &&
      downloadUrl.isNotEmpty &&
      !needsPreviewConversion &&
      (isPreviewableImage ||
          mimeType == null ||
          (mimeType?.startsWith('image/') ?? false));
  bool get canRenderInlineImage =>
      canRenderSticker ||
      (isImage &&
          ((previewUrl?.isNotEmpty ?? false) ||
              (!needsPreviewConversion &&
                  (isPreviewableImage ||
                      _hasInlineRenderableImageExtension(displayName) ||
                      _isInlineRenderableImageUti(uti) ||
                      _isInlineRenderableImageMime(mimeType)))));
  bool get isTiff =>
      needsPreviewConversion ||
      mimeType == 'image/tiff' ||
      originalMimeType == 'image/tiff' ||
      uti == 'public.tiff' ||
      displayName.toLowerCase().endsWith('.tif') ||
      displayName.toLowerCase().endsWith('.tiff');
  bool get isAnimatedGif {
    final mime = (mimeType ?? '').trim().toLowerCase();
    final originalMime = (originalMimeType ?? '').trim().toLowerCase();
    final lowerUti = (uti ?? '').trim().toLowerCase();
    return mime == 'image/gif' ||
        originalMime == 'image/gif' ||
        lowerUti == 'public.gif' ||
        lowerUti == 'com.compuserve.gif' ||
        displayName.toLowerCase().endsWith('.gif');
  }

  bool get isAudio =>
      attachmentKind == 'audio' || (mimeType?.startsWith('audio/') ?? false);
  bool get isVideo =>
      attachmentKind == 'video' ||
      displayKind == 'video' ||
      (mimeType?.startsWith('video/') ?? false) ||
      (originalMimeType?.startsWith('video/') ?? false) ||
      _hasKnownVideoExtension(displayName) ||
      _isVideoUti(uti);

  /// C37: an iMessage shared-location attachment (vlocation). Rendered as a
  /// location card with "Open in Maps" rather than a raw file.
  bool get isLocation =>
      attachmentKind == 'location' ||
      displayKind == 'location' ||
      mimeType == 'text/x-vlocation' ||
      uti == 'public.vlocation';
  bool get isLinkPreview {
    final value = displayName.trim();
    return (mimeType == null || mimeType!.trim().isEmpty) &&
        (value.startsWith('http://') || value.startsWith('https://'));
  }

  /// Apple URLBalloon/link-preview payloads can arrive as UUID-like file rows
  /// with no MIME and no meaningful extension. BlueBubbles keeps those out of
  /// `realAttachments`; MicaGo should not render them as blank file cards.
  bool get isOpaquePreviewPayload {
    if (isStickerLike || isLinkPreview || isImage || isAudio || isVideo) {
      return false;
    }
    if ((mimeType?.trim().isNotEmpty ?? false) ||
        (originalMimeType?.trim().isNotEmpty ?? false)) {
      return false;
    }
    final name = displayName.trim();
    final lowerUti = (uti ?? '').trim().toLowerCase();
    final genericUti =
        lowerUti.isEmpty ||
        lowerUti == 'public.data' ||
        lowerUti == 'public.item' ||
        lowerUti == 'public.content';
    final noUsefulExtension = !_hasKnownRenderableExtension(name);
    return genericUti &&
        noUsefulExtension &&
        (attachmentKind == 'file' ||
            attachmentKind == 'unknown' ||
            displayKind == 'file' ||
            displayKind == 'unknown');
  }

  String get displayName => (transferName?.trim().isNotEmpty ?? false)
      ? transferName!.trim()
      : (filename?.trim().isNotEmpty ?? false)
      ? filename!.trim()
      : 'Attachment';

  static bool _hasKnownRenderableExtension(String name) {
    final lower = name.toLowerCase();
    const exts = [
      '.jpg',
      '.jpeg',
      '.png',
      '.gif',
      '.heic',
      '.heif',
      '.tif',
      '.tiff',
      '.webp',
      '.bmp',
      '.mov',
      '.mp4',
      '.m4v',
      '.mp3',
      '.m4a',
      '.aac',
      '.wav',
      '.caf',
      '.pdf',
      '.txt',
      '.vcf',
      '.zip',
    ];
    return exts.any(lower.endsWith);
  }

  static bool _hasKnownImageExtension(String name) {
    final lower = name.toLowerCase();
    const exts = [
      '.jpg',
      '.jpeg',
      '.png',
      '.gif',
      '.heic',
      '.heif',
      '.tif',
      '.tiff',
      '.webp',
      '.bmp',
    ];
    return exts.any(lower.endsWith);
  }

  static bool _hasKnownVideoExtension(String name) {
    final lower = name.toLowerCase();
    const exts = ['.mov', '.mp4', '.m4v', '.3gp', '.avi'];
    return exts.any(lower.endsWith);
  }

  static bool _hasInlineRenderableImageExtension(String name) {
    final lower = name.toLowerCase();
    const exts = [
      '.jpg',
      '.jpeg',
      '.png',
      '.gif',
      '.heic',
      '.heif',
      '.webp',
      '.bmp',
    ];
    return exts.any(lower.endsWith);
  }

  static bool _isImageUti(String? uti) {
    final value = (uti ?? '').trim().toLowerCase();
    return value == 'public.image' ||
        value == 'public.jpeg' ||
        value == 'public.png' ||
        value == 'public.heic' ||
        value == 'public.heif' ||
        value == 'public.gif' ||
        value == 'public.tiff' ||
        value == 'com.compuserve.gif' ||
        value == 'org.webmproject.webp' ||
        value.startsWith('public.image.');
  }

  static bool _isVideoUti(String? uti) {
    final value = (uti ?? '').trim().toLowerCase();
    return value == 'com.apple.quicktime-movie' ||
        value == 'public.mpeg-4' ||
        value == 'public.mpeg' ||
        value.startsWith('public.movie') ||
        value.startsWith('public.video');
  }

  static bool _isInlineRenderableImageUti(String? uti) {
    final value = (uti ?? '').trim().toLowerCase();
    return _isImageUti(value) && value != 'public.tiff';
  }

  static bool _isInlineRenderableImageMime(String? mimeType) {
    final value = (mimeType ?? '').trim().toLowerCase();
    return value.startsWith('image/') && value != 'image/tiff';
  }

  static bool _isTiffHint({
    required String displayName,
    required String? mimeType,
    required String? originalMimeType,
    required String? uti,
  }) {
    final lowerName = displayName.toLowerCase();
    return mimeType == 'image/tiff' ||
        originalMimeType == 'image/tiff' ||
        uti == 'public.tiff' ||
        lowerName.endsWith('.tif') ||
        lowerName.endsWith('.tiff');
  }

  factory AttachmentModel.fromJson(Map<String, dynamic> json) {
    int asInt(Object? v) => v is num ? v.toInt() : 0;
    final mimeType = json['mimeType'] as String?;
    final originalMimeType = json['originalMimeType'] as String?;
    final transferName = json['transferName'] as String?;
    final filename = json['filename'] as String?;
    final displayName = (transferName?.trim().isNotEmpty ?? false)
        ? transferName!.trim()
        : (filename?.trim().isNotEmpty ?? false)
        ? filename!.trim()
        : 'Attachment';
    final uti = json['uti'] as String?;
    final looksLikeImage =
        json['attachmentKind'] == 'image' ||
        (mimeType?.startsWith('image/') ?? false) ||
        _hasKnownImageExtension(displayName) ||
        _isImageUti(uti);
    final needsPreviewConversion =
        (json['needsPreviewConversion'] as bool?) ??
        _isTiffHint(
          displayName: displayName,
          mimeType: mimeType,
          originalMimeType: originalMimeType,
          uti: uti,
        );
    return AttachmentModel(
      guid: (json['guid'] as String?) ?? '',
      filename: filename,
      mimeType: mimeType,
      originalMimeType: originalMimeType,
      transferName: transferName,
      totalBytes: asInt(json['totalBytes']),
      downloadUrl: (json['downloadUrl'] as String?) ?? '',
      uti: uti,
      isSticker: (json['isSticker'] as bool?) ?? false,
      attachmentKind: (json['attachmentKind'] as String?) ?? 'unknown',
      isVoiceMessage: (json['isVoiceMessage'] as bool?) ?? false,
      displayKind: (json['displayKind'] as String?) ?? 'unknown',
      isPreviewableImage:
          (json['isPreviewableImage'] as bool?) ??
          (looksLikeImage && !needsPreviewConversion),
      needsPreviewConversion: needsPreviewConversion,
      previewUrl: json['previewUrl'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'guid': guid,
    'filename': filename,
    'mimeType': mimeType,
    'originalMimeType': originalMimeType,
    'transferName': transferName,
    'totalBytes': totalBytes,
    'downloadUrl': downloadUrl,
    'uti': uti,
    'isSticker': isSticker,
    'attachmentKind': attachmentKind,
    'isVoiceMessage': isVoiceMessage,
    'displayKind': displayKind,
    'isPreviewableImage': isPreviewableImage,
    'needsPreviewConversion': needsPreviewConversion,
    'previewUrl': previewUrl,
  };
}

/// A reaction/tapback — placeholder model only (the server does not surface
/// these yet, so the list is always empty for now).
class ReactionModel {
  final String type;
  final String? fromHandle;
  final bool isFromMe;
  final String? eventGuid;
  final int? createdAt;

  const ReactionModel({
    required this.type,
    this.fromHandle,
    this.isFromMe = false,
    this.eventGuid,
    this.createdAt,
  });

  factory ReactionModel.fromJson(Map<String, dynamic> json) => ReactionModel(
    type: (json['type'] as String?) ?? 'custom',
    fromHandle: json['fromHandle'] as String? ?? json['sender'] as String?,
    isFromMe: (json['isFromMe'] as bool?) ?? false,
    eventGuid: json['eventGuid'] as String? ?? json['guid'] as String?,
    createdAt: json['createdAt'] is num
        ? (json['createdAt'] as num).toInt()
        : null,
  );

  Map<String, dynamic> toJson() => {
    'type': type,
    'fromHandle': fromHandle,
    'isFromMe': isFromMe,
    'eventGuid': eventGuid,
    'createdAt': createdAt,
  };
}

class MessageModel {
  final String guid;
  final String? text;
  final String? subject;
  final String? service;
  final String? serviceCategory; // server-normalized: imessage|sms|rcs|unknown
  final int? dateCreated; // Unix ms
  final int? dateRead;
  final int? dateDelivered;
  final bool isFromMe;
  final bool isRead;
  final bool isDelivered;
  final String? handleId;
  final String? handleService;
  final bool cacheHasAttachments;
  final List<AttachmentModel> attachments;
  final bool hasAttributedBody;
  final String? semanticKind;
  final String? renderRecommendation;
  final bool isDebugOnly;
  final String? unsupportedReason;

  // Future/optional (empty until the server exposes them):
  final List<ReactionModel> reactions;
  final String? replyToGuid;

  // iMessage compatibility fields (BlueBubbles-compatible). Parsed when the
  // server exposes them. See docs/bluebubbles-compatibility-notes.md.
  final String? chatGuid; // owning chat (also on WS events for routing)
  final int?
  associatedMessageType; // tapback code: 2000-2005 add / 3000-3005 remove
  final String? associatedMessageGuid; // tapback target (p:/bp: prefixed)
  final String? threadOriginatorGuid; // reply target message guid
  final int itemType; // 0 = normal; >0 = service/group event
  final int groupActionType;
  final String? groupTitle;
  final String? balloonBundleId; // interactive app / effect balloon
  final String? expressiveSendStyleId; // message send effect
  final bool payloadDataPresent;
  final int errorCode; // >0 = send failed (server-side)
  final int? dateRetracted; // unsent timestamp (Unix ms)
  final int? dateEdited; // edited timestamp (Unix ms)
  final bool isRetracted;
  final bool isEdited;

  /// The original server JSON for this message — **debug only**. Never rendered
  /// as content; surfaced (redacted) in the Message Debug inspector.
  final Map<String, dynamic>? raw;

  // Local-only (optimistic send):
  final String? tempId;
  final LocalSendState localState;

  const MessageModel({
    required this.guid,
    this.text,
    this.subject,
    this.service,
    this.serviceCategory,
    this.dateCreated,
    this.dateRead,
    this.dateDelivered,
    this.isFromMe = false,
    this.isRead = false,
    this.isDelivered = false,
    this.handleId,
    this.handleService,
    this.cacheHasAttachments = false,
    this.attachments = const [],
    this.hasAttributedBody = false,
    this.semanticKind,
    this.renderRecommendation,
    this.isDebugOnly = false,
    this.unsupportedReason,
    this.reactions = const [],
    this.replyToGuid,
    this.chatGuid,
    this.associatedMessageType,
    this.associatedMessageGuid,
    this.threadOriginatorGuid,
    this.itemType = 0,
    this.groupActionType = 0,
    this.groupTitle,
    this.balloonBundleId,
    this.expressiveSendStyleId,
    this.payloadDataPresent = false,
    this.errorCode = 0,
    this.dateRetracted,
    this.dateEdited,
    this.isRetracted = false,
    this.isEdited = false,
    this.raw,
    this.tempId,
    this.localState = LocalSendState.none,
  });

  bool get hasText => (text?.trim().isNotEmpty ?? false);
  bool get hasAttachments => attachments.isNotEmpty;

  /// C37: handwritten / Digital Touch messages. Apple ships these as an
  /// interactive balloon whose attachment is the already-rendered media (a PNG
  /// for handwriting, a MOV for Digital Touch), so they render like normal
  /// media — but with no chat bubble behind them (transparent), like a sticker.
  bool get isHandwritten =>
      balloonBundleId == 'com.apple.Handwriting.HandwritingProvider';
  bool get isDigitalTouch =>
      balloonBundleId == 'com.apple.DigitalTouchBalloonProvider';
  bool get isEmbeddedMedia => isHandwritten || isDigitalTouch;
  bool get isInteractiveApp =>
      (balloonBundleId?.trim().isNotEmpty ?? false) && !isEmbeddedMedia;
  bool get isApplePoll =>
      balloonBundleId ==
      'com.apple.messages.MSMessageExtensionBalloonPlugin:0000000000:com.apple.messages.Polls';

  /// Stable identity for de-duplication: real GUID if present, else the local
  /// temp id of an optimistic outgoing message.
  String get dedupeKey => guid.isNotEmpty ? guid : (tempId ?? '');

  MessageModel copyWith({
    String? guid,
    String? text,
    int? dateRead,
    int? dateDelivered,
    bool? isRead,
    bool? isDelivered,
    List<AttachmentModel>? attachments,
    LocalSendState? localState,
    int? dateCreated,
    int? errorCode,
    int? dateRetracted,
    int? dateEdited,
    bool? isRetracted,
    bool? isEdited,
    List<ReactionModel>? reactions,
  }) {
    return MessageModel(
      guid: guid ?? this.guid,
      text: text ?? this.text,
      subject: subject,
      service: service,
      serviceCategory: serviceCategory,
      dateCreated: dateCreated ?? this.dateCreated,
      dateRead: dateRead ?? this.dateRead,
      dateDelivered: dateDelivered ?? this.dateDelivered,
      isFromMe: isFromMe,
      isRead: isRead ?? this.isRead,
      isDelivered: isDelivered ?? this.isDelivered,
      handleId: handleId,
      handleService: handleService,
      cacheHasAttachments: cacheHasAttachments,
      attachments: attachments ?? this.attachments,
      hasAttributedBody: hasAttributedBody,
      semanticKind: semanticKind,
      renderRecommendation: renderRecommendation,
      isDebugOnly: isDebugOnly,
      unsupportedReason: unsupportedReason,
      reactions: reactions ?? this.reactions,
      replyToGuid: replyToGuid,
      chatGuid: chatGuid,
      associatedMessageType: associatedMessageType,
      associatedMessageGuid: associatedMessageGuid,
      threadOriginatorGuid: threadOriginatorGuid,
      itemType: itemType,
      groupActionType: groupActionType,
      groupTitle: groupTitle,
      balloonBundleId: balloonBundleId,
      expressiveSendStyleId: expressiveSendStyleId,
      payloadDataPresent: payloadDataPresent,
      errorCode: errorCode ?? this.errorCode,
      dateRetracted: dateRetracted ?? this.dateRetracted,
      dateEdited: dateEdited ?? this.dateEdited,
      isRetracted: isRetracted ?? this.isRetracted,
      isEdited: isEdited ?? this.isEdited,
      raw: raw,
      tempId: tempId,
      localState: localState ?? this.localState,
    );
  }

  factory MessageModel.fromJson(Map<String, dynamic> json) {
    int? asInt(Object? v) => v is num ? v.toInt() : null;
    final handle = json['handle'];
    // Dedup attachments (C49). A real chat.db can hold several attachment records
    // (distinct guids) for one underlying file, so deduping by guid alone isn't
    // enough — the same photo / file / sticker / voice clip would still render
    // twice. Collapse by file identity (name + size + type) when a name exists,
    // else fall back to guid. The server dedupes the same way; this is the safety
    // net for history already cached before that fix.
    final seenAttachmentKeys = <String>{};
    final atts =
        (json['attachments'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .map(AttachmentModel.fromJson)
            .where((a) => !a.isOpaquePreviewPayload)
            .where((a) => seenAttachmentKeys.add(_attachmentIdentityKey(a)))
            .toList(growable: false) ??
        const <AttachmentModel>[];
    final reactions =
        (json['reactions'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .map(ReactionModel.fromJson)
            .toList(growable: false) ??
        const <ReactionModel>[];
    return MessageModel(
      guid: (json['guid'] as String?) ?? '',
      text: json['text'] as String?,
      subject: json['subject'] as String?,
      service: json['service'] as String?,
      serviceCategory: json['serviceCategory'] as String?,
      dateCreated: asInt(json['dateCreated']),
      dateRead: asInt(json['dateRead']),
      dateDelivered: asInt(json['dateDelivered']),
      isFromMe: (json['isFromMe'] as bool?) ?? false,
      isRead: (json['isRead'] as bool?) ?? false,
      isDelivered: (json['isDelivered'] as bool?) ?? false,
      handleId: handle is Map<String, dynamic> ? handle['id'] as String? : null,
      handleService: handle is Map<String, dynamic>
          ? handle['service'] as String?
          : null,
      cacheHasAttachments: (json['cacheHasAttachments'] as bool?) ?? false,
      attachments: atts,
      hasAttributedBody: (json['hasAttributedBody'] as bool?) ?? false,
      semanticKind: json['semanticKind'] as String?,
      renderRecommendation: json['renderRecommendation'] as String?,
      isDebugOnly: (json['isDebugOnly'] as bool?) ?? false,
      unsupportedReason: json['unsupportedReason'] as String?,
      reactions: reactions,
      replyToGuid: json['replyToGuid'] as String?,
      chatGuid: json['chatGuid'] as String?,
      associatedMessageType: asInt(json['associatedMessageType']),
      associatedMessageGuid: json['associatedMessageGuid'] as String?,
      threadOriginatorGuid: json['threadOriginatorGuid'] as String?,
      itemType: asInt(json['itemType']) ?? 0,
      groupActionType: asInt(json['groupActionType']) ?? 0,
      groupTitle: json['groupTitle'] as String?,
      balloonBundleId: json['balloonBundleId'] as String?,
      expressiveSendStyleId: json['expressiveSendStyleId'] as String?,
      payloadDataPresent: (json['payloadDataPresent'] as bool?) ?? false,
      errorCode: asInt(json['error']) ?? 0,
      dateRetracted: asInt(json['dateRetracted']),
      dateEdited: asInt(json['dateEdited']),
      isRetracted: (json['isRetracted'] as bool?) ?? false,
      isEdited: (json['isEdited'] as bool?) ?? false,
      raw: json,
      tempId: json['tempId'] as String?,
      localState: LocalSendState.values.firstWhere(
        (s) => s.name == json['localState'],
        orElse: () => LocalSendState.confirmed,
      ),
    );
  }

  Map<String, dynamic> toJson({String? chatGuidFallback}) => {
    'guid': guid,
    'text': text,
    'subject': subject,
    'service': service,
    'serviceCategory': serviceCategory,
    'dateCreated': dateCreated,
    'dateRead': dateRead,
    'dateDelivered': dateDelivered,
    'isFromMe': isFromMe,
    'isRead': isRead,
    'isDelivered': isDelivered,
    'handle': handleId == null
        ? null
        : {'id': handleId, 'service': handleService},
    'cacheHasAttachments': cacheHasAttachments,
    'attachments': attachments.map((a) => a.toJson()).toList(),
    'hasAttributedBody': hasAttributedBody,
    'semanticKind': semanticKind,
    'renderRecommendation': renderRecommendation,
    'isDebugOnly': isDebugOnly,
    'unsupportedReason': unsupportedReason,
    'reactions': reactions.map((r) => r.toJson()).toList(),
    'replyToGuid': replyToGuid,
    'chatGuid': chatGuid ?? chatGuidFallback,
    'associatedMessageType': associatedMessageType,
    'associatedMessageGuid': associatedMessageGuid,
    'threadOriginatorGuid': threadOriginatorGuid,
    'itemType': itemType,
    'groupActionType': groupActionType,
    'groupTitle': groupTitle,
    'balloonBundleId': balloonBundleId,
    'expressiveSendStyleId': expressiveSendStyleId,
    'payloadDataPresent': payloadDataPresent,
    'error': errorCode,
    'dateRetracted': dateRetracted,
    'dateEdited': dateEdited,
    'isRetracted': isRetracted,
    'isEdited': isEdited,
    'tempId': tempId,
    'localState': localState.name,
  };

  /// Builds an optimistic outgoing message for the composer.
  factory MessageModel.optimistic({
    required String tempId,
    required String text,
    required int dateCreated,
  }) {
    return MessageModel(
      guid: '',
      text: text,
      isFromMe: true,
      dateCreated: dateCreated,
      tempId: tempId,
      localState: LocalSendState.sending,
    );
  }

  /// C63: an optimistic outgoing *attachment* message. The local attachment's
  /// guid is `local-<tempId>`; its bytes are seeded into the media cache under
  /// that key so the bubble renders the file immediately without any fetch.
  /// Only directly-decodable images render inline; everything else shows the
  /// clean file card while sending (the confirmed row brings the real viewer).
  factory MessageModel.optimisticAttachment({
    required String tempId,
    required String filename,
    required int totalBytes,
    required int dateCreated,
  }) {
    final inlineImage = AttachmentModel._hasInlineRenderableImageExtension(
      filename,
    );
    return MessageModel(
      guid: '',
      isFromMe: true,
      dateCreated: dateCreated,
      cacheHasAttachments: true,
      attachments: [
        AttachmentModel(
          guid: localAttachmentGuid(tempId),
          downloadUrl: '',
          filename: filename,
          transferName: filename,
          totalBytes: totalBytes,
          attachmentKind: inlineImage ? 'image' : 'file',
          displayKind: inlineImage ? 'image' : 'file',
          isPreviewableImage: inlineImage,
        ),
      ],
      tempId: tempId,
      localState: LocalSendState.sending,
    );
  }

  static String localAttachmentGuid(String tempId) => 'local-$tempId';
}

/// C63: whether a pending outgoing attachment message matches a confirmed
/// server row by file identity — the server can't echo `tempGuid` for
/// attachment sends (202 optimistic, no text to match), so the client
/// reconciles by name/size. Same-name OR same-size (voice conversion renames
/// the file; some transports rewrite bytes) within the caller's time window.
bool attachmentSendMatches(MessageModel local, MessageModel server) {
  if (local.attachments.isEmpty || server.attachments.isEmpty) return false;
  for (final l in local.attachments) {
    final localName = l.displayName.toLowerCase();
    final localStem = _fileNameStem(localName);
    final localBytes = l.totalBytes;
    for (final s in server.attachments) {
      final serverName = s.displayName.toLowerCase();
      if (localName.isNotEmpty &&
          localName != 'attachment' &&
          serverName == localName) {
        return true;
      }
      // C66: server-side conversion keeps the base name but changes the
      // extension (voice .m4a → .caf and similar) — match on the stem.
      if (localStem.isNotEmpty &&
          localStem != 'attachment' &&
          _fileNameStem(serverName) == localStem) {
        return true;
      }
      if (localBytes > 0 && s.totalBytes == localBytes) return true;
    }
  }
  return false;
}

/// Lower-cased file name without its last extension ('voice.m4a' → 'voice').
String _fileNameStem(String lowerName) {
  final dot = lowerName.lastIndexOf('.');
  return dot <= 0 ? lowerName : lowerName.substring(0, dot);
}
