// lib/server.dart
// import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

/// Represents a single shared file.
class SharedEntry {
  SharedEntry(this.file);

  final File file;

  String get name => p.basename(file.path);
  Future<int> get size async => (await file.stat()).size;
  Future<DateTime> get lastModified async => (await file.stat()).modified;
}

/// HTTP file sharing server manager.
/// - Serves an index page with download links.
/// - Streams downloads.
/// - (Optional) Accepts uploads to a chosen directory.
class ServerManager {
  HttpServer? _server;
  final List<SharedEntry> _shared = <SharedEntry>[];
  Directory? _uploadDir;

  /// Whether the underlying HttpServer is running.
  bool get isRunning => _server != null;

  /// Bound port (null if not running).
  int? get port => _server?.port;

  /// Bound address (null if not running).
  InternetAddress? get address => _server?.address;

  /// Convenience base URL (null if not running).
  Uri? get baseUrl => isRunning
      ? Uri(scheme: 'http', host: address!.address, port: port)
      : null;

  /// Read-only view of shared files.
  List<SharedEntry> get shared => List.unmodifiable(_shared);

  /// Replace the list of shared files.
  Future<void> setSharedFiles(List<File> files) async {
    _shared
      ..clear()
      ..addAll(files.map(SharedEntry.new));
  }

  /// Choose the directory for uploads; pass null to disable uploading.
  void setUploadDir(String? dirPath) {
    _uploadDir = dirPath == null ? null : Directory(dirPath);
  }

  /// Start the server. If already running, returns the existing port.
  ///
  /// [bindAddress] defaults to any IPv4 so other devices on LAN can reach it.
  /// Use [InternetAddress.loopbackIPv4] if you only want local machine access.
  ///
  /// [port] 0 lets the OS pick a free port.
  ///
  /// [enableCors] to allow cross-origin (useful if you consume JSON/REST from other apps).
  ///
  /// [logRequestsToConsole] enables shelf's built-in request logging.
  Future<int> start({
    int port = 0,
    required InternetAddress bindAddress,
    bool enableCors = false,
    bool logRequestsToConsole = true,
  }) async {
    if (isRunning) return _server!.port;

    final Router router = Router()
      ..get('/', _handleIndex)
      ..get('/files', _handleListJson)
      ..get('/download/<idx|[0-9]+>', _handleDownload)
      ..head('/download/<idx|[0-9]+>', _handleHeadDownload)
      ..post('/upload', _handleUpload)
      ..get('/_health', (Request req) => Response.ok('ok'));

    // Compose middlewares
    Handler handler =
        const Pipeline().addMiddleware(_securityHeaders()).addHandler(router);

    if (logRequestsToConsole) {
      handler =
          const Pipeline().addMiddleware(logRequests()).addHandler(handler);
    }
    if (enableCors) {
      handler = const Pipeline().addMiddleware(_cors()).addHandler(handler);
    }

    // Bind and serve
    _server = await shelf_io.serve(
      handler,
      bindAddress,
      port,
      shared: false,
    );

    return _server!.port;
  }

  /// Stop the server if running.
  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  // =========================
  //        Handlers
  // =========================

  Future<Response> _handleIndex(Request req) async {
    final StringBuffer listItems = StringBuffer();
    for (int i = 0; i < _shared.length; i++) {
      final e = _shared[i];
      final size = await e.size;
      // ✅ Proper clickable link with escaped text label
      listItems.writeln(
        '<li><a href="/download/$i">${_htmlEscape(e.name)}</a> '
        '(${_formatBytes(size)})</li>',
      );
    }

    final uploadSection = _uploadDir == null
        ? '<p>Uploads are disabled (no upload folder selected).</p>'
        : '''
<h3>Upload a file</h3>
<input id="fileInput" type="file"/>
<button onclick="upload()">Upload</button>
<p id="status"></p>
<script>
async function upload() {
  const f = document.getElementById('fileInput').files[0];
  if (!f) { alert('Pick a file first'); return; }
  const buf = await f.arrayBuffer();
  const resp = await fetch('/upload', {
    method: 'POST',
    headers: {'x-filename': encodeURIComponent(f.name)},
    body: buf
  });
  document.getElementById('status').innerText = await resp.text();
}
</script>
''';

    final html = '''
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>Local Share</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <style>
    body{font-family:-apple-system,system-ui,Segoe UI,Roboto,Helvetica,Arial,sans-serif;margin:24px;line-height:1.45}
    ul{padding-left:20px}
    a{color:#0b57d0;text-decoration:none}
    a:hover{text-decoration:underline}
    code,pre{background:#f5f5f7;padding:2px 4px;border-radius:4px}
  </style>
</head>
<body>
  <h2>Shared Files</h2>
  <ul>
    ${listItems.isEmpty ? '<li><em>No files shared.</em></li>' : listItems}
  </ul>
  $uploadSection
  <hr/>
  <small>Served by Local Share on ${_htmlEscape(Platform.localHostname)}</small>
</body>
</html>
''';

    return Response.ok(
      html,
      headers: {'content-type': 'text/html; charset=utf-8'},
    );
  }

  Future<Response> _handleListJson(Request req) async {
    final files = <Map<String, Object>>[];
    for (final e in _shared) {
      files.add({
        'name': e.name,
        'size': await e.size,
      });
    }
    return Response.ok(
      jsonEncode(files),
      headers: {'content-type': 'application/json'},
    );
  }

  Future<Response> _handleHeadDownload(Request req, String idx) async {
    final i = int.tryParse(idx);
    if (i == null || i < 0 || i >= _shared.length) {
      return Response.notFound('No such file');
    }
    final e = _shared[i];
    if (!await e.file.exists()) return Response.notFound('File missing');
    final st = await e.file.stat();
    final mime = lookupMimeType(e.file.path) ?? 'application/octet-stream';
    final headers = _downloadHeaders(e.name, mime, st.size, st.modified);
    return Response.ok('', headers: headers);
  }

  Future<Response> _handleDownload(Request req, String idx) async {
    final i = int.tryParse(idx);
    if (i == null || i < 0 || i >= _shared.length) {
      return Response.notFound('No such file');
    }
    final e = _shared[i];
    if (!await e.file.exists()) return Response.notFound('File missing');

    final st = await e.file.stat();

    // --- MIME: force correct type for Android APKs, else detect ---
    String mime = lookupMimeType(e.file.path) ?? 'application/octet-stream';
    final ext = p.extension(e.file.path).toLowerCase();
    if (ext == '.apk') {
      mime = 'application/vnd.android.package-archive';
    }

    final headers = _downloadHeaders(e.name, mime, st.size, st.modified);

    // Stream with error handling (so the connection doesn't hang silently)
    final stream = e.file.openRead().handleError((e, st) {
      // Will be logged by Shelf's zone if logRequests() is enabled.
    });

    return Response.ok(stream, headers: headers);
  }

  /// Upload endpoint expects:
  /// - Raw body with `x-filename` header (as used by our index page JS).
  /// - For multipart: deliberately not supported to keep server minimal.
  Future<Response> _handleUpload(Request req) async {
    if (_uploadDir == null) {
      return Response.forbidden('Uploads are disabled.');
    }

    final encName = req.headers['x-filename'];
    if (encName == null || encName.isEmpty) {
      return Response(400, body: 'Missing x-filename header');
    }

    // Read body into memory (fine for modest file sizes).
    final bytes =
        await req.read().fold<List<int>>(<int>[], (a, b) => a..addAll(b));

    final fileName = Uri.decodeComponent(encName);
    final sanitized = _sanitizeFileName(fileName);
    final dir = _uploadDir!;
    if (!await dir.exists()) await dir.create(recursive: true);

    File out = File(p.join(dir.path, sanitized));
    out = await _uniqueFile(out);

    await out.writeAsBytes(bytes, flush: true);
    return Response.ok('Uploaded as ${p.basename(out.path)}');
  }

  // =========================
  //          Utils
  // =========================

  static Map<String, String> _downloadHeaders(
    String filename,
    String mime,
    int size,
    DateTime lastModified,
  ) {
    // RFC 6266/5987-style disposition (fallback filename + UTF-8 filename*)
    final safe = filename.replaceAll('"', '\\"');
    final enc = Uri.encodeQueryComponent(filename);
    return <String, String>{
      'content-type': mime,
      'content-length': size.toString(),
      'last-modified': HttpDate.format(lastModified.toUtc()),
      'content-disposition':
          'attachment; filename="$safe"; filename*=UTF-8\'\'$enc',
      'accept-ranges': 'none', // change to 'bytes' if you add Range support
      // 'cache-control': 'no-store', // optional
    };
  }

  static String _htmlEscape(String s) {
    return s
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
  }

  static String _formatBytes(int bytes, [int decimals = 1]) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    final i =
        (math.log(bytes) / math.log(1024)).floor().clamp(0, units.length - 1);
    final v = bytes / math.pow(1024, i);
    return '${v.toStringAsFixed(decimals)} ${units[i]}';
  }

  static Middleware _securityHeaders() {
    return (Handler inner) {
      return (Request req) async {
        final resp = await inner(req);
        return resp.change(headers: {
          ...resp.headers,
          'x-content-type-options': 'nosniff',
          'x-frame-options': 'DENY',
          'x-xss-protection': '0',
        });
      };
    };
  }

  static Middleware _cors() {
    const allowHeaders = 'origin, content-type, accept, x-filename';
    const allowMethods = 'GET, POST, HEAD, OPTIONS';
    return (Handler inner) {
      return (Request req) async {
        if (req.method == 'OPTIONS') {
          return Response.ok('', headers: {
            'access-control-allow-origin': '*',
            'access-control-allow-headers': allowHeaders,
            'access-control-allow-methods': allowMethods,
          });
        }
        final resp = await inner(req);
        return resp.change(headers: {
          ...resp.headers,
          'access-control-allow-origin': '*',
        });
      };
    };
  }
}

// ===== filename utilities =====

String _sanitizeFileName(String name) {
  // Remove path separators and control chars; trim spaces.
  var s = name
      .replaceAll(RegExp(r'[\/\\]+'), '_')
      .replaceAll(RegExp(r'[\x00-\x1F]'), '')
      .trim();
  // Avoid special edge cases
  if (s.isEmpty || s == '.' || s == '..') s = 'upload';
  return s;
}

Future<File> _uniqueFile(File f) async {
  if (!await f.exists()) return f;
  final dir = p.dirname(f.path);
  final base = p.basenameWithoutExtension(f.path);
  final ext = p.extension(f.path);
  int i = 1;
  while (await File(p.join(dir, '$base ($i)$ext')).exists()) {
    i++;
  }
  return File(p.join(dir, '$base ($i)$ext'));
}
