import 'dart:async';
import 'dart:io';

import 'package:mime/mime.dart';

import '../models/file_entry.dart';
import '../server/path_utils.dart';

class FileNotFound implements Exception {
  FileNotFound(this.path);
  final String path;
  @override
  String toString() => 'Not found: $path';
}

/// Read-only view of the shared folder.
///
/// Paths are always normalized share paths (`/`, `/a/b.txt`). Implementations:
/// [IoFileSource] for a normal filesystem folder (tests, desktop, iOS) and
/// `SafFileSource` for an Android folder picked through the system picker.
abstract class FileSource {
  /// Human readable name of the shared folder.
  String get displayName;

  /// Lists a folder. Throws [FileNotFound] if it does not exist.
  Future<List<FileEntry>> list(String path);

  /// Returns the entry or null if it does not exist.
  Future<FileEntry?> stat(String path);

  /// Streams bytes [start, end] (end inclusive) of a file.
  Stream<List<int>> read(String path, {int start = 0, int? end});

  Future<void> dispose() async {}
}

String? guessMime(String name) => lookupMimeType(name);

/// [FileSource] backed by a `dart:io` directory.
class IoFileSource extends FileSource {
  IoFileSource(this.root, {String? displayName})
      : displayName = displayName ?? root.uri.pathSegments.where((s) => s.isNotEmpty).lastOrNull ?? root.path;

  final Directory root;
  @override
  final String displayName;

  String _abs(String path) =>
      path == '/' ? root.path : '${root.path}${Platform.pathSeparator}${path.substring(1).replaceAll('/', Platform.pathSeparator)}';

  @override
  Future<List<FileEntry>> list(String path) async {
    final dir = Directory(_abs(path));
    if (!await dir.exists()) throw FileNotFound(path);
    final out = <FileEntry>[];
    await for (final e in dir.list(followLinks: false)) {
      final name = e.path.substring(e.path.lastIndexOf(Platform.pathSeparator) + 1);
      final entry = await _entryFor(e, joinSharePath(path, name));
      if (entry != null) out.add(entry);
    }
    return out;
  }

  Future<FileEntry?> _entryFor(FileSystemEntity e, String path) async {
    final st = await e.stat();
    final name = baseName(path);
    switch (st.type) {
      case FileSystemEntityType.directory:
        return FileEntry(name: name, path: path, isDir: true, modified: st.modified);
      case FileSystemEntityType.file:
        return FileEntry(
          name: name,
          path: path,
          isDir: false,
          size: st.size,
          modified: st.modified,
          mime: guessMime(name),
        );
      default:
        return null; // skip symlinks, sockets, ...
    }
  }

  @override
  Future<FileEntry?> stat(String path) async {
    if (path == '/') {
      return FileEntry(name: displayName, path: '/', isDir: true);
    }
    final abs = _abs(path);
    final type = await FileSystemEntity.type(abs, followLinks: false);
    if (type == FileSystemEntityType.directory) return _entryFor(Directory(abs), path);
    if (type == FileSystemEntityType.file) return _entryFor(File(abs), path);
    return null;
  }

  @override
  Stream<List<int>> read(String path, {int start = 0, int? end}) =>
      File(_abs(path)).openRead(start, end == null ? null : end + 1);
}
