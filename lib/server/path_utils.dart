/// Thrown when a client asks for a path outside the shared root.
class InvalidPathException implements Exception {
  InvalidPathException(this.path);
  final String path;
  @override
  String toString() => 'Invalid path: $path';
}

/// Normalizes a client-supplied path to `/a/b` form.
///
/// Rejects `..`, `.`, empty-but-weird segments, backslashes and NUL bytes, so
/// a request can never escape the shared folder.
String normalizeSharePath(String? raw) {
  if (raw == null || raw.isEmpty || raw == '/') return '/';
  if (raw.contains('\u0000') || raw.contains('\\')) {
    throw InvalidPathException(raw);
  }
  final segments = <String>[];
  for (final seg in raw.split('/')) {
    if (seg.isEmpty) continue;
    if (seg == '.' || seg == '..') throw InvalidPathException(raw);
    segments.add(seg);
  }
  return segments.isEmpty ? '/' : '/${segments.join('/')}';
}

/// Joins a normalized parent path and a child name.
String joinSharePath(String parent, String name) => parent == '/' ? '/$name' : '$parent/$name';

/// Last segment of a normalized path (`''` for the root).
String baseName(String path) => path == '/' ? '' : path.substring(path.lastIndexOf('/') + 1);
