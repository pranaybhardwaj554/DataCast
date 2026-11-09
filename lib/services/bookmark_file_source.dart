import 'dart:async';
import 'dart:io';

import '../models/file_entry.dart';
import 'file_source.dart';
import 'platform_bridge.dart';

/// [FileSource] for a folder picked in the iOS Files picker.
///
/// The picker gives a security-scoped bookmark ([iosBookmarkPrefix] URI). The
/// native side resolves it once and starts access, after which the folder is
/// a normal path that [IoFileSource] reads with `dart:io`. Thumbnails come
/// from QuickLook on the native side.
class BookmarkFileSource extends FileSource {
  BookmarkFileSource(this._bridge, this.uri, this.displayName);

  final PlatformBridge _bridge;
  final String uri;
  @override
  final String displayName;

  Future<IoFileSource>? _io;

  Future<IoFileSource> _resolve() => _io ??= () async {
    final path = await _bridge.resolveBookmark(uri);
    if (path == null) {
      _io = null; // try again next time, e.g. after iCloud catches up
      throw FileNotFound('/');
    }
    return IoFileSource(Directory(path), displayName: displayName);
  }();

  @override
  Future<List<FileEntry>> list(String path) async => (await _resolve()).list(path);

  @override
  Future<FileEntry?> stat(String path) async {
    try {
      return await (await _resolve()).stat(path);
    } on FileNotFound {
      return null;
    }
  }

  @override
  Future<List<int>?> thumbnail(String path, int size) => _bridge.thumbnail(uri, path, size);

  @override
  Stream<List<int>> read(String path, {int start = 0, int? end}) =>
      Stream.fromFuture(_resolve()).asyncExpand((io) => io.read(path, start: start, end: end));
}
