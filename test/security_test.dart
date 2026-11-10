import 'dart:convert';
import 'dart:io';

import 'package:datacast/models/device_identity.dart';
import 'package:datacast/server/datacast_server.dart';
import 'package:datacast/server/pin_auth.dart';
import 'package:datacast/server/zip_stream.dart';
import 'package:datacast/services/file_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// Regression tests for the security review (see docs/SECURITY.md).
void main() {
  late Directory tmp;
  late Directory outside;
  late DataCastServer server;
  late PinAuth auth;
  late Uri base;
  late int port;
  var now = DateTime(2026, 1, 1);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('datacast_sec');
    outside = await Directory.systemTemp.createTemp('datacast_outside');
    await File('${outside.path}/secret.txt').writeAsString('top secret');
    await File('${tmp.path}/hello.txt').writeAsString('hi');
    await File('${tmp.path}/evil.html').writeAsString('<script>alert(1)</script>');
    await File('${tmp.path}/doc.pdf').writeAsString('%PDF-1.4');
    now = DateTime(2026, 1, 1);
    auth = PinAuth(pin: '1234', clock: () => now);
    server = DataCastServer(
      auth: auth,
      identity: () => const DeviceIdentity(deviceId: 'dev-1', name: 'Pixel', platform: 'android'),
      source: () => IoFileSource(tmp, displayName: 'Tax returns'),
      peers: () => const [],
      allowZip: () => true,
      assets: (p) async => p == 'index.html' ? utf8.encode('<html>ui</html>') : null,
    );
    port = await server.start(preferredPort: 0, address: InternetAddress.loopbackIPv4, localIp: '127.0.0.1');
    base = Uri.parse('http://127.0.0.1:$port');
  });

  tearDown(() async {
    await server.stop();
    await tmp.delete(recursive: true);
    await outside.delete(recursive: true);
  });

  Future<String> login() async {
    final r = await http.post(base.resolve('/api/auth'), body: jsonEncode({'pin': '1234'}));
    expect(r.statusCode, 200);
    return jsonDecode(r.body)['token'] as String;
  }

  /// Sends a request with a custom Host / Origin, which package:http can't.
  Future<int> rawRequest(String method, String path, {String? host, String? origin, String? body}) async {
    final client = HttpClient();
    try {
      final req = await client.openUrl(method, base.resolve(path));
      if (host != null) req.headers.set(HttpHeaders.hostHeader, host);
      if (origin != null) req.headers.set('origin', origin);
      if (body != null) req.write(body);
      final res = await req.close();
      await res.drain<void>();
      return res.statusCode;
    } finally {
      client.close(force: true);
    }
  }

  group('DNS rebinding: Host header', () {
    test('public host names are refused', () async {
      expect(await rawRequest('GET', '/api/info', host: 'rebind.attacker.example:$port'), 403);
      expect(await rawRequest('GET', '/', host: 'attacker.example'), 403);
    });

    test('IP literals, localhost and .local names are served', () async {
      expect(await rawRequest('GET', '/api/info', host: '192.168.1.20:8080'), 200);
      expect(await rawRequest('GET', '/api/info', host: 'localhost:$port'), 200);
      expect(await rawRequest('GET', '/api/info', host: 'pixel.local:$port'), 200);
      expect(await rawRequest('GET', '/api/info', host: '[fe80::1]:8080'), 200);
    });

    test('isAllowedHost', () {
      expect(isAllowedHost(null), isFalse);
      expect(isAllowedHost(''), isFalse);
      expect(isAllowedHost('10.0.0.5'), isTrue);
      expect(isAllowedHost('Pixel.LOCAL.'), isTrue);
      expect(isAllowedHost('router'), isTrue);
      expect(isAllowedHost('1.2.3.4.nip.io'), isFalse);
      expect(isAllowedHost('evil.com:8080'), isFalse);
    });
  });

  group('CSRF: Origin on writes', () {
    test('cross-origin POST is refused', () async {
      final body = jsonEncode({'pin': '1234'});
      expect(await rawRequest('POST', '/api/auth', origin: 'http://evil.example', body: body), 403);
      expect(await rawRequest('POST', '/api/logout', origin: 'http://192.168.1.9:8080'), 403);
    });

    test('same-origin and Origin-less POSTs work', () async {
      final body = jsonEncode({'pin': '1234'});
      expect(await rawRequest('POST', '/api/auth', origin: 'http://127.0.0.1:$port', body: body), 200);
      expect(await rawRequest('POST', '/api/auth', body: body), 200);
    });
  });

  test('LAN-only: private, link-local and loopback addresses', () {
    bool lan(String a) => isLanAddress(InternetAddress(a));
    expect(lan('127.0.0.1'), isTrue);
    expect(lan('10.1.2.3'), isTrue);
    expect(lan('172.16.0.1'), isTrue);
    expect(lan('172.20.10.2'), isTrue); // iPhone hotspot
    expect(lan('192.168.43.7'), isTrue); // Android hotspot
    expect(lan('169.254.3.4'), isTrue);
    expect(lan('fe80::1'), isTrue);
    expect(lan('fd12:3456::1'), isTrue);
    expect(lan('::ffff:192.168.1.2'), isTrue);
    expect(lan('8.8.8.8'), isFalse);
    expect(lan('100.64.0.9'), isFalse); // carrier NAT neighbours
    expect(lan('172.32.0.1'), isFalse);
    expect(lan('2001:4860::8888'), isFalse);
  });

  group('PIN brute force', () {
    test('wrong PINs from many IPs share one budget', () {
      // 4 tries each from 5 addresses stays under every per-IP limit...
      for (var ip = 0; ip < 5; ip++) {
        for (var i = 0; i < 4; i++) {
          final r = auth.attempt('10.0.0.$ip', '0000');
          if (ip == 4 && i == 3) {
            expect(r, isA<AuthLocked>());
          } else {
            expect(r, isA<AuthDenied>());
          }
        }
      }
      // ...but the 20th wrong PIN locks everyone, even with the right PIN.
      expect(auth.attempt('10.0.0.99', '1234'), isA<AuthLocked>());
      expect(auth.totalFailures, 20);
      now = now.add(const Duration(seconds: 31));
      expect(auth.attempt('10.0.0.99', '1234'), isA<AuthGranted>());
    });

    test('global lockouts double and keep signed-in clients working', () {
      final ok = auth.attempt('10.0.0.1', '1234') as AuthGranted;
      var reported = 0;
      auth.onBruteForce = (n) => reported = n;
      for (var i = 0; i < 20; i++) {
        auth.attempt('10.9.${i ~/ 4}.${i % 4}', '0000');
      }
      expect(reported, 20);
      expect(auth.validate(ok.token, '10.0.0.1'), isTrue);
      now = now.add(const Duration(seconds: 31));
      for (var i = 0; i < 20; i++) {
        auth.attempt('10.8.${i ~/ 4}.${i % 4}', '0000');
      }
      final r = auth.attempt('10.0.0.50', '1234') as AuthLocked;
      expect(r.retryAfter, const Duration(seconds: 60));
    });

    test('changing the PIN resets the budget', () {
      for (var i = 0; i < 20; i++) {
        auth.attempt('10.7.${i ~/ 4}.${i % 4}', '0000');
      }
      auth.setPin('5678');
      expect(auth.totalFailures, 0);
      expect(auth.attempt('10.0.0.1', '5678'), isA<AuthGranted>());
    });

    test('per-IP records stay bounded', () {
      final big = PinAuth(pin: '1234', globalMaxFailures: 1 << 30, clock: () => now);
      for (var i = 0; i < 5000; i++) {
        big.attempt('ip-$i', '0000');
      }
      expect(big.attempt('fresh', '1234'), isA<AuthGranted>());
    });

    test('oversized auth body is refused', () async {
      final r = await http.post(base.resolve('/api/auth'), body: 'x' * (maxAuthBody + 1));
      expect(r.statusCode, 413);
    });
  });

  test('symlinked folder cannot escape the share', () async {
    await Link('${tmp.path}/escape').create(outside.path);
    await Link('${tmp.path}/secret-link.txt').create('${outside.path}/secret.txt');
    final token = await login();
    final h = {'authorization': 'Bearer $token'};
    for (final p in ['/escape/secret.txt', '/secret-link.txt']) {
      final r = await http.get(base.resolve('/api/raw?path=${Uri.encodeQueryComponent(p)}'), headers: h);
      expect(r.statusCode, 404, reason: p);
      expect(r.body, isNot(contains('top secret')));
    }
    final ls = await http.get(base.resolve('/api/files?path=/escape'), headers: h);
    expect(ls.statusCode, 404);
    final src = IoFileSource(tmp);
    expect(await src.stat('/escape/secret.txt'), isNull);
    await expectLater(src.read('/escape/secret.txt').toList(), throwsA(isA<FileNotFound>()));
  });

  test('shared files are served inside a script-free sandbox', () async {
    final token = await login();
    final h = {'authorization': 'Bearer $token'};
    final html = await http.get(base.resolve('/api/raw?path=/evil.html'), headers: h);
    expect(html.statusCode, 200);
    expect(html.headers['content-security-policy'], startsWith('sandbox;'));
    expect(html.headers['content-security-policy'], isNot(contains('script')));
    expect(html.headers['cross-origin-resource-policy'], 'same-origin');
    final dl = await http.get(base.resolve('/api/download?path=/evil.html'), headers: h);
    expect(dl.headers['content-security-policy'], fileCsp);
    final pdf = await http.get(base.resolve('/api/raw?path=/doc.pdf'), headers: h);
    expect(pdf.headers['content-security-policy'], pdfCsp);
    final page = await http.get(base.resolve('/'));
    expect(page.headers['content-security-policy'], pageCsp);
    expect(page.headers['x-content-type-options'], 'nosniff');
  });

  test('huge Range numbers do not crash the server', () async {
    final token = await login();
    Future<int> get(String range) async => (await http.get(
      base.resolve('/api/raw?path=/hello.txt'),
      headers: {'authorization': 'Bearer $token', 'range': range},
    )).statusCode;
    expect(await get('bytes=99999999999999999999999999-'), 416);
    expect(await get('bytes=0-99999999999999999999999999'), 206);
    expect(await get('bytes=-99999999999999999999999999'), 206);
  });

  test('folder name is hidden until the PIN is entered', () async {
    var info = jsonDecode((await http.get(base.resolve('/api/info'))).body);
    expect(info['folderName'], isNull);
    final token = await login();
    info = jsonDecode((await http.get(base.resolve('/api/info'), headers: {'authorization': 'Bearer $token'})).body);
    expect(info['folderName'], 'Tax returns');
  });

  test('zip entry names cannot climb out of the archive', () {
    expect(zipSafeName('..'), '__');
    expect(zipSafeName('.'), '_');
    expect(zipSafeName('../../etc/passwd'), '.._.._etc_passwd');
    expect(zipSafeName(r'..\..\win.ini'), '.._.._win.ini');
    expect(zipSafeName('C:boot.ini'), 'C_boot.ini');
    expect(zipSafeName('a\u0000b\nc'), 'a_b_c');
    expect(zipSafeName(''), '_');
    expect(zipSafeName('normal name.jpg'), 'normal name.jpg');
    expect(zipSafeName('.hidden'), '.hidden');
  });
}
