/// C74: "is there a newer build?" against the project's GitHub releases.
///
/// Read-only and unauthenticated — it hits the public releases API, compares
/// the newest published tag with the running version, and reports the result.
/// Nothing is downloaded or installed; the UI links to the release page and the
/// user decides. Every failure path resolves to [UpdateCheckResult.unknown] so a
/// rate-limited or offline check never blocks or alarms.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

const String kUpdateReleasesApi =
    'https://api.github.com/repos/cinmou/MicaGo/releases/latest';
const String kUpdateReleasesPage =
    'https://github.com/cinmou/MicaGo/releases/latest';

enum UpdateCheckStatus { upToDate, updateAvailable, unknown }

class UpdateCheckResult {
  final UpdateCheckStatus status;

  /// The newest published version (no leading `v`), when known.
  final String? latestVersion;

  /// Where to send the user to get it.
  final String releaseUrl;

  const UpdateCheckResult({
    required this.status,
    this.latestVersion,
    this.releaseUrl = kUpdateReleasesPage,
  });

  static const unknown = UpdateCheckResult(status: UpdateCheckStatus.unknown);
}

/// Parses a version string into comparable numeric parts, ignoring a leading
/// `v` and any pre-release suffix (`0.64.0-beta.1` → [0, 64, 0]).
List<int> parseVersionParts(String raw) {
  var value = raw.trim();
  if (value.startsWith('v') || value.startsWith('V')) value = value.substring(1);
  final cut = value.indexOf(RegExp(r'[-+ ]'));
  if (cut > 0) value = value.substring(0, cut);
  return [
    for (final part in value.split('.'))
      int.tryParse(part.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0,
  ];
}

/// True when [latest] is strictly newer than [current]. Missing trailing parts
/// count as 0, so `0.64` == `0.64.0`.
bool isNewerVersion(String latest, String current) {
  final a = parseVersionParts(latest);
  final b = parseVersionParts(current);
  final length = a.length > b.length ? a.length : b.length;
  for (var i = 0; i < length; i++) {
    final left = i < a.length ? a[i] : 0;
    final right = i < b.length ? b[i] : 0;
    if (left != right) return left > right;
  }
  return false;
}

/// Pure: turns a releases-API body into a result (no I/O — unit tested).
UpdateCheckResult resultFromReleaseJson(String body, String currentVersion) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) return UpdateCheckResult.unknown;
    if (decoded['draft'] == true) return UpdateCheckResult.unknown;
    final tag = (decoded['tag_name'] as String?)?.trim();
    if (tag == null || tag.isEmpty) return UpdateCheckResult.unknown;
    final url = (decoded['html_url'] as String?)?.trim();
    final latest = tag.startsWith('v') || tag.startsWith('V')
        ? tag.substring(1)
        : tag;
    return UpdateCheckResult(
      status: isNewerVersion(tag, currentVersion)
          ? UpdateCheckStatus.updateAvailable
          : UpdateCheckStatus.upToDate,
      latestVersion: latest,
      releaseUrl: url == null || url.isEmpty ? kUpdateReleasesPage : url,
    );
  } catch (_) {
    return UpdateCheckResult.unknown;
  }
}

/// Asks GitHub for the newest release. Never throws.
Future<UpdateCheckResult> checkForUpdate(
  String currentVersion, {
  http.Client? client,
}) async {
  final http200 = client ?? http.Client();
  try {
    final response = await http200
        .get(
          Uri.parse(kUpdateReleasesApi),
          headers: const {
            'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28',
          },
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) return UpdateCheckResult.unknown;
    return resultFromReleaseJson(response.body, currentVersion);
  } catch (_) {
    return UpdateCheckResult.unknown;
  } finally {
    if (client == null) http200.close();
  }
}
