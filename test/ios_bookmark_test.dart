import 'dart:io';

import 'package:datacast/models/shared_file.dart';
import 'package:datacast/services/bookmark_file_source.dart';
import 'package:datacast/services/platform_bridge.dart';
import 'package:datacast/services/selection_file_source.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// iOS sources: bookmarks are resolved natively to a path, then read with
/// dart:io. The native side is faked with a mock method channel.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('datacast/native');
  late Directory dir;
  final paths = <String, String>{};

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('datacast_ios');
    await Directory('${dir.path}/sub').create();
    await File('${dir.path}/sub/a.txt').writeAsString('hello world');
    paths
      ..clear()
      ..['${iosBookmarkPrefix}folder'] = dir.path
      ..['${iosBookmarkPrefix}file'] = '${dir.path}/sub/a.txt';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'resolveBookmark') return paths[(call.arguments as Map)['uri']];
      return null;
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    await dir.delete(recursive: true);
  });

  test('bookmarked folder lists and reads through dart:io', () async {
    final src = BookmarkFileSource(PlatformBridge(), '${iosBookmarkPrefix}folder', 'Photos');
    expect((await src.stat('/'))!.name, 'Photos');
    expect((await src.list('/')).map((e) => e.name), ['sub']);
    final bytes = await src.read('/sub/a.txt', start: 6, end: 10).expand((b) => b).toList();
    expect(String.fromCharCodes(bytes), 'world');
  });

  test('unresolvable bookmark reads as missing', () async {
    final src = BookmarkFileSource(PlatformBridge(), '${iosBookmarkPrefix}gone', 'Gone');
    expect(await src.stat('/sub'), isNull);
  });

  test('bookmarked single file is served from the selection', () async {
    final src = SelectionFileSource(PlatformBridge(), [
      const SharedFile(uri: '${iosBookmarkPrefix}file', name: 'a.txt'),
    ], displayName: '1 file');
    final entries = await src.list('/');
    expect(entries.single.size, 11);
    final bytes = await src.read('/a.txt').expand((b) => b).toList();
    expect(String.fromCharCodes(bytes), 'hello world');
  });

  test('isNativeUri', () {
    expect(isNativeUri('content://x'), isTrue);
    expect(isNativeUri('${iosBookmarkPrefix}abc'), isTrue);
    expect(isNativeUri('/var/mobile/a.txt'), isFalse);
  });
}
