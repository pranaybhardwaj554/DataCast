import 'dart:convert';
import 'dart:io';

import 'package:datacast/models/device_identity.dart';
import 'package:datacast/models/peer_device.dart';
import 'package:datacast/server/datacast_server.dart';
import 'package:datacast/server/path_utils.dart';
import 'package:datacast/server/pin_auth.dart';
import 'package:datacast/services/file_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  late Directory tmp;
  late DataCastServer server;
  late PinAuth auth;
  late Uri base;
  var now = DateTime(2026, 1, 1);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('datacast_test');
    await File('${tmp.path}/hello.txt').writeAsString('Hello, DataCast!');
    await Directory('${tmp.path}/Photos').create();
    await File('${tmp.path}/Photos/a b ü.jpg').writeAsBytes(List.generate(1000, (i) => i % 256));
    now = DateTime(2026, 1, 1);
    auth = PinAuth(pin: '1234', clock: () => now);
    server = DataCastServer(
      auth: auth,
      identity: () => const DeviceIdentity(deviceId: 'dev-1', name: 'Pixel', platform: 'android'),
      source: () => IoFileSource(tmp, displayName: 'Shared'),
      peers: () => const [
        PeerDevice(deviceId: 'dev-2', name: 'Other', ip: '10.0.0.9', port: 8080, platform: 'android'),
      ],
      allowZip: () => true,
      assets: (p) async => p == 'index.html' ? utf8.encode('<html>ui</html>') : null,
    );
    final port = await server.start(preferredPort: 0, address: InternetAddress.loopbackIPv4, localIp: '127.0.0.1');
    base = Uri.parse('http://127.0.0.1:$port');
  });

  tearDown(() async {
    await server.stop();
    await tmp.delete(recursive: true);
  });

  Future<String> login() async {
    final r = await http.post(base.resolve('/api/auth'), body: jsonEncode({'pin': '1234'}));
    expect(r.statusCode, 200);
    expect(r.headers['set-cookie'], contains('dc_token='));
    return jsonDecode(r.body)['token'] as String;
  }

  test('info and devices are public', () async {
    final info = jsonDecode((await http.get(base.resolve('/api/info'))).body);
    expect(info['name'], 'Pixel');
    expect(info['authenticated'], false);
    final devices = jsonDecode((await http.get(base.resolve('/api/devices'))).body) as List;
    expect(devices, hasLength(2));
    expect(devices.first['self'], true);
    expect(devices.last['url'], 'http://10.0.0.9:8080/');
  });

  test('files require a PIN', () async {
    final r = await http.get(base.resolve('/api/files?path=/'));
    expect(r.statusCode, 401);
  });

  test('wrong PINs lock out after 5 attempts', () async {
    for (var i = 4; i >= 1; i--) {
      final r = await http.post(base.resolve('/api/auth'), body: jsonEncode({'pin': '0000'}));
      expect(r.statusCode, 401);
      expect(jsonDecode(r.body)['attemptsLeft'], i);
    }
    var r = await http.post(base.resolve('/api/auth'), body: jsonEncode({'pin': '0000'}));
    expect(r.statusCode, 429);
    expect(jsonDecode(r.body)['retryAfterSec'], 30);
    // Even the right PIN is refused while locked.
    r = await http.post(base.resolve('/api/auth'), body: jsonEncode({'pin': '1234'}));
    expect(r.statusCode, 429);
    now = now.add(const Duration(seconds: 31));
    await login();
  });

  test('lists folders, dirs first', () async {
    final token = await login();
    final r = await http.get(base.resolve('/api/files?path=/'), headers: {'authorization': 'Bearer $token'});
    expect(r.statusCode, 200);
    final body = jsonDecode(r.body);
    expect(body['name'], 'Shared');
    final names = [for (final e in body['entries']) e['name']];
    expect(names, ['Photos', 'hello.txt']);
    final sub = jsonDecode((await http.get(
      base.replace(path: '/api/files', queryParameters: {'path': '/Photos'}),
      headers: {'cookie': 'dc_token=$token'},
    )).body);
    expect(sub['entries'].single['path'], '/Photos/a b ü.jpg');
    expect(sub['entries'].single['size'], 1000);
    expect(sub['entries'].single['mime'], 'image/jpeg');
  });

  test('rejects path traversal', () async {
    final token = await login();
    final r = await http.get(base.replace(path: '/api/files', queryParameters: {'path': '/../'}),
        headers: {'authorization': 'Bearer $token'});
    expect(r.statusCode, 400);
  });

  test('download and ranged raw', () async {
    final token = await login();
    final h = {'authorization': 'Bearer $token'};
    var r = await http.get(base.replace(path: '/api/download', queryParameters: {'path': '/hello.txt'}), headers: h);
    expect(r.body, 'Hello, DataCast!');
    expect(r.headers['content-disposition'], startsWith('attachment;'));
    r = await http.get(base.replace(path: '/api/raw', queryParameters: {'path': '/Photos/a b ü.jpg'}),
        headers: {...h, 'range': 'bytes=10-19'});
    expect(r.statusCode, 206);
    expect(r.bodyBytes, List.generate(10, (i) => i + 10));
    expect(r.headers['content-range'], 'bytes 10-19/1000');
    r = await http.get(base.replace(path: '/api/raw', queryParameters: {'path': '/hello.txt'}),
        headers: {...h, 'range': 'bytes=500-'});
    expect(r.statusCode, 416);
  });

  test('regenerating PIN signs everyone out', () async {
    final token = await login();
    auth.setPin('9999');
    final r = await http.get(base.resolve('/api/files?path=/'), headers: {'authorization': 'Bearer $token'});
    expect(r.statusCode, 401);
  });

  test('serves web UI with SPA fallback', () async {
    expect((await http.get(base.resolve('/'))).body, '<html>ui</html>');
    expect((await http.get(base.resolve('/device/abc'))).body, '<html>ui</html>');
    expect((await http.get(base.resolve('/missing.js'))).statusCode, 404);
  });

  test('connected clients counts recent tokens', () async {
    await login();
    expect(auth.connectedClients, 1);
    now = now.add(const Duration(minutes: 3));
    expect(auth.connectedClients, 0);
  });

  test('zip download is a valid archive', () async {
    final token = await login();
    final r = await http.get(base.replace(path: '/api/zip', queryParameters: {'path': '/'}),
        headers: {'authorization': 'Bearer $token'});
    expect(r.statusCode, 200);
    final zipFile = File('${tmp.path}/../dc_test_out.zip');
    await zipFile.writeAsBytes(r.bodyBytes);
    final out = Directory('${tmp.path}_unzipped');
    final res = await Process.run('python3', ['-c', 'import zipfile,sys; z=zipfile.ZipFile(sys.argv[1]); assert z.testzip() is None; z.extractall(sys.argv[2]); print(sorted(z.namelist()))', zipFile.path, out.path]);
    expect(res.exitCode, 0, reason: res.stderr.toString());
    expect(res.stdout.toString(), contains('Photos/a b ü.jpg'));
    expect(await File('${out.path}/hello.txt').readAsString(), 'Hello, DataCast!');
    await zipFile.delete();
    await out.delete(recursive: true);
  });

  test('path normalization', () {
    expect(normalizeSharePath(null), '/');
    expect(normalizeSharePath('a//b/'), '/a/b');
    expect(() => normalizeSharePath('/a/../b'), throwsA(isA<InvalidPathException>()));
    expect(parseRange('bytes=-5', 10), const ByteRange(5, 9));
  });
}
