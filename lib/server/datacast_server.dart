import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mime/mime.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

import '../models/device_identity.dart';
import '../models/peer_device.dart';
import '../services/file_source.dart';
import 'path_utils.dart';
import 'pin_auth.dart';
import 'zip_stream.dart';

/// Loads a static web asset (relative path like `index.html`), or null.
typedef AssetLoader = Future<List<int>?> Function(String path);

const _cookieName = 'dc_token';
const apiVersion = 1;

/// The HTTP server each device runs.
///
/// Serves the web UI from [assets] at `/` and the JSON API under `/api`.
/// See `docs/API.md` for the contract.
class DataCastServer {
  DataCastServer({
    required this.auth,
    required this.identity,
    required this.source,
    required this.peers,
    required this.assets,
    bool Function()? allowZip,
  }) : allowZip = allowZip ?? (() => false);

  final PinAuth auth;

  /// Current identity (read on every request so renames apply immediately).
  final DeviceIdentity Function() identity;

  /// Current shared folder, or null when nothing is shared.
  final FileSource? Function() source;

  /// Other DataCast devices discovered on the network (excluding this one).
  final List<PeerDevice> Function() peers;
  final AssetLoader assets;

  /// Whether visitors may download whole folders as ZIP.
  final bool Function() allowZip;

  HttpServer? _server;
  String? _localIp;

  int? get port => _server?.port;
  bool get isRunning => _server != null;

  /// Starts listening on all IPv4 interfaces. Tries [preferredPort] and the
  /// next few ports, then falls back to any free port. Returns the port.
  Future<int> start({
    int preferredPort = 8080,
    String? localIp,
    InternetAddress? address,
  }) async {
    if (_server != null) return _server!.port;
    _localIp = localIp;
    final bindAddress = address ?? InternetAddress.anyIPv4;
    Object? lastError;
    for (final p in [for (var i = 0; i < 10; i++) preferredPort + i, 0]) {
      try {
        _server = await shelf_io.serve(handler, bindAddress, p);
        _server!.autoCompress = false;
        return _server!.port;
      } on SocketException catch (e) {
        lastError = e;
      }
    }
    throw StateError('Could not bind server: $lastError');
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    await s?.close(force: true);
  }

  /// Update the IP advertised in `/api/devices` (e.g. after a Wi-Fi change).
  set localIp(String? ip) => _localIp = ip;

  late final Handler handler = const Pipeline()
      .addMiddleware(_errors)
      .addMiddleware(_securityHeaders)
      .addHandler(_router.call);

  late final Router _router = Router(notFoundHandler: _static)
    ..get('/api/info', _info)
    ..get('/api/devices', _devices)
    ..post('/api/auth', _authenticate)
    ..post('/api/logout', _logout)
    ..get('/api/files', _guard(_files))
    ..get('/api/download', _guard((r) => _sendFile(r, attachment: true)))
    ..head('/api/download', _guard((r) => _sendFile(r, attachment: true)))
    ..get('/api/raw', _guard((r) => _sendFile(r, attachment: false)))
    ..head('/api/raw', _guard((r) => _sendFile(r, attachment: false)))
    ..get('/api/zip', _guard(_zip))
    ..all('/api/<ignored|.*>', (Request r) => _json({'error': 'Unknown endpoint'}, 404));

  // ---------------------------------------------------------------- middleware

  Middleware get _errors => (inner) => (request) async {
        try {
          return await inner(request);
        } on InvalidPathException {
          return _json({'error': 'Invalid path'}, 400);
        } on FileNotFound {
          return _json({'error': 'Not found'}, 404);
        }
      };

  Middleware get _securityHeaders => (inner) => (request) async {
        final res = await inner(request);
        return res.change(headers: {
          'x-content-type-options': 'nosniff',
          'referrer-policy': 'no-referrer',
          'x-frame-options': 'SAMEORIGIN',
        });
      };

  Handler _guard(FutureOr<Response> Function(Request) h) => (request) {
        if (!auth.validate(_token(request))) {
          return _json({'error': 'PIN required'}, 401);
        }
        if (source() == null) {
          return _json({'error': 'No folder is being shared'}, 503);
        }
        return h(request);
      };

  // ------------------------------------------------------------------ handlers

  Response _info(Request r) {
    final id = identity();
    return _json({
      'name': id.name,
      'deviceId': id.deviceId,
      'platform': id.platform,
      'requiresPin': true,
      'authenticated': auth.validate(_token(r)),
      'sharing': source() != null,
      'folderName': source()?.displayName,
      'allowZip': allowZip(),
      'apiVersion': apiVersion,
    });
  }

  Response _devices(Request r) {
    final id = identity();
    final selfIp = _localIp ?? _hostOf(r);
    final list = <PeerDevice>[
      PeerDevice(
        deviceId: id.deviceId,
        name: id.name,
        ip: selfIp,
        port: port ?? 0,
        platform: id.platform,
        self: true,
      ),
      ...peers().where((p) => p.deviceId != id.deviceId),
    ];
    return _jsonList([for (final d in list) d.toJson()]);
  }

  Future<Response> _authenticate(Request r) async {
    String? pin;
    try {
      final body = await r.readAsString();
      if (body.isNotEmpty) {
        final ct = r.headers['content-type'] ?? '';
        if (ct.contains('application/x-www-form-urlencoded')) {
          pin = Uri.splitQueryString(body)['pin'];
        } else {
          final decoded = jsonDecode(body);
          if (decoded is Map) pin = decoded['pin']?.toString();
        }
      }
    } on FormatException {
      return _json({'error': 'Invalid request body'}, 400);
    }
    final result = auth.attempt(_clientKey(r), pin?.trim());
    switch (result) {
      case AuthGranted(:final token):
        return _json({'token': token}, 200, {
          'set-cookie': '$_cookieName=$token; Path=/; HttpOnly; SameSite=Strict',
        });
      case AuthDenied(:final attemptsLeft):
        return _json({'error': 'Wrong PIN', 'attemptsLeft': attemptsLeft}, 401);
      case AuthLocked(:final retryAfter):
        final secs = (retryAfter.inMilliseconds / 1000).ceil();
        return _json(
          {'error': 'Too many attempts. Try again later.', 'retryAfterSec': secs},
          429,
          {'retry-after': '$secs'},
        );
    }
  }

  Response _logout(Request r) => _json({'ok': true}, 200, {
        'set-cookie': '$_cookieName=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict',
      });

  Future<Response> _files(Request r) async {
    final path = normalizeSharePath(r.url.queryParameters['path']);
    final src = source()!;
    final entry = await src.stat(path);
    if (entry == null) throw FileNotFound(path);
    if (!entry.isDir) return _json({'error': 'Not a folder'}, 400);
    final entries = await src.list(path);
    entries.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return _json({
      'path': path,
      'name': path == '/' ? src.displayName : baseName(path),
      'entries': [for (final e in entries) e.toJson()],
    });
  }

  Future<Response> _sendFile(Request r, {required bool attachment}) async {
    final path = normalizeSharePath(r.url.queryParameters['path']);
    if (path == '/') return _json({'error': 'Not a file'}, 400);
    final src = source()!;
    final entry = await src.stat(path);
    if (entry == null) throw FileNotFound(path);
    if (entry.isDir) return _json({'error': 'Not a file'}, 400);

    final size = entry.size;
    final mime = entry.mime ?? lookupMimeType(entry.name) ?? 'application/octet-stream';
    final headers = <String, String>{
      'content-type': mime,
      'accept-ranges': 'bytes',
      'cache-control': 'private, no-cache',
      'content-disposition': _disposition(entry.name, attachment),
      if (entry.modified != null) 'last-modified': HttpDate.format(entry.modified!.toUtc()),
    };

    final range = parseRange(r.headers['range'], size);
    if (range == RangeResult.unsatisfiable) {
      return Response(416, headers: {...headers, 'content-range': 'bytes */$size'});
    }
    final isHead = r.method == 'HEAD';
    if (range != null) {
      final len = range.end - range.start + 1;
      return Response(
        206,
        body: isHead ? null : src.read(path, start: range.start, end: range.end),
        headers: {
          ...headers,
          'content-length': '$len',
          'content-range': 'bytes ${range.start}-${range.end}/$size',
        },
      );
    }
    return Response.ok(
      isHead || size == 0 ? null : src.read(path),
      headers: {...headers, 'content-length': '$size'},
    );
  }

  Future<Response> _zip(Request r) async {
    if (!allowZip()) return _json({'error': 'Folder download is turned off'}, 403);
    final path = normalizeSharePath(r.url.queryParameters['path']);
    final src = source()!;
    final entry = await src.stat(path);
    if (entry == null) throw FileNotFound(path);
    if (!entry.isDir) return _json({'error': 'Not a folder'}, 400);
    final name = '${path == '/' ? src.displayName : baseName(path)}.zip';
    return Response.ok(zipFolder(src, path), headers: {
      'content-type': 'application/zip',
      'content-disposition': _disposition(name, true),
      'cache-control': 'no-store',
    });
  }

  Future<Response> _static(Request r) async {
    if (r.method != 'GET' && r.method != 'HEAD') {
      return Response.notFound('Not found');
    }
    String rel;
    try {
      rel = normalizeSharePath(Uri.decodeComponent(r.url.path)).substring(1);
    } on Object {
      return Response.notFound('Not found');
    }
    if (rel.isEmpty) rel = 'index.html';
    var bytes = await assets(rel);
    // Single-page-app fallback: extension-less paths serve index.html.
    if (bytes == null && !baseName('/$rel').contains('.')) {
      rel = 'index.html';
      bytes = await assets(rel);
    }
    if (bytes == null) return Response.notFound('Not found');
    return Response.ok(
      r.method == 'HEAD' ? null : bytes,
      headers: {
        'content-type': lookupMimeType(rel) ?? 'application/octet-stream',
        'content-length': '${bytes.length}',
        'cache-control': 'no-cache',
      },
    );
  }

  // ------------------------------------------------------------------- helpers

  String? _token(Request r) {
    final authz = r.headers['authorization'];
    if (authz != null && authz.toLowerCase().startsWith('bearer ')) {
      return authz.substring(7).trim();
    }
    final cookie = r.headers['cookie'];
    if (cookie == null) return null;
    for (final part in cookie.split(';')) {
      final i = part.indexOf('=');
      if (i > 0 && part.substring(0, i).trim() == _cookieName) {
        return part.substring(i + 1).trim();
      }
    }
    return null;
  }

  String _clientKey(Request r) {
    final info = r.context['shelf.io.connection_info'];
    if (info is HttpConnectionInfo) return info.remoteAddress.address;
    return 'unknown';
  }

  String _hostOf(Request r) => r.requestedUri.host;

  static String _disposition(String name, bool attachment) {
    final type = attachment ? 'attachment' : 'inline';
    final ascii = name.replaceAll(RegExp(r'[^\x20-\x7E]|["\\]'), '_');
    return '$type; filename="$ascii"; filename*=UTF-8\'\'${Uri.encodeComponent(name)}';
  }

  static Response _json(Object body, [int status = 200, Map<String, String>? extraHeaders]) =>
      Response(
        status,
        body: jsonEncode(body),
        headers: {
          'content-type': 'application/json; charset=utf-8',
          'cache-control': 'no-store',
          ...?extraHeaders,
        },
      );

  static Response _jsonList(List<Object?> body) => _json(body);
}

/// A byte range, both ends inclusive.
class ByteRange {
  const ByteRange(this.start, this.end);
  final int start;
  final int end;
  @override
  bool operator ==(Object other) =>
      other is ByteRange && other.start == start && other.end == end;
  @override
  int get hashCode => Object.hash(start, end);
}

abstract final class RangeResult {
  static const unsatisfiable = ByteRange(-1, -1);
}

/// Parses a single `Range: bytes=...` header. Returns null for "send the whole
/// file" (no header, or a form we do not support such as multiple ranges),
/// [RangeResult.unsatisfiable] for an out-of-bounds range.
ByteRange? parseRange(String? header, int size) {
  if (header == null) return null;
  final m = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(header.trim());
  if (m == null) return null;
  final a = m.group(1)!, b = m.group(2)!;
  if (a.isEmpty && b.isEmpty) return null;
  int start, end;
  if (a.isEmpty) {
    final suffix = int.parse(b);
    if (suffix == 0) return RangeResult.unsatisfiable;
    start = size - suffix < 0 ? 0 : size - suffix;
    end = size - 1;
  } else {
    start = int.parse(a);
    end = b.isEmpty ? size - 1 : int.parse(b);
    if (end >= size) end = size - 1;
  }
  if (size == 0 || start >= size || start > end) return RangeResult.unsatisfiable;
  return ByteRange(start, end);
}
