/// What the device is sharing: a whole folder, or files picked one by one.
enum ShareMode { folder, files }

/// Why sharing ended without the user tapping Stop in the app.
enum StopReason {
  /// Wi-Fi / hotspot went away.
  wifiLost,

  /// The app can no longer read the shared folder or files.
  accessLost,

  /// The system ended it: notification Stop, the 6-hour Android limit, or
  /// the app being killed while sharing.
  system,
}

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
