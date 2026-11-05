// NaviUpload for Windows.
//
// Desktop sibling of the NaviUpload iOS app: upload music straight
// into a Navidrome library — pick or drag-and-drop audio files, or
// paste a URL and let the companion server fetch it (direct audio
// links are saved as-is; page links such as YouTube go through yt-dlp
// on the server). The visual system mirrors Viu for Windows on
// purpose: Material 3 with the expressive scheme variant, the same
// enlarged text theme, big rounded cards and filled buttons, a
// navigation rail, and a row of selectable accent colors — with
// Navi Blue (the Navidrome record blue) as the default accent.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------------------
// Accents (Viu's curated set, reordered: Navi Blue first / default)
// ---------------------------------------------------------------------------

class Accent {
  final String name;
  final Color seed;
  const Accent(this.name, this.seed);
}

const List<Accent> kAccents = [
  Accent('Navi Blue', Color(0xFF1890EB)),
  Accent('Red', Color(0xFFE5323B)),
  Accent('Purple', Color(0xFF9D6BFF)),
  Accent('Pink', Color(0xFFFF5C8A)),
  Accent('Orange', Color(0xFFFF8A3D)),
  Accent('Green', Color(0xFF35C26B)),
  Accent('Teal', Color(0xFF2BB3A3)),
];

const List<String> kAudioExtensions = [
  'mp3', 'm4a', 'flac', 'wav', 'ogg', 'opus', 'aac', 'aif', 'aiff', 'wma',
];

/// This build's marketing version (kept in step with pubspec.yaml;
/// the update checker compares it against GitHub's latest release).
const String kAppVersion = '0.5.1';

/// Numeric dotted-version compare: is [candidate] newer than
/// [current]? ("0.10.0" > "0.9.9")
bool isNewerVersion(String candidate, String current) {
  List<int> parts(String v) =>
      v.split('.').map((p) => int.tryParse(p) ?? 0).toList();
  final a = parts(candidate);
  final b = parts(current);
  for (var i = 0; i < a.length || i < b.length; i++) {
    final x = i < a.length ? a[i] : 0;
    final y = i < b.length ? b[i] : 0;
    if (x != y) return x > y;
  }
  return false;
}

// ---------------------------------------------------------------------------
// Small formatting helpers (no intl dependency, like the rest of the app)
// ---------------------------------------------------------------------------

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB'];
  double value = bytes / 1024;
  int unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[unit]}';
}

String thousands(int n) {
  final s = n.toString();
  final b = StringBuffer();
  for (int i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

String formatDateTime(DateTime d) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} '
      '${two(d.hour)}:${two(d.minute)}';
}

String baseName(String path) => path.replaceAll('\\', '/').split('/').last;

// ---------------------------------------------------------------------------
// API models
// ---------------------------------------------------------------------------

class ApiException implements Exception {
  final String message;
  const ApiException(this.message);
  @override
  String toString() => message;
}

class HealthResult {
  final int libraryFiles;
  final bool scanConfigured;
  const HealthResult({required this.libraryFiles, required this.scanConfigured});
}

class UploadResult {
  final String savedAs;
  final int size;
  final bool scanTriggered;
  final String? via;
  final int alsoSaved;
  final String folder;
  final bool enriched;
  final String? metadataSource;
  final bool lyricsEmbedded;
  final String? matchedTitle;
  final List<UploadResult> files;
  final List<String> failedTracks;
  // How the server pulled a direct download down (0.5.0).
  final bool downloadAccelerated;
  final int downloadConnections;

  const UploadResult({
    required this.savedAs,
    required this.size,
    required this.scanTriggered,
    this.via,
    this.alsoSaved = 0,
    this.folder = '',
    this.enriched = false,
    this.metadataSource,
    this.lyricsEmbedded = false,
    this.matchedTitle,
    this.files = const [],
    this.failedTracks = const [],
    this.downloadAccelerated = false,
    this.downloadConnections = 1,
  });

  factory UploadResult.fromJson(Map<String, dynamic> j) {
    final rawFiles = j['files'];
    final dl = j['download'];
    return UploadResult(
      savedAs: (j['saved_as'] ?? j['savedAs'] ?? '').toString(),
      size: (j['size'] as num?)?.toInt() ?? 0,
      scanTriggered:
          j['scan_triggered'] == true || j['scanTriggered'] == true,
      via: j['via'] as String?,
      alsoSaved: (j['also_saved'] as num?)?.toInt() ?? 0,
      folder: (j['folder'] as String?) ?? '',
      enriched: j['enriched'] == true,
      metadataSource: j['metadata_source'] as String?,
      lyricsEmbedded: j['lyrics_embedded'] == true,
      matchedTitle: j['matched_title'] as String?,
      files: rawFiles is List
          ? rawFiles
              .whereType<Map<String, dynamic>>()
              .map(UploadResult.fromJson)
              .toList()
          : const [],
      failedTracks: j['failed_tracks'] is List
          ? (j['failed_tracks'] as List).map((e) => e.toString()).toList()
          : const [],
      downloadAccelerated:
          dl is Map<String, dynamic> && dl['accelerated'] == true,
      downloadConnections: dl is Map<String, dynamic>
          ? (dl['connections'] as num?)?.toInt() ?? 1
          : 1,
    );
  }

  /// One short line per thing the server did to the file while
  /// saving it — shown under queue rows and URL results.
  List<String> get processingNotes {
    final notes = <String>[];
    if (enriched && matchedTitle != null) {
      notes.add('Tagged as "$matchedTitle"');
    } else if (enriched) {
      notes.add('Metadata cleaned up');
    }
    if (lyricsEmbedded) notes.add('Lyrics embedded');
    if (downloadAccelerated) {
      notes.add('⚡ Accelerated download ×$downloadConnections');
    }
    if (folder.isNotEmpty) notes.add('Filed under $folder');
    if (via != null) notes.add('via $via');
    if (failedTracks.isNotEmpty) {
      notes.add('${failedTracks.length} track'
          '${failedTracks.length == 1 ? '' : 's'} couldn\'t be downloaded');
    }
    return notes;
  }
}

class HistoryItem {
  final String name;
  final String source; // 'File' or 'URL'
  final DateTime at;
  final int size;
  final bool scanTriggered;
  final String savedAs;
  // Library sub-folder the server filed the song under ('' = root).
  final String folder;
  // True for entries merged in from the server's /recent list rather
  // than recorded by this app.
  final bool fromServer;
  // Tracks of a URL batch that failed to download ("Artist - Title"),
  // kept so History can offer a one-tap retry.
  final List<String> failedTracks;
  // The link a URL batch came from ('' for file uploads).
  final String sourceUrl;

  const HistoryItem({
    required this.name,
    required this.source,
    required this.at,
    required this.size,
    required this.scanTriggered,
    required this.savedAs,
    this.folder = '',
    this.fromServer = false,
    this.failedTracks = const [],
    this.sourceUrl = '',
  });

  HistoryItem withFailedTracks(List<String> tracks) => HistoryItem(
        name: name,
        source: source,
        at: at,
        size: size,
        scanTriggered: scanTriggered,
        savedAs: savedAs,
        folder: folder,
        fromServer: fromServer,
        failedTracks: tracks,
        sourceUrl: sourceUrl,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'source': source,
        'at': at.toIso8601String(),
        'size': size,
        'scanTriggered': scanTriggered,
        'savedAs': savedAs,
        'folder': folder,
        'failedTracks': failedTracks,
        'sourceUrl': sourceUrl,
      };

  factory HistoryItem.fromJson(Map<String, dynamic> j) => HistoryItem(
        name: j['name'] as String? ?? '',
        source: j['source'] as String? ?? 'File',
        at: DateTime.tryParse(j['at'] as String? ?? '') ?? DateTime.now(),
        size: (j['size'] as num?)?.toInt() ?? 0,
        scanTriggered: j['scanTriggered'] as bool? ?? false,
        savedAs: j['savedAs'] as String? ?? (j['name'] as String? ?? ''),
        folder: j['folder'] as String? ?? '',
        failedTracks: j['failedTracks'] is List
            ? [for (final t in j['failedTracks'] as List) t.toString()]
            : const [],
        sourceUrl: j['sourceUrl'] as String? ?? '',
      );
}

class LibraryStats {
  final int libraryFiles;
  final int uploadedTotal;
  final int uploadedBytes;
  final DateTime? lastUploadAt;
  const LibraryStats({
    required this.libraryFiles,
    required this.uploadedTotal,
    required this.uploadedBytes,
    this.lastUploadAt,
  });
}

/// One copy of a duplicated song (GET /duplicates).
class DuplicateFileInfo {
  final String file; // library-relative path
  final int size;
  final String title;
  final String artist;
  final String album;
  final double duration;
  const DuplicateFileInfo({
    required this.file,
    required this.size,
    required this.title,
    required this.artist,
    required this.album,
    required this.duration,
  });
  factory DuplicateFileInfo.fromJson(Map<String, dynamic> j) =>
      DuplicateFileInfo(
        file: j['file'] as String? ?? '',
        size: (j['size'] as num?)?.toInt() ?? 0,
        title: j['title'] as String? ?? '',
        artist: j['artist'] as String? ?? '',
        album: j['album'] as String? ?? '',
        duration: (j['duration'] as num?)?.toDouble() ?? 0,
      );
}

/// A song that exists more than once; files are biggest-first, so
/// files.first is the keeper.
class DuplicateGroupInfo {
  final String title;
  final String artist;
  final List<DuplicateFileInfo> files;
  final int wastedBytes;
  const DuplicateGroupInfo({
    required this.title,
    required this.artist,
    required this.files,
    required this.wastedBytes,
  });
  factory DuplicateGroupInfo.fromJson(Map<String, dynamic> j) =>
      DuplicateGroupInfo(
        title: j['title'] as String? ?? '',
        artist: j['artist'] as String? ?? '',
        files: j['files'] is List
            ? [
                for (final f in j['files'] as List)
                  DuplicateFileInfo.fromJson(f as Map<String, dynamic>)
              ]
            : const [],
        wastedBytes: (j['wasted_bytes'] as num?)?.toInt() ?? 0,
      );
}

class DuplicatesResult {
  final List<DuplicateGroupInfo> groups;
  final int groupCount;
  final int fileCount;
  final int wastedBytes;
  final int scanned;
  const DuplicatesResult({
    required this.groups,
    required this.groupCount,
    required this.fileCount,
    required this.wastedBytes,
    required this.scanned,
  });
  factory DuplicatesResult.fromJson(Map<String, dynamic> j) =>
      DuplicatesResult(
        groups: j['groups'] is List
            ? [
                for (final g in j['groups'] as List)
                  DuplicateGroupInfo.fromJson(g as Map<String, dynamic>)
              ]
            : const [],
        groupCount: (j['group_count'] as num?)?.toInt() ?? 0,
        fileCount: (j['file_count'] as num?)?.toInt() ?? 0,
        wastedBytes: (j['wasted_bytes'] as num?)?.toInt() ?? 0,
        scanned: (j['scanned'] as num?)?.toInt() ?? 0,
      );
}

class DeleteFilesResult {
  final List<String> deleted;
  final int errorCount;
  final bool scanTriggered;
  const DeleteFilesResult({
    required this.deleted,
    required this.errorCount,
    required this.scanTriggered,
  });
}

class ScanResult {
  final bool configured;
  final bool triggered;
  const ScanResult({required this.configured, required this.triggered});
}

class DuplicateCheck {
  final String name;
  final bool exists;
  final bool sameSize;
  const DuplicateCheck({
    required this.name,
    required this.exists,
    required this.sameSize,
  });
}

class LibraryMatch {
  final bool configured;
  final bool found;
  final String? matchedTitle;
  const LibraryMatch({
    required this.configured,
    required this.found,
    this.matchedTitle,
  });
}

// ---------------------------------------------------------------------------
// App state
// ---------------------------------------------------------------------------

class AppState extends ChangeNotifier {
  final NaviApi api = NaviApi();
  static const FlutterSecureStorage _secure = FlutterSecureStorage();
  SharedPreferences? _prefs;

  bool booted = false;

  String serverUrl = 'https://upload.07051969.xyz';
  String? token;

  // Optional per-user debrid keys, sent to the server with URL
  // downloads (X-TorBox-Key / X-Premiumize-Key). Blank means "use
  // whatever keys the server itself has configured".
  String? torboxKey;
  String? premiumizeKey;

  int accentIndex = 0;
  int appearanceMode = 2; // 0 system, 1 light, 2 dark (default dark)

  // Server-side processing preferences (Settings → Processing),
  // sent with every upload. File uploads stay untagged by default —
  // albums usually arrive already tagged.
  bool enrichURLs = true;
  bool enrichFiles = false;
  bool embedLyrics = true;
  bool sortFolders = false;
  bool skipDuplicates = true;

  Accent get accent => kAccents[accentIndex.clamp(0, kAccents.length - 1)];

  ThemeMode get themeMode => switch (appearanceMode) {
        1 => ThemeMode.light,
        2 => ThemeMode.dark,
        _ => ThemeMode.system,
      };

  List<HistoryItem> history = [];

  // Last /health probe (null until the first test runs).
  bool checkingHealth = false;
  HealthResult? lastHealth;
  String? healthError;
  DateTime? lastHealthAt;
  // Verdict of the authenticated probe that follows a successful
  // /health (which itself needs no token): "accepted" / "rejected" /
  // "missing". Null when no verdict yet.
  String? tokenCheck;

  Future<void> boot() async {
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;
    serverUrl =
        prefs.getString('naviupload_server_url') ?? serverUrl;
    accentIndex = prefs.getInt('naviupload_accent') ?? 0;
    appearanceMode = prefs.getInt('naviupload_appearance') ?? 2;
    enrichURLs = prefs.getBool('processing.enrichURLs') ?? true;
    enrichFiles = prefs.getBool('processing.enrichFiles') ?? false;
    embedLyrics = prefs.getBool('processing.embedLyrics') ?? true;
    sortFolders = prefs.getBool('processing.sortFolders') ?? false;
    skipDuplicates = prefs.getBool('processing.skipDuplicates') ?? true;
    token = await _secure.read(key: 'upload_token');
    torboxKey = await _secure.read(key: 'torbox_api_key');
    premiumizeKey = await _secure.read(key: 'premiumize_api_key');
    final raw = prefs.getString('naviupload_history');
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          history = decoded
              .whereType<Map<String, dynamic>>()
              .map(HistoryItem.fromJson)
              .toList();
        }
      } catch (_) {
        // A corrupt history blob should never stop the app booting.
        history = [];
      }
    }
    booted = true;
    notifyListeners();
    unawaited(testConnection());
    unawaited(checkForUpdate());
  }

  Future<void> setServerUrl(String url) async {
    var v = url.trim();
    while (v.endsWith('/')) {
      v = v.substring(0, v.length - 1);
    }
    serverUrl = v;
    lastHealth = null;
    healthError = null;
    notifyListeners();
    await _prefs?.setString('naviupload_server_url', v);
  }

  Future<void> setToken(String value) async {
    final v = value.trim();
    token = v.isEmpty ? null : v;
    notifyListeners();
    if (v.isEmpty) {
      await _secure.delete(key: 'upload_token');
    } else {
      await _secure.write(key: 'upload_token', value: v);
    }
  }

  Future<void> setTorboxKey(String value) async {
    final v = value.trim();
    torboxKey = v.isEmpty ? null : v;
    notifyListeners();
    if (v.isEmpty) {
      await _secure.delete(key: 'torbox_api_key');
    } else {
      await _secure.write(key: 'torbox_api_key', value: v);
    }
  }

  Future<void> setPremiumizeKey(String value) async {
    final v = value.trim();
    premiumizeKey = v.isEmpty ? null : v;
    notifyListeners();
    if (v.isEmpty) {
      await _secure.delete(key: 'premiumize_api_key');
    } else {
      await _secure.write(key: 'premiumize_api_key', value: v);
    }
  }

  Future<void> setAccent(int i) async {
    accentIndex = i;
    notifyListeners();
    await _prefs?.setInt('naviupload_accent', i);
  }

  Future<void> setAppearance(int mode) async {
    appearanceMode = mode;
    notifyListeners();
    await _prefs?.setInt('naviupload_appearance', mode);
  }

  Future<void> setEnrichURLs(bool v) async {
    enrichURLs = v;
    notifyListeners();
    await _prefs?.setBool('processing.enrichURLs', v);
  }

  Future<void> setEnrichFiles(bool v) async {
    enrichFiles = v;
    notifyListeners();
    await _prefs?.setBool('processing.enrichFiles', v);
  }

  Future<void> setEmbedLyrics(bool v) async {
    embedLyrics = v;
    notifyListeners();
    await _prefs?.setBool('processing.embedLyrics', v);
  }

  Future<void> setSortFolders(bool v) async {
    sortFolders = v;
    notifyListeners();
    await _prefs?.setBool('processing.sortFolders', v);
  }

  Future<void> setSkipDuplicates(bool v) async {
    skipDuplicates = v;
    notifyListeners();
    await _prefs?.setBool('processing.skipDuplicates', v);
  }

  Future<void> _saveHistory() async {
    await _prefs?.setString(
      'naviupload_history',
      jsonEncode(history.map((h) => h.toJson()).toList()),
    );
  }

  void addHistory(HistoryItem item) {
    history = [item, ...history];
    if (history.length > 200) {
      history = history.sublist(0, 200);
    }
    notifyListeners();
    unawaited(_saveHistory());
  }

  void clearHistory() {
    history = [];
    notifyListeners();
    unawaited(_saveHistory());
  }

  /// After a retry, replace one entry's still-failed track list (an
  /// empty list clears the retry offer).
  void replaceHistoryFailedTracks(HistoryItem old, List<String> remaining) {
    final i = history.indexOf(old);
    if (i < 0) return;
    final copy = [...history];
    copy[i] = old.withFailedTracks(remaining);
    history = copy;
    notifyListeners();
    unawaited(_saveHistory());
  }

  // --- Update checker -------------------------------------------------
  // GitHub's latest release vs this build, checked at most every 6
  // hours; the Upload page shows a small banner when one is newer.
  String? updateVersion;
  String? updateUrl;
  String? _dismissedUpdate;

  Future<void> checkForUpdate() async {
    final prefs = _prefs;
    if (prefs == null) return;
    _dismissedUpdate = prefs.getString('update.dismissedVersion');
    final lastMs = prefs.getInt('update.lastCheck') ?? 0;
    final stale = DateTime.now().millisecondsSinceEpoch - lastMs >
        6 * 3600 * 1000;
    if (stale) {
      await prefs.setInt(
          'update.lastCheck', DateTime.now().millisecondsSinceEpoch);
      try {
        final r = await http.get(
          Uri.parse(
              'https://api.github.com/repos/c12n/navidrome-uploader/releases/latest'),
          headers: const {'Accept': 'application/vnd.github+json'},
        );
        if (r.statusCode == 200) {
          final j = jsonDecode(r.body) as Map<String, dynamic>;
          var tag = (j['tag_name'] as String? ?? '');
          if (tag.startsWith('v')) tag = tag.substring(1);
          await prefs.setString('update.cachedVersion', tag);
          await prefs.setString(
              'update.cachedUrl', j['html_url'] as String? ?? '');
        }
      } catch (_) {
        // Offline or blocked: keep whatever was cached.
      }
    }
    final cached = prefs.getString('update.cachedVersion');
    final cachedUrl = prefs.getString('update.cachedUrl');
    if (cached != null &&
        cachedUrl != null &&
        cached != _dismissedUpdate &&
        isNewerVersion(cached, kAppVersion)) {
      updateVersion = cached;
      updateUrl = cachedUrl;
    } else {
      updateVersion = null;
      updateUrl = null;
    }
    notifyListeners();
  }

  Future<void> dismissUpdate() async {
    if (updateVersion != null) {
      _dismissedUpdate = updateVersion;
      await _prefs?.setString('update.dismissedVersion', updateVersion!);
    }
    updateVersion = null;
    updateUrl = null;
    notifyListeners();
  }

  Future<void> testConnection() async {
    if (checkingHealth) return;
    checkingHealth = true;
    notifyListeners();
    try {
      final h = await api.health();
      lastHealth = h;
      healthError = null;
      lastHealthAt = DateTime.now();
      // /health is public — also probe an authenticated endpoint so a
      // wrong token is caught here, not at the first upload.
      final t = token;
      if (t == null || t.isEmpty) {
        tokenCheck = 'missing';
      } else {
        try {
          tokenCheck = await api.recentStatus() == 200 ? 'accepted' : 'rejected';
        } catch (_) {
          tokenCheck = null;
        }
      }
    } catch (e) {
      lastHealth = null;
      healthError = e.toString();
      lastHealthAt = DateTime.now();
      tokenCheck = null;
    } finally {
      checkingHealth = false;
      notifyListeners();
    }
  }
}

final AppState appState = AppState();

// ---------------------------------------------------------------------------
// API client for the NaviUpload companion server
// ---------------------------------------------------------------------------

class NaviApi {
  Uri _uri(String path) {
    var base = appState.serverUrl.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return Uri.parse('$base$path');
  }

  Map<String, String> get _authHeaders {
    final t = appState.token;
    if (t == null || t.isEmpty) return const {};
    return {'X-Upload-Token': t};
  }

  /// The user's own debrid keys, when saved in Settings. The server
  /// prefers these over its configured keys; absent means server keys.
  Map<String, String> get _debridHeaders {
    final headers = <String, String>{};
    final tb = appState.torboxKey;
    if (tb != null && tb.isNotEmpty) headers['X-TorBox-Key'] = tb;
    final pm = appState.premiumizeKey;
    if (pm != null && pm.isNotEmpty) headers['X-Premiumize-Key'] = pm;
    return headers;
  }

  /// Pull the server's own error message out of a response body.
  /// The companion answers {"error": "..."}; stock FastAPI errors use
  /// {"detail": "..."}. Either way the UI shows the server's words,
  /// never a generic "something went wrong".
  String _serverMessage(http.Response r) {
    try {
      final decoded = jsonDecode(r.body);
      if (decoded is Map) {
        final msg = decoded['error'] ?? decoded['detail'] ?? decoded['message'];
        if (msg != null) return msg.toString();
      }
    } catch (_) {
      // Not JSON — fall through to the raw body.
    }
    final body = r.body.trim();
    if (body.isNotEmpty) return 'HTTP ${r.statusCode}: $body';
    return 'HTTP ${r.statusCode}';
  }

  UploadResult _parseUpload(http.Response r) {
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw ApiException(_serverMessage(r));
    }
    try {
      final decoded = jsonDecode(r.body);
      if (decoded is Map<String, dynamic>) {
        return UploadResult.fromJson(decoded);
      }
    } catch (_) {
      // Fall through to the generic-but-honest error below.
    }
    throw const ApiException('The server answered with an unreadable reply.');
  }

  /// Status code of an authenticated GET /recent — 200 means the
  /// saved token is the server's token, 401 means it is not.
  Future<int> recentStatus() async {
    final r = await http
        .get(_uri('/recent'), headers: _authHeaders)
        .timeout(const Duration(seconds: 15));
    return r.statusCode;
  }

  Future<HealthResult> health() async {
    final http.Response r;
    try {
      r = await http
          .get(_uri('/health'), headers: _authHeaders)
          .timeout(const Duration(seconds: 15));
    } on ApiException {
      rethrow;
    } catch (e) {
      throw ApiException('Could not reach the server: $e');
    }
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw ApiException(_serverMessage(r));
    }
    try {
      final decoded = jsonDecode(r.body);
      if (decoded is Map) {
        return HealthResult(
          libraryFiles:
              (decoded['library_files'] as num?)?.toInt() ??
                  (decoded['libraryFiles'] as num?)?.toInt() ??
                  0,
          scanConfigured: decoded['scan_configured'] == true ||
              decoded['scanConfigured'] == true,
        );
      }
    } catch (_) {
      // Fall through.
    }
    throw const ApiException('The server answered with an unreadable reply.');
  }

  /// Multipart upload of one file with real byte-counted progress.
  /// The body is assembled by hand and streamed through a counting
  /// transformer, so [onProgress] reports sent/total for the file
  /// bytes themselves (plus the tiny multipart framing).
  Future<UploadResult> uploadFile(
    File file,
    String displayName, {
    bool enrich = false,
    bool lyrics = false,
    bool sort = false,
    required void Function(double progress) onProgress,
  }) async {
    final fileLength = await file.length();
    final boundary =
        'naviupload-${DateTime.now().millisecondsSinceEpoch.toRadixString(16)}';
    var safeName = displayName
        .replaceAll('"', "'")
        .replaceAll('\r', ' ')
        .replaceAll('\n', ' ');
    if (safeName.isEmpty) safeName = 'upload';
    // The processing flags ride along as plain form fields ahead of
    // the file part, in the same hand-assembled multipart body.
    String formField(String name, bool value) => '--$boundary\r\n'
        'Content-Disposition: form-data; name="$name"\r\n\r\n'
        '${value ? 'true' : 'false'}\r\n';
    final headerBuffer = StringBuffer()
      ..write(formField('enrich', enrich))
      ..write(formField('lyrics', lyrics))
      ..write(formField('sort', sort))
      ..write('--$boundary\r\n')
      ..write('Content-Disposition: form-data; name="file"; '
          'filename="$safeName"\r\n')
      ..write('Content-Type: application/octet-stream\r\n\r\n');
    final header = utf8.encode(headerBuffer.toString());
    final footer = utf8.encode('\r\n--$boundary--\r\n');
    final total = header.length + fileLength + footer.length;

    var sent = 0;
    Stream<List<int>> body() async* {
      sent += header.length;
      onProgress(total == 0 ? 0 : sent / total);
      yield header;
      await for (final chunk in file.openRead()) {
        sent += chunk.length;
        onProgress(total == 0 ? 0 : sent / total);
        yield chunk;
      }
      yield footer;
    }

    final req = http.StreamedRequest('POST', _uri('/upload'));
    req.headers.addAll(_authHeaders);
    req.headers['Content-Type'] = 'multipart/form-data; boundary=$boundary';
    req.contentLength = total;
    body().listen(
      req.sink.add,
      onError: (Object e, StackTrace st) {
        req.sink.addError(e, st);
      },
      onDone: () {
        req.sink.close();
      },
      cancelOnError: true,
    );

    final http.Response r;
    try {
      final streamed = await req.send();
      r = await http.Response.fromStream(streamed);
    } on ApiException {
      rethrow;
    } catch (e) {
      throw ApiException('Upload failed: $e');
    }
    return _parseUpload(r);
  }

  Future<UploadResult> uploadUrl(
    String url, {
    bool enrich = false,
    bool lyrics = false,
    bool sort = false,
  }) async {
    final http.Response r;
    try {
      r = await http.post(
        _uri('/url'),
        headers: {
          'Content-Type': 'application/json',
          ..._authHeaders,
          ..._debridHeaders,
        },
        body: jsonEncode({
          'url': url,
          'enrich': enrich,
          'lyrics': lyrics,
          'sort': sort,
        }),
      );
    } catch (e) {
      throw ApiException('Could not reach the server: $e');
    }
    return _parseUpload(r);
  }

  /// Ask Navidrome (through the server) to rescan the library now.
  Future<ScanResult> scanLibrary() async {
    final http.Response r;
    try {
      r = await http
          .post(_uri('/scan'), headers: _authHeaders)
          .timeout(const Duration(seconds: 30));
    } catch (e) {
      throw ApiException('Could not reach the server: $e');
    }
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw ApiException(_serverMessage(r));
    }
    try {
      final decoded = jsonDecode(r.body);
      if (decoded is Map) {
        return ScanResult(
          configured: decoded['scan_configured'] == true,
          triggered: decoded['scan_triggered'] == true,
        );
      }
    } catch (_) {
      // Fall through.
    }
    throw const ApiException('The server answered with an unreadable reply.');
  }

  /// Library + upload counters for the Upload page stats card.
  Future<LibraryStats> fetchStats() async {
    final http.Response r;
    try {
      r = await http
          .get(_uri('/stats'), headers: _authHeaders)
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      throw ApiException('Could not reach the server: $e');
    }
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw ApiException(_serverMessage(r));
    }
    try {
      final decoded = jsonDecode(r.body);
      if (decoded is Map) {
        final rawAt = (decoded['last_upload_at'] as num?)?.toInt();
        return LibraryStats(
          libraryFiles: (decoded['library_files'] as num?)?.toInt() ?? 0,
          uploadedTotal: (decoded['uploaded_total'] as num?)?.toInt() ?? 0,
          uploadedBytes: (decoded['uploaded_bytes'] as num?)?.toInt() ?? 0,
          // The contract says epoch; accept seconds, tolerate ms.
          lastUploadAt: rawAt == null || rawAt <= 0
              ? null
              : DateTime.fromMillisecondsSinceEpoch(
                  rawAt > 100000000000 ? rawAt : rawAt * 1000),
        );
      }
    } catch (_) {
      // Fall through.
    }
    throw const ApiException('The server answered with an unreadable reply.');
  }

  /// Ask the server which of these files the library already has.
  /// Results come back in request order.
  Future<List<DuplicateCheck>> checkDuplicates(
      List<({String name, int size})> items) async {
    final http.Response r;
    try {
      r = await http
          .post(
            _uri('/check'),
            headers: {'Content-Type': 'application/json', ..._authHeaders},
            body: jsonEncode({
              'items': [
                for (final i in items) {'name': i.name, 'size': i.size},
              ],
            }),
          )
          .timeout(const Duration(seconds: 30));
    } catch (e) {
      throw ApiException('Could not reach the server: $e');
    }
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw ApiException(_serverMessage(r));
    }
    try {
      final decoded = jsonDecode(r.body);
      if (decoded is Map && decoded['results'] is List) {
        return [
          for (final e in decoded['results'] as List)
            if (e is Map)
              DuplicateCheck(
                name: (e['name'] ?? '').toString(),
                exists: e['exists'] == true,
                sameSize: e['same_size'] == true,
              ),
        ];
      }
    } catch (_) {
      // Fall through.
    }
    throw const ApiException('The server answered with an unreadable reply.');
  }

  /// Has Navidrome indexed this song yet? Used after a scan-triggered
  /// download to confirm the track is actually in the library.
  Future<LibraryMatch> inLibrary(String title, String artist) async {
    final uri = _uri('/in-library').replace(queryParameters: {
      'title': title,
      'artist': artist,
    });
    final http.Response r;
    try {
      r = await http
          .get(uri, headers: _authHeaders)
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      throw ApiException('Could not reach the server: $e');
    }
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw ApiException(_serverMessage(r));
    }
    try {
      final decoded = jsonDecode(r.body);
      if (decoded is Map) {
        return LibraryMatch(
          configured: decoded['configured'] == true,
          found: decoded['found'] == true,
          matchedTitle: decoded['matched_title'] as String?,
        );
      }
    } catch (_) {
      // Fall through.
    }
    throw const ApiException('The server answered with an unreadable reply.');
  }

  /// The server's own upload log (newest first), as history entries
  /// flagged fromServer so the History page can chip them.
  /// GET /duplicates — songs that exist more than once in the
  /// library (same artist + title), biggest copy first per group.
  Future<DuplicatesResult> fetchDuplicates() async {
    final http.Response r;
    try {
      r = await http.get(_uri('/duplicates'), headers: _authHeaders);
    } catch (e) {
      throw ApiException('Could not reach the server: $e');
    }
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw ApiException(_serverMessage(r));
    }
    return DuplicatesResult.fromJson(
        jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// POST /delete — remove library files by relative path (the
  /// duplicate finder's cleanup).
  Future<DeleteFilesResult> deleteFiles(List<String> files) async {
    final http.Response r;
    try {
      r = await http.post(
        _uri('/delete'),
        headers: {
          'Content-Type': 'application/json',
          ..._authHeaders,
        },
        body: jsonEncode({'files': files}),
      );
    } catch (e) {
      throw ApiException('Could not reach the server: $e');
    }
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw ApiException(_serverMessage(r));
    }
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return DeleteFilesResult(
      deleted: j['deleted'] is List
          ? [for (final f in j['deleted'] as List) f.toString()]
          : const [],
      errorCount: j['errors'] is List ? (j['errors'] as List).length : 0,
      scanTriggered: j['scan_triggered'] as bool? ?? false,
    );
  }

  /// POST /tracks — fetch specific tracks ("Artist - Title") via
  /// the server's search route; retries a batch's failed tracks.
  Future<UploadResult> retryTracks(
    List<String> tracks, {
    bool enrich = true,
    bool lyrics = true,
    bool sort = false,
  }) async {
    final http.Response r;
    try {
      r = await http.post(
        _uri('/tracks'),
        headers: {
          'Content-Type': 'application/json',
          ..._authHeaders,
          ..._debridHeaders,
        },
        body: jsonEncode({
          'tracks': tracks,
          'enrich': enrich,
          'lyrics': lyrics,
          'sort': sort,
        }),
      );
    } catch (e) {
      throw ApiException('Could not reach the server: $e');
    }
    return _parseUpload(r);
  }

  Future<List<HistoryItem>> fetchRecent() async {
    final http.Response r;
    try {
      r = await http
          .get(_uri('/recent'), headers: _authHeaders)
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      throw ApiException('Could not reach the server: $e');
    }
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw ApiException(_serverMessage(r));
    }
    try {
      final decoded = jsonDecode(r.body);
      if (decoded is Map && decoded['uploads'] is List) {
        return [
          for (final e in decoded['uploads'] as List)
            if (e is Map)
              HistoryItem(
                name: (e['saved_as'] ?? '').toString(),
                source: e['source'] == 'url' ? 'URL' : 'File',
                at: DateTime.fromMillisecondsSinceEpoch(
                    ((e['at'] as num?)?.toInt() ?? 0) * 1000),
                size: (e['size'] as num?)?.toInt() ?? 0,
                scanTriggered: e['scan_triggered'] == true,
                savedAs: (e['saved_as'] ?? '').toString(),
                folder: (e['folder'] as String?) ?? '',
                fromServer: true,
              ),
        ];
      }
    } catch (_) {
      // Fall through.
    }
    throw const ApiException('The server answered with an unreadable reply.');
  }
}

// ---------------------------------------------------------------------------
// Theme — copied from Viu's visual system (sizes and shapes are theirs)
// ---------------------------------------------------------------------------

TextTheme _textTheme(Brightness brightness) {
  // Deliberately larger than the Material defaults — the same
  // readability pass as Viu. Styles stay relative so the platform
  // font-size accessibility setting scales them further.
  return const TextTheme(
    headlineMedium: TextStyle(fontSize: 27, fontWeight: FontWeight.w700),
    headlineSmall: TextStyle(fontSize: 23, fontWeight: FontWeight.w600),
    titleLarge: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
    titleMedium: TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
    bodyLarge: TextStyle(fontSize: 18),
    bodyMedium: TextStyle(fontSize: 17),
    bodySmall: TextStyle(fontSize: 15),
    labelLarge: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const NaviUploadApp());
  unawaited(appState.boot());
}

class NaviUploadApp extends StatelessWidget {
  const NaviUploadApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        // Material 3 Expressive, like Viu: the expressive scheme
        // variant gives bolder, higher-energy color mappings from the
        // same accent seed, paired with large rounded shapes below.
        final light = ColorScheme.fromSeed(
          seedColor: appState.accent.seed,
          brightness: Brightness.light,
          dynamicSchemeVariant: DynamicSchemeVariant.expressive,
        );
        final dark = ColorScheme.fromSeed(
          seedColor: appState.accent.seed,
          brightness: Brightness.dark,
          dynamicSchemeVariant: DynamicSchemeVariant.expressive,
        );
        ThemeData themeFor(ColorScheme scheme, {bool isDark = false}) {
          return ThemeData(
            useMaterial3: true,
            colorScheme: scheme,
            scaffoldBackgroundColor: isDark ? const Color(0xFF0A0A0E) : null,
            textTheme: _textTheme(isDark ? Brightness.dark : Brightness.light),
            cardTheme: CardThemeData(
              elevation: 0,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24)),
              color: scheme.surfaceContainerLow,
            ),
            filledButtonTheme: FilledButtonThemeData(
              style: FilledButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
                textStyle:
                    const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(28)),
              ),
            ),
            navigationRailTheme: NavigationRailThemeData(
              indicatorColor: scheme.primaryContainer,
              selectedIconTheme:
                  IconThemeData(color: scheme.onPrimaryContainer, size: 28),
              unselectedIconTheme: const IconThemeData(size: 26),
              selectedLabelTextStyle: const TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w600),
              unselectedLabelTextStyle: const TextStyle(fontSize: 14),
            ),
          );
        }

        return MaterialApp(
          title: 'NaviUpload',
          debugShowCheckedModeBanner: false,
          themeMode: appState.themeMode,
          theme: themeFor(light),
          darkTheme: themeFor(dark, isDark: true),
          home: const HomeShell(),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// App icon (built from widgets — the album disc + upload arrow badge)
// ---------------------------------------------------------------------------

class AppIconBadge extends StatelessWidget {
  final double size;
  const AppIconBadge({super.key, this.size = 52});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: size,
            height: size,
            decoration: const BoxDecoration(
              color: Color(0xFF1890EB),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.album, color: Colors.white, size: size * 0.94),
          ),
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              width: size * 0.44,
              height: size * 0.44,
              decoration: BoxDecoration(
                color: scheme.surface,
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFF1890EB), width: 2),
              ),
              child: Icon(Icons.arrow_upward,
                  color: const Color(0xFF1890EB), size: size * 0.30),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Home shell: header (icon, name, connection chip) + navigation rail
// ---------------------------------------------------------------------------

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  static const _pages = <Widget>[
    UploadPage(),
    UrlPage(),
    HistoryPage(),
    SettingsPage(),
  ];

  Widget _connectionChip(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final String label;
    final Color dot;
    if (appState.checkingHealth) {
      label = 'Checking…';
      dot = scheme.outline;
    } else if (appState.lastHealth != null) {
      label =
          'Connected · ${thousands(appState.lastHealth!.libraryFiles)} songs';
      dot = Colors.green;
    } else if (appState.healthError != null) {
      label = 'Server unreachable';
      dot = scheme.error;
    } else {
      label = 'Not tested';
      dot = scheme.outline;
    }
    return ActionChip(
      avatar: Icon(Icons.circle, size: 12, color: dot),
      label: Text(label),
      onPressed: () => unawaited(appState.testConnection()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
            child: Row(
              children: [
                const AppIconBadge(),
                const SizedBox(width: 16),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('NaviUpload', style: theme.textTheme.headlineSmall),
                    Text(
                      'for Navidrome',
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
                const Spacer(),
                _connectionChip(context),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final extended = constraints.maxWidth >= 1000;
                return Row(
                  children: [
                    NavigationRail(
                      selectedIndex: _tab,
                      onDestinationSelected: (i) =>
                          setState(() => _tab = i),
                      extended: extended,
                      labelType: extended
                          ? NavigationRailLabelType.none
                          : NavigationRailLabelType.all,
                      destinations: const [
                        NavigationRailDestination(
                          icon: Icon(Icons.upload_file_outlined),
                          selectedIcon: Icon(Icons.cloud_upload),
                          label: Text('Upload'),
                        ),
                        NavigationRailDestination(
                          icon: Icon(Icons.link),
                          selectedIcon: Icon(Icons.link),
                          label: Text('URL'),
                        ),
                        NavigationRailDestination(
                          icon: Icon(Icons.history),
                          selectedIcon: Icon(Icons.history),
                          label: Text('History'),
                        ),
                        NavigationRailDestination(
                          icon: Icon(Icons.settings_outlined),
                          selectedIcon: Icon(Icons.settings),
                          label: Text('Settings'),
                        ),
                      ],
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(
                      child: IndexedStack(index: _tab, children: _pages),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader(this.text);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 22, 4, 10),
      child: Text(text, style: theme.textTheme.titleLarge),
    );
  }
}

// ---------------------------------------------------------------------------
// Upload page: drag-and-drop zone, file picker, sequential upload queue
// ---------------------------------------------------------------------------

enum QueueStatus { queued, uploading, done, error, skipped }

class QueueItem {
  final String name;
  final String path;
  final int size;
  double progress = 0;
  QueueStatus status = QueueStatus.queued;
  String? savedAs;
  bool scanTriggered = false;
  String? message;
  // Full server reply for the done row's processing notes.
  UploadResult? result;
  // Failed upload attempts so far (one automatic retry is allowed).
  int attempts = 0;
  // The library holds a different file with this exact byte size.
  bool sizeNote = false;

  QueueItem({required this.name, required this.path, required this.size});
}

enum UrlStatus { waiting, busy, done, error }

class UrlItem {
  final String url;
  UrlStatus status = UrlStatus.waiting;
  UploadResult? result;
  String? message;
  // Set a few seconds after a scan-triggered save, once the server
  // has checked whether Navidrome has indexed the track.
  String? libraryNote;

  UrlItem(this.url);
}

class UploadPage extends StatefulWidget {
  const UploadPage({super.key});

  @override
  State<UploadPage> createState() => _UploadPageState();
}

class _UploadPageState extends State<UploadPage> {
  final List<QueueItem> _queue = [];
  bool _dragging = false;
  bool _processing = false;
  bool _paused = false;

  // Library stats card state.
  LibraryStats? _stats;
  String? _statsError;
  bool _scanBusy = false;
  String? _scanOutcome;

  @override
  void initState() {
    super.initState();
    unawaited(_loadStatsWhenReady());
  }

  Future<void> _loadStatsWhenReady() async {
    // The page is built before AppState.boot() lands; wait for the
    // saved server/token before asking the server for numbers.
    while (!appState.booted) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (!mounted) return;
    }
    await _loadStats();
  }

  Future<void> _loadStats() async {
    try {
      final s = await appState.api.fetchStats();
      if (!mounted) return;
      setState(() {
        _stats = s;
        _statsError = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _statsError =
            'Could not load library stats — check the server in Settings.';
      });
    }
  }

  Future<void> _refreshLibrary() async {
    if (_scanBusy) return;
    setState(() {
      _scanBusy = true;
      _scanOutcome = null;
    });
    try {
      final res = await appState.api.scanLibrary();
      if (!mounted) return;
      final String outcome;
      if (res.triggered) {
        outcome =
            'Refresh triggered — new songs appear in Navidrome within seconds.';
      } else if (res.configured) {
        outcome =
            'Navidrome did not accept the refresh this time. Try again in a moment.';
      } else {
        outcome = 'Instant refresh is not set up on the server yet '
            '(it needs the Navidrome login in the server config). '
            'Uploads still appear after Navidrome\'s own scheduled scan.';
      }
      setState(() {
        _scanOutcome = outcome;
        _scanBusy = false;
      });
      if (res.triggered) {
        await Future<void>.delayed(const Duration(seconds: 2));
        if (mounted) await _loadStats();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _scanOutcome = e.toString();
        _scanBusy = false;
      });
    }
  }

  int get _waitingCount =>
      _queue.where((q) => q.status == QueueStatus.queued).length;

  int get _failedCount =>
      _queue.where((q) => q.status == QueueStatus.error).length;

  void _snack(String text) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(text)));
  }

  void _enqueue(String name, String path, int size) {
    _queue.add(QueueItem(name: name, path: path, size: size));
  }

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: kAudioExtensions,
      allowMultiple: true,
      withData: false,
    );
    if (result == null || !mounted) return;
    setState(() {
      for (final f in result.files) {
        final path = f.path;
        if (path == null) continue;
        var size = f.size;
        if (size <= 0) {
          try {
            size = File(path).lengthSync();
          } catch (_) {
            size = 0;
          }
        }
        _enqueue(f.name, path, size);
      }
    });
    // Start automatically (0.5.1): picking files IS the instruction
    // to upload them — no second tap on "Upload N files".
    _runQueue();
  }

  void _addDropped(List<dynamic> files) {
    var skipped = 0;
    setState(() {
      for (final f in files) {
        final String path = f.path as String;
        final String name = f.name as String;
        final ext =
            name.contains('.') ? name.split('.').last.toLowerCase() : '';
        if (!kAudioExtensions.contains(ext)) {
          skipped++;
          continue;
        }
        var size = 0;
        try {
          size = File(path).lengthSync();
        } catch (_) {
          size = 0;
        }
        _enqueue(name, path, size);
      }
    });
    if (skipped > 0) {
      _snack(skipped == 1
          ? 'Skipped 1 non-audio file.'
          : 'Skipped $skipped non-audio files.');
    }
    // Dropped files start uploading right away too (0.5.1).
    _runQueue();
  }

  /// Start (or restart) the queue run: duplicate-check everything
  /// waiting, upload sequentially, then give each failure one
  /// automatic second chance.
  Future<void> _runQueue() async {
    if (_processing) return;
    _processing = true;
    _paused = false;
    if (mounted) setState(() {});
    try {
      if (appState.skipDuplicates) {
        final waiting =
            _queue.where((q) => q.status == QueueStatus.queued).toList();
        if (waiting.isNotEmpty) {
          try {
            final checks = await appState.api.checkDuplicates([
              for (final q in waiting) (name: q.name, size: q.size),
            ]);
            if (mounted) {
              setState(() {
                for (var i = 0; i < waiting.length && i < checks.length; i++) {
                  if (checks[i].exists) {
                    waiting[i].status = QueueStatus.skipped;
                  } else if (checks[i].sameSize) {
                    waiting[i].sizeNote = true;
                  }
                }
              });
            }
          } catch (_) {
            // A failed duplicate check must never block uploads.
          }
        }
      }
      await _drainQueue();
      final failed = _queue
          .where((q) => q.status == QueueStatus.error && q.attempts <= 1)
          .toList();
      if (failed.isNotEmpty) {
        if (mounted) {
          setState(() {
            for (final q in failed) {
              q.status = QueueStatus.queued;
              q.message = null;
            }
          });
        }
        await _drainQueue();
      }
    } finally {
      _processing = false;
      _paused = false;
      if (mounted) setState(() {});
      unawaited(_loadStats());
    }
  }

  /// Manual retry: failed items get a fresh attempt budget.
  void _retryFailed() {
    if (_processing) return;
    setState(() {
      for (final q in _queue) {
        if (q.status == QueueStatus.error) {
          q.attempts = 0;
          q.status = QueueStatus.queued;
          q.message = null;
        }
      }
    });
    unawaited(_runQueue());
  }

  /// Upload every queued item, one at a time, honouring pause.
  Future<void> _drainQueue() async {
    while (true) {
      while (_paused) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        if (!mounted) return;
      }
      QueueItem? next;
      for (final q in _queue) {
        if (q.status == QueueStatus.queued) {
          next = q;
          break;
        }
      }
      if (next == null) break;
      final item = next;
      if (mounted) {
        setState(() {
          item.status = QueueStatus.uploading;
          item.progress = 0;
        });
      }
      try {
        final res = await appState.api.uploadFile(
          File(item.path),
          item.name,
          enrich: appState.enrichFiles,
          lyrics: appState.embedLyrics,
          sort: appState.sortFolders,
          onProgress: (p) {
            if (mounted) {
              setState(() => item.progress = p);
            }
          },
        );
        if (mounted) {
          setState(() {
            item.status = QueueStatus.done;
            item.progress = 1;
            item.savedAs = res.savedAs;
            item.scanTriggered = res.scanTriggered;
            item.result = res;
          });
        }
        appState.addHistory(HistoryItem(
          name: res.savedAs.isNotEmpty ? res.savedAs : item.name,
          source: 'File',
          at: DateTime.now(),
          size: res.size > 0 ? res.size : item.size,
          scanTriggered: res.scanTriggered,
          savedAs: res.savedAs,
          folder: res.folder,
        ));
      } catch (e) {
        if (mounted) {
          setState(() {
            item.status = QueueStatus.error;
            item.attempts++;
            item.message = e.toString();
          });
        }
      }
    }
  }

  Widget _queueRow(BuildContext context, QueueItem item) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final Widget trailing;
    final Widget bottom;
    switch (item.status) {
      case QueueStatus.queued:
        trailing = const Icon(Icons.schedule);
        bottom = Text(
          item.sizeNote
              ? 'A file with this size is already in the library — '
                  'will upload anyway'
              : 'Waiting',
          style: theme.textTheme.bodyMedium,
        );
      case QueueStatus.uploading:
        trailing = Text('${(item.progress * 100).round()}%',
            style: theme.textTheme.titleMedium);
        bottom = LinearProgressIndicator(value: item.progress);
      case QueueStatus.done:
        trailing = Icon(Icons.check_circle, color: Colors.green, size: 30);
        bottom = Text(
          [
            item.scanTriggered
                ? 'Saved as ${item.savedAs} · library scan started'
                : 'Saved as ${item.savedAs}',
            ...?item.result?.processingNotes,
          ].join(' · '),
          style: theme.textTheme.bodyMedium,
        );
      case QueueStatus.error:
        trailing = Icon(Icons.error, color: scheme.error, size: 30);
        bottom = Text(
          item.message ?? 'Upload failed',
          style:
              theme.textTheme.bodyMedium?.copyWith(color: scheme.error),
        );
      case QueueStatus.skipped:
        trailing =
            Icon(Icons.library_music, color: scheme.onSurfaceVariant, size: 30);
        bottom = Text(
          'Already in your library — skipped',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: scheme.onSurfaceVariant),
        );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 14),
        child: Row(
          children: [
            Icon(Icons.music_note, size: 30, color: scheme.primary),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.name,
                      style: theme.textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  Text(formatBytes(item.size),
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant)),
                  const SizedBox(height: 6),
                  bottom,
                ],
              ),
            ),
            const SizedBox(width: 12),
            trailing,
          ],
        ),
      ),
    );
  }

  Widget _statsCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    Widget stat(String value, String label) {
      return Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value, style: theme.textTheme.headlineSmall),
            Text(
              label,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Your library', style: theme.textTheme.titleLarge),
            const SizedBox(height: 14),
            if (_statsError != null)
              Text(
                _statsError!,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: scheme.error),
              )
            else if (_stats == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: LinearProgressIndicator(),
              )
            else
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  stat(thousands(_stats!.libraryFiles),
                      'Songs in the library'),
                  stat(thousands(_stats!.uploadedTotal),
                      'Uploaded via NaviUpload'),
                  if (_stats!.uploadedBytes > 0)
                    stat(formatBytes(_stats!.uploadedBytes), 'Added'),
                ],
              ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                onPressed: _scanBusy ? null : _refreshLibrary,
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh library'),
              ),
            ),
            if (_scanBusy) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
            ],
            if (_scanOutcome != null) ...[
              const SizedBox(height: 12),
              Text(_scanOutcome!, style: theme.textTheme.bodyMedium),
            ],
          ],
        ),
      ),
    );
  }

  Widget _queueControls(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          FilledButton.icon(
            onPressed: (_processing || _waitingCount == 0)
                ? null
                : () => unawaited(_runQueue()),
            icon: const Icon(Icons.cloud_upload),
            label: Text(_waitingCount == 1
                ? 'Upload 1 file'
                : 'Upload $_waitingCount files'),
          ),
          if (_processing)
            FilledButton.tonalIcon(
              onPressed: () => setState(() => _paused = !_paused),
              icon: Icon(_paused ? Icons.play_arrow : Icons.pause),
              label: Text(_paused ? 'Resume' : 'Pause'),
            ),
          if (!_processing && _failedCount > 0)
            FilledButton.tonalIcon(
              onPressed: _retryFailed,
              icon: const Icon(Icons.replay),
              label: Text(_failedCount == 1
                  ? 'Retry 1 failed'
                  : 'Retry $_failedCount failed'),
            ),
          TextButton(
            onPressed: () => setState(() {
              _queue.removeWhere(
                  (q) => q.status != QueueStatus.uploading);
            }),
            child: const Text('Clear list'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      children: [
        const _SectionHeader('Upload files'),
        if (appState.updateVersion != null) ...[
          Card(
            color: scheme.primaryContainer,
            child: ListTile(
              leading: Icon(Icons.system_update,
                  color: scheme.onPrimaryContainer),
              title: Text(
                  'NaviUpload ${appState.updateVersion} is available'),
              subtitle: const Text(
                  'Get the new build from the GitHub release page. '
                  'Click to copy the link.'),
              trailing: IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Dismiss',
                onPressed: () => appState.dismissUpdate(),
              ),
              onTap: () async {
                await Clipboard.setData(
                    ClipboardData(text: appState.updateUrl ?? ''));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('Release page link copied.')));
                }
              },
            ),
          ),
          const SizedBox(height: 8),
        ],
        _statsCard(context),
        const SizedBox(height: 8),
        DropTarget(
          onDragEntered: (_) => setState(() => _dragging = true),
          onDragExited: (_) => setState(() => _dragging = false),
          onDragDone: (details) {
            setState(() => _dragging = false);
            _addDropped(details.files);
          },
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 24),
            decoration: BoxDecoration(
              color: _dragging
                  ? scheme.primaryContainer
                  : scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: _dragging ? scheme.primary : scheme.outlineVariant,
                width: _dragging ? 3 : 2,
              ),
            ),
            child: Column(
              children: [
                Icon(Icons.cloud_upload,
                    size: 56,
                    color: _dragging ? scheme.primary : scheme.onSurfaceVariant),
                const SizedBox(height: 12),
                Text(
                  _dragging ? 'Let go to add the files' : 'Drop audio files here',
                  style: theme.textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 6),
                Text(
                  'MP3, M4A, FLAC, WAV, OGG, Opus, AAC and more',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: scheme.onSurfaceVariant),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: _pickFiles,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Choose audio files'),
                ),
              ],
            ),
          ),
        ),
        if (_queue.isNotEmpty) ...[
          const _SectionHeader('Queue'),
          _queueControls(context),
          for (final item in _queue) _queueRow(context, item),
        ] else ...[
          const SizedBox(height: 28),
          Center(
            child: Text(
              'Add files, then press Upload — they go one at a time, '
              'straight into the Navidrome library folder.',
              style: theme.textTheme.bodyLarge
                  ?.copyWith(color: scheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// URL page: paste a link, the server downloads it into the library
// ---------------------------------------------------------------------------

class UrlPage extends StatefulWidget {
  const UrlPage({super.key});

  @override
  State<UrlPage> createState() => _UrlPageState();
}

class _UrlPageState extends State<UrlPage> {
  final TextEditingController _urlCtrl = TextEditingController();
  final List<UrlItem> _items = [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // The download button label counts the links as they are typed.
    _urlCtrl.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

  /// Split pasted text into links: whitespace-separated http(s)
  /// tokens, deduped, order preserved.
  static List<String> parseLinks(String text) {
    final seen = <String>{};
    final out = <String>[];
    for (final token in text.split(RegExp(r'\s+'))) {
      final t = token.trim();
      if ((t.startsWith('http://') || t.startsWith('https://')) &&
          seen.add(t)) {
        out.add(t);
      }
    }
    return out;
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) return;
    setState(() {
      _urlCtrl.text = text;
    });
  }

  Future<void> _submit() async {
    if (_busy) return;
    final links = parseLinks(_urlCtrl.text);
    if (links.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Paste at least one link first.')),
      );
      return;
    }
    setState(() {
      _busy = true;
      _items
        ..clear()
        ..addAll([for (final l in links) UrlItem(l)]);
    });
    try {
      for (final item in _items) {
        if (!mounted) return;
        setState(() => item.status = UrlStatus.busy);
        try {
          final res = await appState.api.uploadUrl(
            item.url,
            enrich: appState.enrichURLs,
            lyrics: appState.embedLyrics,
            sort: appState.sortFolders,
          );
          if (!mounted) return;
          setState(() {
            item.status = UrlStatus.done;
            item.result = res;
          });
          _recordHistory(item.url, res);
          if (res.scanTriggered) {
            unawaited(_verifyInLibrary(item, res));
          }
        } catch (e) {
          if (!mounted) return;
          setState(() {
            item.status = UrlStatus.error;
            item.message = e.toString();
          });
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// One history entry per saved file: every entry of files[] when
  /// the server returned a list (playlists, ZIPs), else the single
  /// result itself.
  void _recordHistory(String url, UploadResult res) {
    var first = true;
    void addOne(String savedAs, int size, bool scan) {
      appState.addHistory(HistoryItem(
        name: savedAs.isNotEmpty ? savedAs : url,
        source: 'URL',
        at: DateTime.now(),
        size: size,
        scanTriggered: scan,
        savedAs: savedAs,
        folder: res.folder,
        // The batch's failed tracks ride on its first entry, so
        // History can offer a retry for just those.
        failedTracks: first ? res.failedTracks : const [],
        sourceUrl: first ? url : '',
      ));
      first = false;
    }

    if (res.files.isNotEmpty) {
      for (final f in res.files) {
        addOne(f.savedAs, f.size, f.scanTriggered);
      }
    } else {
      addOne(res.savedAs, res.size, res.scanTriggered);
    }
  }

  /// A few seconds after a scan-triggered save, ask the server
  /// whether Navidrome has indexed the track yet.
  Future<void> _verifyInLibrary(UrlItem item, UploadResult res) async {
    await Future<void>.delayed(const Duration(seconds: 5));
    if (!mounted) return;
    final title = res.matchedTitle ?? _searchTitle(res.savedAs);
    try {
      final m = await appState.api.inLibrary(title, '');
      if (!mounted) return;
      if (m.found) {
        setState(() => item.libraryNote = 'In your Navidrome library ✓');
      } else if (m.configured) {
        setState(() =>
            item.libraryNote = 'Saved — Navidrome has not indexed it yet');
      }
    } catch (_) {
      // Confirmation is best-effort; the save itself already landed.
    }
  }

  /// "Artist - Title.mp3" → "Artist Title" as a search hint.
  static String _searchTitle(String savedAs) {
    var name = savedAs;
    final dot = name.lastIndexOf('.');
    if (dot > 0) name = name.substring(0, dot);
    return name.replaceAll(' - ', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  Widget _urlRow(BuildContext context, UrlItem item) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final Widget trailing;
    final List<String> lines = [];
    switch (item.status) {
      case UrlStatus.waiting:
        trailing = const Icon(Icons.schedule);
        lines.add('Waiting');
      case UrlStatus.busy:
        trailing = const SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(strokeWidth: 3),
        );
        lines.add('Downloading — the server is fetching this link…');
      case UrlStatus.done:
        trailing = Icon(Icons.check_circle, color: Colors.green, size: 30);
        final res = item.result!;
        lines.add(res.scanTriggered
            ? 'Saved as ${res.savedAs} · library scan started'
            : 'Saved as ${res.savedAs}');
        if (res.alsoSaved > 0) {
          lines.add(res.alsoSaved == 1
              ? '+ 1 more file from this link'
              : '+ ${res.alsoSaved} more files from this link');
        }
        if (res.processingNotes.isNotEmpty) {
          lines.add(res.processingNotes.join(' · '));
        }
        if (item.libraryNote != null) lines.add(item.libraryNote!);
      case UrlStatus.error:
        trailing = Icon(Icons.error, color: scheme.error, size: 30);
        lines.add(item.message ?? 'Download failed');
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 14),
        child: Row(
          children: [
            Icon(Icons.link, size: 30, color: scheme.primary),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.url,
                      style: theme.textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 6),
                  Text(
                    lines.join('\n'),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: item.status == UrlStatus.error
                          ? scheme.error
                          : null,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            trailing,
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final linkCount = parseLinks(_urlCtrl.text).length;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      children: [
        const _SectionHeader('Add from a URL'),
        Text(
          'Paste a link and the server downloads it into your library. '
          'A direct audio link is saved as-is. Google Drive file links '
          'download directly. Spotify track, album and playlist links '
          'are resolved song by song and downloaded with their exact '
          'titles and artists. Links on supported '
          'file hosters are fetched through your TorBox or Premiumize '
          'account when the server has a key for one. Any other page '
          'link — YouTube, SoundCloud and similar — is fetched on the '
          'server with yt-dlp and converted to audio there.',
          style: theme.textTheme.bodyLarge
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 18),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                controller: _urlCtrl,
                style: theme.textTheme.bodyLarge,
                decoration: const InputDecoration(
                  labelText: 'URLs',
                  hintText: 'https://…',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.multiline,
                minLines: 3,
                maxLines: 8,
              ),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: _busy ? null : _paste,
              icon: const Icon(Icons.content_paste),
              label: const Text('Paste'),
              style: OutlinedButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
                textStyle:
                    const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(28)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Text(
          'One link per line. Spotify track, album and playlist links '
          'and YouTube playlists add every song in them (up to 50).',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 18),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: _busy ? null : _submit,
            icon: const Icon(Icons.download),
            label: Text(linkCount > 1
                ? 'Download $linkCount links'
                : 'Download to Navidrome'),
          ),
        ),
        if (_busy) ...[
          const SizedBox(height: 20),
          const LinearProgressIndicator(),
        ],
        if (_items.isNotEmpty) ...[
          const SizedBox(height: 10),
          for (final item in _items) _urlRow(context, item),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// History page: everything this app has uploaded, newest first
// ---------------------------------------------------------------------------

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  // The server's own upload log, fetched once when the page is
  // created and merged into the display in memory (local history
  // storage stays exactly as it was).
  List<HistoryItem> _serverEntries = [];
  bool _retryBusy = false;

  /// Ask the server to fetch just this entry's failed tracks again,
  /// record what landed, and shrink the entry's failed list to
  /// whatever is still missing.
  Future<void> _retryFailed(HistoryItem h) async {
    if (_retryBusy) return;
    setState(() => _retryBusy = true);
    try {
      final res = await appState.api.retryTracks(
        h.failedTracks,
        enrich: appState.enrichURLs,
        lyrics: appState.embedLyrics,
        sort: appState.sortFolders,
      );
      final saved = res.files.isNotEmpty ? res.files : [res];
      for (final f in saved) {
        appState.addHistory(HistoryItem(
          name: f.savedAs.isNotEmpty ? f.savedAs : 'Retried track',
          source: 'URL',
          at: DateTime.now(),
          size: f.size,
          scanTriggered: f.scanTriggered,
          savedAs: f.savedAs,
          folder: f.folder,
          failedTracks: f == saved.first ? res.failedTracks : const [],
          sourceUrl: h.sourceUrl,
        ));
      }
      // The fresh first entry above carries whatever is still
      // failing; this entry's retry offer is spent.
      appState.replaceHistoryFailedTracks(h, const []);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(res.failedTracks.isEmpty
              ? 'All failed tracks downloaded.'
              : '${res.failedTracks.length} track(s) still failing.'),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) setState(() => _retryBusy = false);
    }
  }

  @override
  void initState() {
    super.initState();
    unawaited(_loadServer());
  }

  Future<void> _loadServer() async {
    while (!appState.booted) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (!mounted) return;
    }
    try {
      final entries = await appState.api.fetchRecent();
      if (!mounted) return;
      setState(() => _serverEntries = entries);
    } catch (_) {
      // Server history is a bonus; local history still shows.
    }
  }

  /// Local entries plus server entries that are not already here:
  /// a server entry matching a local one on name + size within
  /// 10 minutes is the same upload seen from both sides.
  List<HistoryItem> get _merged {
    final local = appState.history;
    final merged = [...local];
    for (final s in _serverEntries) {
      final duplicate = local.any((l) =>
          l.name == s.name &&
          l.size == s.size &&
          l.at.difference(s.at).inMinutes.abs() <= 10);
      if (!duplicate) merged.add(s);
    }
    merged.sort((a, b) => b.at.compareTo(a.at));
    return merged;
  }

  Future<void> _confirmClear(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear history?'),
        content: const Text(
            'This only clears the list on this computer — the songs '
            'stay in your Navidrome library.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok == true) {
      appState.clearHistory();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final items = _merged;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      children: [
        Row(
          children: [
            const Expanded(child: _SectionHeader('History')),
            TextButton.icon(
              onPressed:
                  items.isEmpty ? null : () => _confirmClear(context),
              icon: const Icon(Icons.delete_outline),
              label: const Text('Clear all'),
            ),
          ],
        ),
        if (items.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 60),
            child: Column(
              children: [
                Icon(Icons.history, size: 64, color: scheme.onSurfaceVariant),
                const SizedBox(height: 14),
                Text('Nothing uploaded yet',
                    style: theme.textTheme.titleLarge),
                const SizedBox(height: 6),
                Text(
                  'Uploads from this computer will be listed here.',
                  style: theme.textTheme.bodyLarge
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          )
        else
          for (final h in items)
            Card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ListTile(
                leading: Icon(
                  h.source == 'URL' ? Icons.link : Icons.music_note,
                  size: 30,
                  color: scheme.primary,
                ),
                title: Row(
                  children: [
                    Expanded(
                      child: Text(h.name,
                          style: theme.textTheme.titleMedium),
                    ),
                    if (h.fromServer) ...[
                      const SizedBox(width: 10),
                      Chip(
                        label: const Text('Server'),
                        labelStyle: theme.textTheme.bodySmall,
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ],
                ),
                subtitle: Text(
                  [
                    h.source,
                    formatDateTime(h.at),
                    if (h.size > 0) formatBytes(h.size),
                    h.scanTriggered ? 'Scan started' : 'Scan pending',
                    if (h.folder.isNotEmpty) 'Filed under ${h.folder}',
                  ].join(' · '),
                  style: theme.textTheme.bodyMedium,
                ),
                  ),
                  if (h.failedTracks.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 12, 10),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${h.failedTracks.length} track'
                              '${h.failedTracks.length == 1 ? '' : 's'} '
                              "didn't download: "
                              '${h.failedTracks.take(3).join(', ')}'
                              '${h.failedTracks.length > 3 ? '…' : ''}',
                              style: theme.textTheme.bodyMedium
                                  ?.copyWith(color: scheme.error),
                            ),
                          ),
                          TextButton.icon(
                            onPressed:
                                _retryBusy ? null : () => _retryFailed(h),
                            icon: const Icon(Icons.refresh, size: 18),
                            label: Text(_retryBusy ? 'Retrying…' : 'Retry'),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Settings page: server, token, connection test, accent, appearance
// ---------------------------------------------------------------------------

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final TextEditingController _urlCtrl = TextEditingController();
  final TextEditingController _tokenCtrl = TextEditingController();
  final TextEditingController _torboxCtrl = TextEditingController();
  final TextEditingController _premiumizeCtrl = TextEditingController();
  bool _synced = false;
  String? _backupNote;

  /// Write the keys backup JSON (same shape as the iOS app's) to a
  /// file the user picks.
  Future<void> _exportKeys() async {
    final backup = <String, dynamic>{
      'app': 'NaviUpload',
      'version': 1,
      'server': appState.serverUrl,
      'token': appState.token ?? '',
      'torbox_key': appState.torboxKey ?? '',
      'premiumize_key': appState.premiumizeKey ?? '',
    };
    final bytes =
        utf8.encode(const JsonEncoder.withIndent('  ').convert(backup));
    try {
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Save NaviUpload keys backup',
        fileName: 'NaviUpload-Keys.json',
        type: FileType.custom,
        allowedExtensions: const ['json'],
        bytes: bytes,
      );
      if (path == null) return; // user cancelled
      // Some platform versions return a path without writing when
      // bytes are passed — write it ourselves to be sure.
      await File(path).writeAsBytes(bytes, flush: true);
      setState(() => _backupNote = 'Keys exported to $path');
    } catch (e) {
      setState(() => _backupNote = 'Export failed: $e');
    }
  }

  /// Read a keys backup JSON back in and apply what it carries.
  Future<void> _importKeys() async {
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json'],
        withData: true,
      );
      final file = (picked == null || picked.files.isEmpty)
          ? null
          : picked.files.single;
      if (file == null) return; // user cancelled
      var bytes = file.bytes;
      if (bytes == null && file.path != null) {
        bytes = await File(file.path!).readAsBytes();
      }
      if (bytes == null) {
        setState(() => _backupNote = 'Could not read that file.');
        return;
      }
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map || decoded['app'] != 'NaviUpload') {
        setState(() =>
            _backupNote = 'That file is not a NaviUpload keys backup.');
        return;
      }
      String field(String key) => (decoded[key] as String? ?? '').trim();
      if (field('server').isNotEmpty) {
        await appState.setServerUrl(field('server'));
      }
      if (field('token').isNotEmpty) {
        await appState.setToken(field('token'));
      }
      if (field('torbox_key').isNotEmpty) {
        await appState.setTorboxKey(field('torbox_key'));
      }
      if (field('premiumize_key').isNotEmpty) {
        await appState.setPremiumizeKey(field('premiumize_key'));
      }
      await _syncFromState();
      setState(() => _backupNote =
          'Keys imported — use Test connection to confirm.');
    } catch (_) {
      setState(() => _backupNote =
          'Could not read that file — it is not a valid NaviUpload '
          'JSON backup.');
    }
  }

  @override
  void initState() {
    super.initState();
    unawaited(_syncFromState());
  }

  /// The text fields are created before AppState.boot() finishes
  /// loading the saved values, so pull them in once boot lands.
  Future<void> _syncFromState() async {
    while (!appState.booted) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (!mounted || _synced) return;
    _synced = true;
    setState(() {
      _urlCtrl.text = appState.serverUrl;
      _tokenCtrl.text = appState.token ?? '';
      _torboxCtrl.text = appState.torboxKey ?? '';
      _premiumizeCtrl.text = appState.premiumizeKey ?? '';
    });
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _tokenCtrl.dispose();
    _torboxCtrl.dispose();
    _premiumizeCtrl.dispose();
    super.dispose();
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(text)));
  }

  Widget _switchRow(BuildContext context, String label, bool value,
      ValueChanged<bool> onChanged) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(label, style: theme.textTheme.bodyLarge)),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }

  /// "Saved (N characters)" note under a debrid key field, or nothing
  /// when no key is stored.
  Widget _savedLine(BuildContext context, String? key) {
    if (key == null || key.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        'Saved (${key.length} characters)',
        style: theme.textTheme.bodyMedium
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }

  Widget _connectionResult(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (appState.checkingHealth) {
      return const Padding(
        padding: EdgeInsets.only(top: 16),
        child: LinearProgressIndicator(),
      );
    }
    if (appState.lastHealth != null) {
      final h = appState.lastHealth!;
      return Card(
        child: ListTile(
          leading:
              const Icon(Icons.check_circle, color: Colors.green, size: 34),
          title: Text('Connected', style: theme.textTheme.titleMedium),
          subtitle: Text(
            [
              'Library has ${thousands(h.libraryFiles)} songs',
              h.scanConfigured
                  ? 'Instant scan is set up on the server'
                  : 'Instant scan not configured — Navidrome picks '
                      'uploads up on its own scan',
              if (appState.tokenCheck == 'accepted')
                'Token accepted'
              else if (appState.tokenCheck == 'rejected')
                'Token REJECTED — re-paste the server UPLOAD_TOKEN above'
              else if (appState.tokenCheck == 'missing')
                'No token saved yet',
            ].join(' · '),
            style: theme.textTheme.bodyMedium,
          ),
        ),
      );
    }
    if (appState.healthError != null) {
      return Card(
        child: ListTile(
          leading: Icon(Icons.error, color: scheme.error, size: 34),
          title: Text('Could not connect', style: theme.textTheme.titleMedium),
          subtitle: Text(
            appState.healthError!,
            style:
                theme.textTheme.bodyMedium?.copyWith(color: scheme.error),
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      children: [
        const _SectionHeader('Server'),
        TextField(
          controller: _urlCtrl,
          style: theme.textTheme.bodyLarge,
          decoration: const InputDecoration(
            labelText: 'Server address',
            hintText: 'https://upload.07051969.xyz',
            border: OutlineInputBorder(),
          ),
          keyboardType: TextInputType.url,
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonal(
            onPressed: () async {
              await appState.setServerUrl(_urlCtrl.text);
              _urlCtrl.text = appState.serverUrl;
              if (mounted) _snack('Server address saved.');
            },
            child: const Text('Save address'),
          ),
        ),
        const _SectionHeader('Upload token'),
        TextField(
          controller: _tokenCtrl,
          style: theme.textTheme.bodyLarge,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'Token',
            hintText: 'The token printed when the server was installed',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonal(
            onPressed: () async {
              await appState.setToken(_tokenCtrl.text);
              if (mounted) _snack('Token saved on this computer.');
            },
            child: const Text('Save token'),
          ),
        ),
        const _SectionHeader('Debrid services (optional)'),
        Text(
          'Keys are stored in Windows secure storage and sent to your '
          'NaviUpload server with URL downloads. Leave a key blank to '
          'use the key configured on the server itself.',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _torboxCtrl,
          style: theme.textTheme.bodyLarge,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'TorBox API key',
            hintText: 'From torbox.app — Settings, API',
            border: OutlineInputBorder(),
          ),
        ),
        _savedLine(context, appState.torboxKey),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonal(
            onPressed: () async {
              await appState.setTorboxKey(_torboxCtrl.text);
              if (mounted) _snack('TorBox key saved on this computer.');
            },
            child: const Text('Save TorBox key'),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _premiumizeCtrl,
          style: theme.textTheme.bodyLarge,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'Premiumize API key',
            hintText: 'From premiumize.me — Account, API key',
            border: OutlineInputBorder(),
          ),
        ),
        _savedLine(context, appState.premiumizeKey),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonal(
            onPressed: () async {
              await appState.setPremiumizeKey(_premiumizeCtrl.text);
              if (mounted) {
                _snack('Premiumize key saved on this computer.');
              }
            },
            child: const Text('Save Premiumize key'),
          ),
        ),
        const _SectionHeader('Processing'),
        _switchRow(context, 'Clean up metadata — URL downloads',
            appState.enrichURLs, (v) => appState.setEnrichURLs(v)),
        _switchRow(context, 'Clean up metadata — file uploads',
            appState.enrichFiles, (v) => appState.setEnrichFiles(v)),
        _switchRow(context, 'Fetch & embed lyrics', appState.embedLyrics,
            (v) => appState.setEmbedLyrics(v)),
        _switchRow(context, 'File into Artist / Album folders',
            appState.sortFolders, (v) => appState.setSortFolders(v)),
        _switchRow(context, 'Skip songs already in the library',
            appState.skipDuplicates, (v) => appState.setSkipDuplicates(v)),
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(
            'The server identifies each song (iTunes, then MusicBrainz '
            '+ Cover Art Archive) and embeds proper title, artist, '
            'album and cover art into the audio file. Lyrics come from '
            'LRCLIB and are embedded into the file too. File uploads '
            'are left untagged by default — albums usually arrive '
            'already tagged.',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
        const _SectionHeader('Connection'),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: appState.checkingHealth
                ? null
                : () => unawaited(appState.testConnection()),
            icon: const Icon(Icons.network_check),
            label: const Text('Test connection'),
          ),
        ),
        _connectionResult(context),
        const _SectionHeader('Accent color'),
        SizedBox(
          height: 62,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: kAccents.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, i) {
              final a = kAccents[i];
              final selected = i == appState.accentIndex;
              return GestureDetector(
                onTap: () => appState.setAccent(i),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: a.seed,
                        shape: BoxShape.circle,
                        border: selected
                            ? Border.all(color: scheme.onSurface, width: 3)
                            : null,
                      ),
                      child: selected
                          ? const Icon(Icons.check,
                              color: Colors.white, size: 22)
                          : null,
                    ),
                    const SizedBox(height: 3),
                    Text(a.name, style: theme.textTheme.bodySmall),
                  ],
                ),
              );
            },
          ),
        ),
        const _SectionHeader('Library'),
        Card(
          child: ListTile(
            leading: const Icon(Icons.copy_all_outlined),
            title: const Text('Find duplicate songs'),
            subtitle: const Text(
                'Songs that exist more than once, and the space the '
                'extra copies waste. Delete extras from inside the app.'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                  builder: (_) => const DuplicatesPage()),
            ),
          ),
        ),
        const _SectionHeader('Backup'),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.upload_file_outlined),
                title: const Text('Export keys as JSON'),
                subtitle: const Text(
                    'One file with your server, upload token and both '
                    'debrid keys — the same file works in the iOS app.'),
                onTap: _exportKeys,
              ),
              ListTile(
                leading: const Icon(Icons.download_outlined),
                title: const Text('Import keys from JSON'),
                subtitle: const Text(
                    'Fill in whatever a backup file carries; the rest '
                    'stays as-is.'),
                onTap: _importKeys,
              ),
              if (_backupNote != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(_backupNote!,
                        style: theme.textTheme.bodyMedium),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            'The backup file contains your keys — treat it like a '
            'password.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
        const _SectionHeader('Appearance'),
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(
              value: 0,
              icon: Icon(Icons.brightness_auto),
              label: Text('System'),
            ),
            ButtonSegment(
              value: 1,
              icon: Icon(Icons.light_mode),
              label: Text('Light'),
            ),
            ButtonSegment(
              value: 2,
              icon: Icon(Icons.dark_mode),
              label: Text('Dark'),
            ),
          ],
          selected: {appState.appearanceMode},
          onSelectionChanged: (s) => appState.setAppearance(s.first),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            'System follows your Windows Light / Dark setting; Light '
            'and Dark lock the app to that look.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
        const _SectionHeader('About'),
        Card(
          child: ListTile(
            leading: const AppIconBadge(size: 40),
            title:
                Text('NaviUpload $kAppVersion', style: theme.textTheme.titleMedium),
            subtitle: Text(
              'Upload music to your Navidrome library from files or '
              'URLs.',
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Duplicate finder page: songs that exist more than once in the
// library (server GET /duplicates), with per-copy delete (POST
// /delete). The biggest copy of each song is marked as the keeper;
// deleting is always confirmed first.
// ---------------------------------------------------------------------------

class DuplicatesPage extends StatefulWidget {
  const DuplicatesPage({super.key});

  @override
  State<DuplicatesPage> createState() => _DuplicatesPageState();
}

class _DuplicatesPageState extends State<DuplicatesPage> {
  DuplicatesResult? _result;
  bool _loading = true;
  bool _deleting = false;
  String? _error;
  String? _note;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await appState.api.fetchDuplicates();
      if (mounted) {
        setState(() {
          _result = r;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  Future<void> _confirmDelete(List<DuplicateFileInfo> files) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(files.length == 1
            ? 'Delete this copy?'
            : 'Delete ${files.length} copies?'),
        content: const Text(
            'This removes the file from your server for good. The '
            'biggest copy of each song is kept.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _deleting = true);
    try {
      final res =
          await appState.api.deleteFiles([for (final f in files) f.file]);
      _note = res.errorCount == 0
          ? 'Deleted ${res.deleted.length} file(s).'
          : 'Deleted ${res.deleted.length}; ${res.errorCount} could '
              'not be deleted.';
      await _load();
    } catch (e) {
      _note = e.toString();
    }
    if (mounted) setState(() => _deleting = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Duplicate songs')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Could not scan the library',
                          style: theme.textTheme.titleLarge),
                      const SizedBox(height: 8),
                      Text(_error!,
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: scheme.error)),
                      const SizedBox(height: 16),
                      FilledButton.tonal(
                          onPressed: _load, child: const Text('Retry')),
                    ],
                  ),
                )
              : _result == null || _result!.groups.isEmpty
                  ? Center(
                      child: Text(
                        'No duplicates — every song in your library '
                        'exists exactly once.',
                        style: theme.textTheme.titleMedium,
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                      children: [
                        Text(
                          '${_result!.groupCount} songs are duplicated '
                          '(${_result!.fileCount} files) · '
                          '${formatBytes(_result!.wastedBytes)} wasted',
                          style: theme.textTheme.bodyLarge?.copyWith(
                              color: scheme.onSurfaceVariant),
                        ),
                        if (_note != null) ...[
                          const SizedBox(height: 8),
                          Text(_note!, style: theme.textTheme.bodyMedium),
                        ],
                        const SizedBox(height: 12),
                        for (final g in _result!.groups)
                          Card(
                            margin: const EdgeInsets.only(bottom: 12),
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(
                                  16, 12, 16, 8),
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    g.artist.isEmpty
                                        ? g.title
                                        : '${g.artist} — ${g.title}',
                                    style: theme.textTheme.titleMedium,
                                  ),
                                  const SizedBox(height: 6),
                                  for (var i = 0; i < g.files.length; i++)
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            '${g.files[i].file}  ·  '
                                            '${formatBytes(g.files[i].size)}',
                                            style:
                                                theme.textTheme.bodyMedium,
                                          ),
                                        ),
                                        if (i == 0)
                                          Text(
                                            'Keep',
                                            style: theme
                                                .textTheme.bodyMedium
                                                ?.copyWith(
                                                    color: Colors.green,
                                                    fontWeight:
                                                        FontWeight.bold),
                                          )
                                        else
                                          TextButton(
                                            onPressed: _deleting
                                                ? null
                                                : () => _confirmDelete(
                                                    [g.files[i]]),
                                            child: const Text('Delete'),
                                          ),
                                      ],
                                    ),
                                  if (g.files.length > 2)
                                    Align(
                                      alignment: Alignment.centerRight,
                                      child: TextButton.icon(
                                        onPressed: _deleting
                                            ? null
                                            : () => _confirmDelete(
                                                g.files.sublist(1)),
                                        icon: const Icon(
                                            Icons.delete_sweep_outlined,
                                            size: 18),
                                        label: const Text(
                                            'Delete extra copies'),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
    );
  }
}
