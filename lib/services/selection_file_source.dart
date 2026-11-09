import 'dart:io';

import '../models/file_entry.dart';
import '../models/shared_file.dart';
import 'file_source.dart';
import 'platform_bridge.dart';
import 'saf_file_source.dart';

/// [FileSource] for individually picked files, shown as one flat folder.
///
/// Duplicate names get a ` (2)`, ` (3)`... suffix so every file has a unique
/// path.
class SelectionFileSource extends FileSource {
  SelectionFileSource(this._bridge, List<SharedFile> files, {required this.displayName}) {
    for (final f in files) {
      _byName[_uniqueName(f.name)] = f;
    }
  }

  final PlatformBridge _bridge;
  @override
  final String displayName;
  final Map<String, SharedFile> _byName = {};

  String _uniqueName(String name) {
    if (!_byName.containsKey(name)) return name;
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '';
    for (var i = 2; ; i++) {
      final candidate = '$stem ($i)$ext';
      if (!_byName.containsKey(candidate)) return candidate;
    }
  }

  static bool _isContent(String uri) => uri.startsWith('content://');

  Future<FileEntry?> _entry(String name, SharedFile f) async {
    if (_isContent(f.uri)) {
      final m = await _bridge.docStat(f.uri);
      if (m == null) return null;
      final modified = m['modified'] as int?;
      return FileEntry(
        name: name,
        path: '/$name',
        isDir: false,
        size: (m['size'] as num?)?.toInt() ?? f.size,
        modified: modified == null || modified == 0 ? null : DateTime.fromMillisecondsSinceEpoch(modified),
        mime: guessMime(name) ?? m['mime'] as String? ?? f.mime,
      );
    }
    final file = File(f.uri);
    if (!await file.exists()) return null;
    final st = await file.stat();
    return FileEntry(
      name: name,
      path: '/$name',
      isDir: false,
      size: st.size,
      modified: st.modified,
      mime: guessMime(name),
    );
  }

  @override
  Future<List<FileEntry>> list(String path) async {
    if (path != '/') throw FileNotFound(path);
    final out = <FileEntry>[];
    for (final e in _byName.entries) {
      final entry = await _entry(e.key, e.value);
      if (entry != null) out.add(entry);
    }
    return out;
  }

  @override
  Future<FileEntry?> stat(String path) async {
    if (path == '/') return FileEntry(name: displayName, path: '/', isDir: true);
    final f = _fileFor(path);
    return f == null ? null : _entry(path.substring(1), f);
  }

  SharedFile? _fileFor(String path) => path.lastIndexOf('/') == 0 ? _byName[path.substring(1)] : null;

  @override
  Stream<List<int>> read(String path, {int start = 0, int? end}) {
    final f = _fileFor(path);
    if (f == null) throw FileNotFound(path);
    if (!_isContent(f.uri)) {
      return File(f.uri).openRead(start, end == null ? null : end + 1);
    }
    return readDescriptor(
      bridge: _bridge,
      open: () => _bridge.docOpenFd(f.uri),
      readChunk: (off, len) => _bridge.docReadChunk(f.uri, off, len),
      path: path,
      start: start,
      end: end,
    );
  }
}
