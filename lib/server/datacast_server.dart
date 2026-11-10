import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

/// Largest body accepted by `POST /api/auth`.
const maxAuthBody = 4096;

/// CSP for the web UI and API responses.
const pageCsp =
    "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; "
    "img-src 'self' data: blob:; media-src 'self' blob:; connect-src 'self'; frame-src 'self'; "
    "object-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'self'";

/// CSP for shared files: a sandbox with no script, so a hostile HTML or SVG
/// file renders inert in an opaque origin.
const fileCsp =
    "sandbox; default-src 'none'; img-src 'self' data:; media-src 'self'; "
    "style-src 'unsafe-inline'; font-src 'self'; frame-ancestors 'self'";

/// PDFs: browsers' built-in viewers break under `sandbox` or `default-src`,
/// and PDF script runs in the viewer's own sandbox, not this origin. With
/// `nosniff`, a file named `.pdf` is never rendered as HTML.
const pdfCsp = "frame-ancestors 'self'";

/// True for loopback, link-local and private (RFC 1918 / IPv6 ULA) addresses.
/// Carrier-grade NAT (100.64.0.0/10) is deliberately excluded: other phones on
/// the same mobile network live there.
bool isLanAddress(InternetAddress a) {
  if (a.isLoopback || a.isLinkLocal) return true;
  final b = a.rawAddress;
  if (a.type == InternetAddressType.IPv4) {
    return b[0] == 10 || (b[0] == 172 && b[1] >= 16 && b[1] <= 31) || (b[0] == 192 && b[1] == 168);
  }
  if (a.type == InternetAddressType.IPv6) {
    if ((b[0] & 0xFE) == 0xFC) return true; // fc00::/7 unique local
    // IPv4-mapped (::ffff:a.b.c.d)
    final mapped = b.sublist(0, 10).every((x) => x == 0) && b[10] == 0xFF && b[11] == 0xFF;
    if (mapped) return isLanAddress(InternetAddress.fromRawAddress(Uint8List.fromList(b.sublist(12))));
  }
  return false;
}

/// Host headers we answer to: IP literals, `localhost`, single-label names
/// and mDNS `.local` names. Anything else is a public DNS name, which is what
/// a DNS rebinding attack needs a victim's browser to send.
bool isAllowedHost(String? hostHeader) {
  if (hostHeader == null || hostHeader.isEmpty) return false;
  final uri = Uri.tryParse('http://$hostHeader');
  if (uri == null || uri.host.isEmpty) return false;
  var host = uri.host.toLowerCase();
  if (host.endsWith('.')) host = host.substring(0, host.length - 1);
  if (InternetAddress.tryParse(host) != null) return true;
  if (host == 'localhost' || host.endsWith('.local')) return true;
  return !host.contains('.');
}

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
    String Function()? mode,
    this.thumbWait = const Duration(seconds: 3),
    this.thumbTimeout = const Duration(seconds: 8),
    this.lanOnly = true,
  }) : allowZip = allowZip ?? (() => false),
       mode = mode ?? (() => 'folder');

  final PinAuth auth;

  /// How long a thumbnail request may queue for a decoder slot before it gets
  /// a 503 (so a grid of thumbnails can't tie up the browser's connections).
  final Duration thumbWait;

  /// How long one native thumbnail may take before it counts as unsupported.
  final Duration thumbTimeout;

  /// Current identity (read on every request so renames apply immediately).
  final DeviceIdentity Function() identity;

  /// Current shared folder, or null when nothing is shared.
  final FileSource? Function() source;

  /// Other DataCast devices discovered on the network (excluding this one).
  final List<PeerDevice> Function() peers;
  final AssetLoader assets;

  /// Whether visitors may download whole folders as ZIP.
  final bool Function() allowZip;

  /// `folder` or `files` (individually picked files in a flat root).
  final String Function() mode;

  /// Refuse connections from addresses outside private / link-local ranges,
  /// so a phone that is also on mobile data (carrier NAT, public IPv4) is not
  /// reachable from there even though the server binds every interface.
  final bool lanOnly;

  HttpServer? _server;
  String? _localIp;

  int? get port => _server?.port;
  bool get isRunning => _server != null;

  /// Starts listening on all IPv4 interfaces. Tries [preferredPort] and the
  /// next few ports, then falls back to any free port. Returns the port.
  Future<int> start({int preferredPort = 8080, String? localIp, InternetAddress? address}) async {
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
      .addMiddleware(_requestGate)
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
    ..get('/api/thumb', _guard(_thumb))
    ..all('/api/<ignored|.*>', (Request r) => _json({'error': 'Unknown endpoint'}, 404));

  // ---------------------------------------------------------------- middleware

  Middleware get _errors =>
      (inner) => (request) async {
        try {
          return await inner(request);
        } on InvalidPathException {
          return _json({'error': 'Invalid path'}, 400);
        } on FileNotFound {
          return _json({'error': 'Not found'}, 404);
        }
      };

  Middleware get _securityHeaders =>
      (inner) => (request) async {
        final res = await inner(request);
        return res.change(
          headers: {
            'x-content-type-options': 'nosniff',
            'referrer-policy': 'no-referrer',
            'x-frame-options': 'SAMEORIGIN',
            if (!res.headers.containsKey('content-security-policy')) 'content-security-policy': pageCsp,
          },
        );
      };

  /// Rejects requests that did not come from the local network, that name
  /// this server by a hostname a web page could control (DNS rebinding), or
  /// that are cross-origin writes (CSRF).
  Middleware get _requestGate =>
      (inner) => (request) {
        if (lanOnly) {
          final info = request.context['shelf.io.connection_info'];
          if (info is HttpConnectionInfo && !isLanAddress(info.remoteAddress)) {
            return _json({'error': 'Only devices on the local network can connect'}, 403);
          }
        }
        if (!isAllowedHost(request.headers['host'])) {
          return _json({'error': 'Unknown host name. Open this device by its IP address.'}, 403);
        }
        if (request.method != 'GET' && request.method != 'HEAD') {
          final origin = request.headers['origin'];
          if (origin != null && !_sameOrigin(origin, request.headers['host'])) {
            return _json({'error': 'Cross-origin request refused'}, 403);
          }
        }
        return inner(request);
      };

  static bool _sameOrigin(String origin, String? host) {
    if (host == null) return false;
    final o = Uri.tryParse(origin);
    if (o == null || o.scheme != 'http' || o.host.isEmpty) return false;
    final h = Uri.tryParse('http://$host');
    if (h == null) return false;
    return o.host.toLowerCase() == h.host.toLowerCase() && o.port == h.port;
  }

  Handler _guard(FutureOr<Response> Function(Request) h) => (request) {
    if (!auth.validate(_token(request), _clientKey(request))) {
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
    final authed = auth.validate(_token(r), _clientKey(r));
    return _json({
      'name': id.name,
      'deviceId': id.deviceId,
      'platform': id.platform,
      'requiresPin': true,
      'authenticated': authed,
      'sharing': source() != null,
      // The folder's name can say a lot about its contents; only show it to
      // someone who knows the PIN.
      'folderName': authed ? source()?.displayName : null,
      'allowZip': allowZip(),
      'thumbs': true,
      'mode': mode(),
      'apiVersion': apiVersion,
    });
  }

  Response _devices(Request r) {
    final id = identity();
    final selfIp = _localIp ?? _hostOf(r);
    final list = <PeerDevice>[
      PeerDevice(deviceId: id.deviceId, name: id.name, ip: selfIp, port: port ?? 0, platform: id.platform, self: true),
      ...peers().where((p) => p.deviceId != id.deviceId),
    ];
    return _jsonList([for (final d in list) d.toJson()]);
  }

  Future<Response> _authenticate(Request r) async {
    String? pin;
    final len = r.contentLength;
    if (len != null && len > maxAuthBody) return _json({'error': 'Request too large'}, 413);
    try {
      final bytes = <int>[];
      await for (final chunk in r.read()) {
        bytes.addAll(chunk);
        if (bytes.length > maxAuthBody) return _json({'error': 'Request too large'}, 413);
      }
      final body = utf8.decode(bytes, allowMalformed: true);
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
        return _json({'token': token}, 200, {'set-cookie': '$_cookieName=$token; Path=/; HttpOnly; SameSite=Strict'});
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

  Response _logout(Request r) {
    auth.revoke(_token(r));
    return _json({'ok': true}, 200, {'set-cookie': '$_cookieName=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict'});
  }

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
      // Shared files are untrusted: an .html or .svg opened straight from
      // /api/raw must not run script on this origin, where it could use the
      // visitor's session to read every other file.
      'content-security-policy': mime == 'application/pdf' ? pdfCsp : fileCsp,
      'cross-origin-resource-policy': 'same-origin',
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
        headers: {...headers, 'content-length': '$len', 'content-range': 'bytes ${range.start}-${range.end}/$size'},
      );
    }
    return Response.ok(isHead || size == 0 ? null : src.read(path), headers: {...headers, 'content-length': '$size'});
  }

  static const thumbSizes = [128, 256, 512];
  final _thumbSlots = _Semaphore(3);

  Future<Response> _thumb(Request r) async {
    final path = normalizeSharePath(r.url.queryParameters['path']);
    final size = int.tryParse(r.url.queryParameters['size'] ?? '') ?? 256;
    if (!thumbSizes.contains(size)) {
      return _json({'error': 'size must be one of $thumbSizes'}, 400);
    }
    final src = source()!;
    final entry = await src.stat(path);
    if (entry == null) throw FileNotFound(path);
    final mime = entry.mime ?? lookupMimeType(entry.name) ?? '';
    if (entry.isDir || !(mime.startsWith('image/') || mime.startsWith('video/'))) {
      return _json({'error': 'No thumbnail for this file type'}, 415);
    }
    final etag =
        '"${Object.hash(path, entry.modified?.millisecondsSinceEpoch, entry.size, size).toUnsigned(32).toRadixString(16)}"';
    final cacheHeaders = {
      'etag': etag,
      'cache-control': 'private, max-age=86400',
      'cross-origin-resource-policy': 'same-origin',
    };
    if (r.headers['if-none-match'] == etag) return Response.notModified(headers: cacheHeaders);

    if (!await _thumbSlots.acquire(thumbWait)) {
      return _json({'error': 'Busy making thumbnails'}, 503, {'retry-after': '2'});
    }
    List<int>? bytes;
    try {
      bytes = await src.thumbnail(path, size).timeout(thumbTimeout);
    } catch (_) {
      bytes = null; // decoder failed or took too long on this file
    } finally {
      _thumbSlots.release();
    }
    if (bytes == null || bytes.isEmpty) {
      return _json({'error': 'No thumbnail for this file'}, 415);
    }
    return Response.ok(
      bytes,
      headers: {...cacheHeaders, 'content-type': 'image/jpeg', 'content-length': '${bytes.length}'},
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
    return Response.ok(
      zipFolder(src, path),
      headers: {
        'content-type': 'application/zip',
        'content-disposition': _disposition(name, true),
        'cache-control': 'no-store',
        'cross-origin-resource-policy': 'same-origin',
      },
    );
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

  static Response _json(Object body, [int status = 200, Map<String, String>? extraHeaders]) => Response(
    status,
    body: jsonEncode(body),
    headers: {'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store', ...?extraHeaders},
  );

  static Response _jsonList(List<Object?> body) => _json(body);
}

/// A byte range, both ends inclusive.
class ByteRange {
  const ByteRange(this.start, this.end);
  final int start;
  final int end;
  @override
  bool operator ==(Object other) => other is ByteRange && other.start == start && other.end == end;
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
  // Numbers too long for an int would throw (a 500); treat a huge suffix or
  // end as "to the end" and a huge start as out of range.
  if (a.isEmpty) {
    final suffix = int.tryParse(b);
    if (suffix == 0) return RangeResult.unsatisfiable;
    start = suffix == null || size - suffix < 0 ? 0 : size - suffix;
    end = size - 1;
  } else {
    final s = int.tryParse(a);
    if (s == null) return RangeResult.unsatisfiable;
    start = s;
    end = b.isEmpty ? size - 1 : (int.tryParse(b) ?? size - 1);
    if (end >= size) end = size - 1;
  }
  if (size == 0 || start >= size || start > end) return RangeResult.unsatisfiable;
  return ByteRange(start, end);
}

/// Limits how many thumbnails are generated at once.
class _Semaphore {
  _Semaphore(this._max);
  final int _max;
  int _running = 0;
  final _waiters = <Completer<void>>[];

  /// Takes a slot, waiting at most [timeout]. Returns false (and leaves the
  /// queue) if no slot freed up in time. Call [release] after a true result.
  Future<bool> acquire(Duration timeout) async {
    if (_running < _max) {
      _running++;
      return true;
    }
    final c = Completer<void>();
    _waiters.add(c);
    try {
      await c.future.timeout(timeout);
      return true;
    } on TimeoutException {
      // Still queued: give up. Already removed: release() handed us its slot.
      return !_waiters.remove(c);
    }
  }

  /// Frees a slot, handing it straight to the next waiter if there is one.
  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    } else {
      _running--;
    }
  }
}
