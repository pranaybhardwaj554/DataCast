import '../models/file_entry.dart';
import 'descriptor_pool.dart';
import 'file_source.dart';
import 'platform_bridge.dart';
import 'stat_cache.dart';

/// [FileSource] for a folder picked with Android's system folder picker
/// (Storage Access Framework). Dart cannot open `content://` URIs, so listing
/// goes through the native bridge, and reads use a file descriptor that the
/// native side opens for us.
class SafFileSource extends FileSource {
  SafFileSource(this._bridge, this.treeUri, this.displayName) : _pool = DescriptorPool(_bridge);

  final PlatformBridge _bridge;
  final String treeUri;
  @override
  final String displayName;
  final DescriptorPool _pool;
  final _stats = StatCache();

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
  Future<FileEntry?> stat(String path) => _stats.get(path, () => _stat(path));

  Future<FileEntry?> _stat(String path) async {
    final m = await _bridge.stat(treeUri, path);
    if (m == null) return null;
    final e = _entry(m, path);
    return path == '/' ? FileEntry(name: displayName, path: '/', isDir: true) : e;
  }

  @override
  Future<List<int>?> thumbnail(String path, int size) => _bridge.thumbnail(treeUri, path, size);

  @override
  Stream<List<int>> read(String path, {int start = 0, int? end}) async* {
    final e = await stat(path);
    if (e == null || e.isDir) throw FileNotFound(path);
    yield* _pool.read(
      key: '$path|${e.size}|${e.modified?.millisecondsSinceEpoch}',
      path: path,
      size: e.size,
      open: () => _bridge.openFd(treeUri, path),
      readChunk: (off, len) => _bridge.readChunk(treeUri, path, off, len),
      start: start,
      end: end,
    );
  }

  @override
  Future<void> dispose() => _pool.dispose();
}
