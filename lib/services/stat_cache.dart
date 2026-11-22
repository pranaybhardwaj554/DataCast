import '../models/file_entry.dart';

/// Remembers file details for a few seconds. A video plays as hundreds of
/// range requests and each one used to ask Android for the file's size again
/// (~38 ms each on a Pixel 8).
class StatCache {
  StatCache({this.ttl = const Duration(seconds: 5)});
  final Duration ttl;
  final _entries = <String, ({DateTime at, Future<FileEntry?> value})>{};

  Future<FileEntry?> get(String path, Future<FileEntry?> Function() load) {
    final now = DateTime.now();
    final hit = _entries[path];
    if (hit != null && now.difference(hit.at) < ttl) return hit.value;
    if (_entries.length > 256) _entries.removeWhere((_, e) => now.difference(e.at) >= ttl);
    final value = load();
    _entries[path] = (at: now, value: value);
    value.then<void>(
      (e) {
        if (e == null) _entries.remove(path); // don't remember "missing"
      },
      onError: (Object _) {
        _entries.remove(path);
      },
    );
    return value;
  }
}
