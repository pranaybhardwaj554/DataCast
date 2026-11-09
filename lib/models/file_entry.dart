/// One file or folder inside the shared root.
class FileEntry {
  const FileEntry({
    required this.name,
    required this.path,
    required this.isDir,
    this.size = 0,
    this.modified,
    this.mime,
  });

  /// Display name, e.g. `holiday.jpg`.
  final String name;

  /// Path relative to the shared root, always starting with `/`.
  final String path;
  final bool isDir;

  /// Size in bytes (0 for folders).
  final int size;
  final DateTime? modified;
  final String? mime;

  Map<String, Object?> toJson() => {
    'name': name,
    'path': path,
    'isDir': isDir,
    'size': size,
    'modified': modified?.toUtc().toIso8601String(),
    'mime': mime,
  };
}
