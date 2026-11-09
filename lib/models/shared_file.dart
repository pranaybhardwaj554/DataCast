/// What the device is sharing: a whole folder, or files picked one by one.
enum ShareMode { folder, files }

/// One file the user picked to share in [ShareMode.files].
class SharedFile {
  const SharedFile({required this.uri, required this.name, this.size = 0, this.mime});

  /// Android: a `content://` document URI. Elsewhere: a filesystem path.
  final String uri;
  final String name;
  final int size;
  final String? mime;

  Map<String, Object?> toJson() => {'uri': uri, 'name': name, 'size': size, 'mime': mime};

  factory SharedFile.fromJson(Map<String, Object?> j) => SharedFile(
    uri: j['uri'] as String,
    name: j['name'] as String,
    size: (j['size'] as num?)?.toInt() ?? 0,
    mime: j['mime'] as String?,
  );
}
