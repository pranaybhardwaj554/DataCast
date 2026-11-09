import 'dart:async';
import 'dart:io';

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

  static const _chunk = 256 * 1024;

  FileEntry _entry(Map<String, Object?> m, String path) {
    final name = m['name'] as String;
    final isDir = m['isDir'] as bool;
    final modified = m['modified'] as int?;
    return FileEntry(
      name: name,
      path: path,
      isDir: isDir,
      size: isDir ? 0 : (m['size'] as int? ?? 0),
      modified: modified == null || modified == 0
          ? null
          : DateTime.fromMillisecondsSinceEpoch(modified),
      mime: isDir ? null : (guessMime(name) ?? m['mime'] as String?),
    );
  }

  @override
  Future<List<FileEntry>> list(String path) async {
    final rows = await _bridge.list(treeUri, path);
    if (rows == null) throw FileNotFound(path);
    return [
      for (final m in rows)
        _entry(m, path == '/' ? '/${m['name']}' : '$path/${m['name']}'),
    ];
  }

  @override
  Future<FileEntry?> stat(String path) async {
    final m = await _bridge.stat(treeUri, path);
    if (m == null) return null;
    final e = _entry(m, path);
    return path == '/'
        ? FileEntry(name: displayName, path: '/', isDir: true)
        : e;
  }

  @override
  Stream<List<int>> read(String path, {int start = 0, int? end}) async* {
    RandomAccessFile? raf;
    final fd = await _bridge.openFd(treeUri, path);
    if (fd == null) throw FileNotFound(path);
    try {
      // Re-open the descriptor through procfs so dart:io can read it directly.
      raf = await File('/proc/self/fd/$fd').open();
    } on FileSystemException {
      raf = null;
    } finally {
      await _bridge.closeFd(fd);
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

    // Fallback: copy chunks over the platform channel.
    var pos = start;
    while (end == null || pos <= end) {
      final want = end == null ? _chunk : (end - pos + 1).clamp(0, _chunk);
      final bytes = await _bridge.readChunk(treeUri, path, pos, want);
      if (bytes.isEmpty) break;
      pos += bytes.length;
      yield bytes;
    }
  }
}
