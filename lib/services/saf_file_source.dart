import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../models/file_entry.dart';
import 'file_source.dart';
import 'platform_bridge.dart';

/// [FileSource] for a folder picked with Android's system folder picker
/// (Storage Access Framework). Dart cannot open `content://` URIs, so listing
/// goes through the native bridge, and reads use a file descriptor that the
/// native side opens for us.
class SafFileSource extends FileSource {
  SafFileSource(this._bridge, this.treeUri, this.displayName);

  final PlatformBridge _bridge;
  final String treeUri;
  @override
  final String displayName;

  FileEntry _entry(Map<String, Object?> m, String path) {
    final name = m['name'] as String;
    final isDir = m['isDir'] as bool;
    final modified = m['modified'] as int?;
    return FileEntry(
      name: name,
      path: path,
      isDir: isDir,
      size: isDir ? 0 : (m['size'] as int? ?? 0),
      modified: modified == null || modified == 0 ? null : DateTime.fromMillisecondsSinceEpoch(modified),
      mime: isDir ? null : (guessMime(name) ?? m['mime'] as String?),
    );
  }

  @override
  Future<List<FileEntry>> list(String path) async {
    final rows = await _bridge.list(treeUri, path);
    if (rows == null) throw FileNotFound(path);
    return [for (final m in rows) _entry(m, path == '/' ? '/${m['name']}' : '$path/${m['name']}')];
  }

  @override
  Future<FileEntry?> stat(String path) async {
    final m = await _bridge.stat(treeUri, path);
    if (m == null) return null;
    final e = _entry(m, path);
    return path == '/' ? FileEntry(name: displayName, path: '/', isDir: true) : e;
  }

  @override
  Future<List<int>?> thumbnail(String path, int size) => _bridge.thumbnail(treeUri, path, size);

  @override
  Stream<List<int>> read(String path, {int start = 0, int? end}) => readDescriptor(
    bridge: _bridge,
    open: () => _bridge.openFd(treeUri, path),
    readChunk: (off, len) => _bridge.readChunk(treeUri, path, off, len),
    path: path,
    start: start,
    end: end,
  );
}

const _chunk = 256 * 1024;

/// Reads a native file descriptor through procfs, or falls back to copying
/// chunks over the platform channel when the provider can't give one.
Stream<List<int>> readDescriptor({
  required PlatformBridge bridge,
  required Future<int?> Function() open,
  required Future<Uint8List> Function(int offset, int length) readChunk,
  required String path,
  int start = 0,
  int? end,
}) async* {
  RandomAccessFile? raf;
  final fd = await open();
  if (fd == null) throw FileNotFound(path);
  try {
    raf = await File('/proc/self/fd/$fd').open();
  } on FileSystemException {
    raf = null;
  } finally {
    await bridge.closeFd(fd);
  }

  if (raf != null) {
    try {
      final last = end ?? (await raf.length()) - 1;
      var pos = start;
      await raf.setPosition(pos);
      while (pos <= last) {
        final n = (last - pos + 1) < _chunk ? last - pos + 1 : _chunk;
        final bytes = await raf.read(n);
        if (bytes.isEmpty) break;
        pos += bytes.length;
        yield bytes;
      }
    } finally {
      await raf.close();
    }
    return;
  }

  var pos = start;
  while (end == null || pos <= end) {
    final want = end == null ? _chunk : (end - pos + 1).clamp(0, _chunk);
    final bytes = await readChunk(pos, want);
    if (bytes.isEmpty) break;
    pos += bytes.length;
    yield bytes;
  }
}
