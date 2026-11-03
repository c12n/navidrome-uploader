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
  const UploadResult({
    required this.savedAs,
    required this.size,
    required this.scanTriggered,
  });
}

class HistoryItem {
  final String name;
  final String source; // 'File' or 'URL'
  final DateTime at;
  final int size;
  final bool scanTriggered;
  final String savedAs;

  const HistoryItem({
    required this.name,
    required this.source,
    required this.at,
    required this.size,
    required this.scanTriggered,
    required this.savedAs,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'source': source,
        'at': at.toIso8601String(),
        'size': size,
        'scanTriggered': scanTriggered,
        'savedAs': savedAs,
      };

  factory HistoryItem.fromJson(Map<String, dynamic> j) => HistoryItem(
        name: j['name'] as String? ?? '',
        source: j['source'] as String? ?? 'File',
        at: DateTime.tryParse(j['at'] as String? ?? '') ?? DateTime.now(),
        size: (j['size'] as num?)?.toInt() ?? 0,
        scanTriggered: j['scanTriggered'] as bool? ?? false,
        savedAs: j['savedAs'] as String? ?? (j['name'] as String? ?? ''),
      );
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

  int accentIndex = 0;
  int appearanceMode = 2; // 0 system, 1 light, 2 dark (default dark)

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

  Future<void> boot() async {
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;
    serverUrl =
        prefs.getString('naviupload_server_url') ?? serverUrl;
    accentIndex = prefs.getInt('naviupload_accent') ?? 0;
    appearanceMode = prefs.getInt('naviupload_appearance') ?? 2;
    token = await _secure.read(key: 'upload_token');
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

  Future<void> testConnection() async {
    if (checkingHealth) return;
    checkingHealth = true;
    notifyListeners();
    try {
      final h = await api.health();
      lastHealth = h;
      healthError = null;
      lastHealthAt = DateTime.now();
    } catch (e) {
      lastHealth = null;
      healthError = e.toString();
      lastHealthAt = DateTime.now();
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
      if (decoded is Map) {
        return UploadResult(
          savedAs: (decoded['saved_as'] ?? decoded['savedAs'] ?? '')
              .toString(),
          size: (decoded['size'] as num?)?.toInt() ?? 0,
          scanTriggered: decoded['scan_triggered'] == true ||
              decoded['scanTriggered'] == true,
        );
      }
    } catch (_) {
      // Fall through to the generic-but-honest error below.
    }
    throw const ApiException('The server answered with an unreadable reply.');
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
    final header = utf8.encode('--$boundary\r\n'
        'Content-Disposition: form-data; name="file"; filename="$safeName"\r\n'
        'Content-Type: application/octet-stream\r\n\r\n');
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

  Future<UploadResult> uploadUrl(String url) async {
    final http.Response r;
    try {
      r = await http.post(
        _uri('/url'),
        headers: {
          'Content-Type': 'application/json',
          ..._authHeaders,
        },
        body: jsonEncode({'url': url}),
      );
    } catch (e) {
      throw ApiException('Could not reach the server: $e');
    }
    return _parseUpload(r);
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

enum QueueStatus { queued, uploading, done, error }

class QueueItem {
  final String name;
  final String path;
  final int size;
  double progress = 0;
  QueueStatus status = QueueStatus.queued;
  String? savedAs;
  bool scanTriggered = false;
  String? message;

  QueueItem({required this.name, required this.path, required this.size});
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
    unawaited(_processQueue());
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
    unawaited(_processQueue());
  }

  Future<void> _processQueue() async {
    if (_processing) return;
    _processing = true;
    try {
      while (true) {
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
            });
          }
          appState.addHistory(HistoryItem(
            name: res.savedAs.isNotEmpty ? res.savedAs : item.name,
            source: 'File',
            at: DateTime.now(),
            size: res.size > 0 ? res.size : item.size,
            scanTriggered: res.scanTriggered,
            savedAs: res.savedAs,
          ));
        } catch (e) {
          if (mounted) {
            setState(() {
              item.status = QueueStatus.error;
              item.message = e.toString();
            });
          }
        }
      }
    } finally {
      _processing = false;
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
        bottom = Text('Queued', style: theme.textTheme.bodyMedium);
      case QueueStatus.uploading:
        trailing = Text('${(item.progress * 100).round()}%',
            style: theme.textTheme.titleMedium);
        bottom = LinearProgressIndicator(value: item.progress);
      case QueueStatus.done:
        trailing = Icon(Icons.check_circle, color: Colors.green, size: 30);
        bottom = Text(
          item.scanTriggered
              ? 'Saved as ${item.savedAs} · library scan started'
              : 'Saved as ${item.savedAs}',
          style: theme.textTheme.bodyMedium,
        );
      case QueueStatus.error:
        trailing = Icon(Icons.error, color: scheme.error, size: 30);
        bottom = Text(
          item.message ?? 'Upload failed',
          style:
              theme.textTheme.bodyMedium?.copyWith(color: scheme.error),
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      children: [
        const _SectionHeader('Upload files'),
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
          for (final item in _queue) _queueRow(context, item),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: _processing
                  ? null
                  : () => setState(() {
                        _queue.removeWhere(
                            (q) => q.status != QueueStatus.uploading);
                      }),
              child: const Text('Clear finished'),
            ),
          ),
        ] else ...[
          const SizedBox(height: 28),
          Center(
            child: Text(
              'Files you add upload one at a time, straight into the '
              'Navidrome library folder.',
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
  bool _busy = false;
  UploadResult? _result;
  String? _error;

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) return;
    setState(() {
      _urlCtrl.text = text;
      _result = null;
      _error = null;
    });
  }

  Future<void> _submit() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _result = null;
      _error = null;
    });
    try {
      final res = await appState.api.uploadUrl(url);
      if (!mounted) return;
      setState(() {
        _result = res;
        _busy = false;
      });
      appState.addHistory(HistoryItem(
        name: res.savedAs.isNotEmpty ? res.savedAs : url,
        source: 'URL',
        at: DateTime.now(),
        size: res.size,
        scanTriggered: res.scanTriggered,
        savedAs: res.savedAs,
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      children: [
        const _SectionHeader('Add from a URL'),
        Text(
          'Paste a link and the server downloads it into your library. '
          'A direct audio link is saved as-is; a page link — YouTube, '
          'SoundCloud and similar — is fetched on the server with '
          'yt-dlp and converted to audio there.',
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
                  labelText: 'URL',
                  hintText: 'https://…',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.url,
                onSubmitted: (_) => unawaited(_submit()),
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
        const SizedBox(height: 18),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: _busy ? null : _submit,
            icon: const Icon(Icons.download),
            label: const Text('Download to Navidrome'),
          ),
        ),
        if (_busy) ...[
          const SizedBox(height: 26),
          const LinearProgressIndicator(),
          const SizedBox(height: 10),
          Text(
            'The server is fetching that link — page links can take a '
            'little while.',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
        if (_result != null) ...[
          const SizedBox(height: 26),
          Card(
            child: ListTile(
              leading:
                  const Icon(Icons.check_circle, color: Colors.green, size: 34),
              title: Text('Saved as ${_result!.savedAs}',
                  style: theme.textTheme.titleMedium),
              subtitle: Text(
                [
                  if (_result!.size > 0) formatBytes(_result!.size),
                  if (_result!.scanTriggered) 'Library scan started',
                ].join(' · '),
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 26),
          Card(
            child: ListTile(
              leading: Icon(Icons.error, color: scheme.error, size: 34),
              title:
                  Text('Download failed', style: theme.textTheme.titleMedium),
              subtitle: Text(
                _error!,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: scheme.error),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// History page: everything this app has uploaded, newest first
// ---------------------------------------------------------------------------

class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key});

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
    final items = appState.history;
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
              child: ListTile(
                leading: Icon(
                  h.source == 'URL' ? Icons.link : Icons.music_note,
                  size: 30,
                  color: scheme.primary,
                ),
                title: Text(h.name, style: theme.textTheme.titleMedium),
                subtitle: Text(
                  [
                    h.source,
                    formatDateTime(h.at),
                    if (h.size > 0) formatBytes(h.size),
                    h.scanTriggered ? 'Scan started' : 'Scan pending',
                  ].join(' · '),
                  style: theme.textTheme.bodyMedium,
                ),
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
  bool _synced = false;

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
    });
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _tokenCtrl.dispose();
    super.dispose();
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(text)));
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
            title: Text('NaviUpload 1.0.0', style: theme.textTheme.titleMedium),
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
