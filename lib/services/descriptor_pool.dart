import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'file_source.dart';
import 'platform_bridge.dart';

/// Keeps Android files open across HTTP requests and caches what was read.
///
/// A browser plays a video as hundreds of small range requests (64 to 256 KB,
/// often two streams at once for audio and video). Opening the file and
/// making the first platform-channel read cost ~140 ms per request on a Pixel
/// 8, so each small request crawled at a few Mbit/s even though one long read
/// runs at ~100 Mbit/s. Here a file is opened once, read in [blockSize] blocks
/// with read-ahead, and recent blocks are served from memory.
class DescriptorPool {
  DescriptorPool(
    this._bridge, {
    this.blockSize = 1024 * 1024,
    this.blocksPerFile = 32,
    this.maxFiles = 4,
    this.idleClose = const Duration(seconds: 30),
    this.readAhead = 4,
  });

  final PlatformBridge _bridge;
  final int blockSize;
  final int blocksPerFile;
  final int maxFiles;
  final Duration idleClose;
  final int readAhead;

  final _readers = <String, _Reader>{}; // insertion order = least recently used first
  final _opening = <String, Future<_Reader>>{};
  final _waiting = <String, int>{}; // callers waiting on an open, per key

  int get openFiles => _readers.length;

  /// Streams bytes [start, end] (inclusive) of the file identified by [key].
  /// [key] should change when the file changes (include size and mtime).
  /// [open] returns a raw descriptor (owned by the pool afterwards) or null if
  /// the file is gone. [readChunk] is the slow fallback for providers that
  /// hand out a pipe, which can't be read at an offset.
  Stream<List<int>> read({
    required String key,
    required String path,
    required int size,
    required Future<int?> Function() open,
    required Future<Uint8List> Function(int offset, int length) readChunk,
    int start = 0,
    int? end,
  }) async* {
    final last = end ?? size - 1;
    if (start > last) return;
    final reader = await _acquire(key, path, open); // counted as active already
    reader.idle?.cancel();
    try {
      if (reader.direct) {
        yield* _readDirect(reader, start, last);
        return;
      }
      if (!reader.pipe) {
        // Errors inside yield* go to the client, not to a catch here, so find
        // out whether the descriptor can be read at an offset before streaming.
        try {
          await reader.block(start ~/ blockSize, this);
        } on _PipeException {
          reader.pipe = true;
        }
      }
      yield* reader.pipe ? _readSlow(readChunk, start, last) : _readBlocks(reader, start, last, size);
    } finally {
      reader.active--;
      _scheduleIdle(key, reader);
    }
  }

  /// Returns the reader for [key] with this caller already counted in
  /// `active`, so another file's open can't evict it in between.
  Future<_Reader> _acquire(String key, String path, Future<int?> Function() open) {
    final existing = _readers.remove(key);
    if (existing != null) {
      _readers[key] = existing; // most recently used goes last
      existing.active++;
      return Future.value(existing);
    }
    _waiting[key] = (_waiting[key] ?? 0) + 1;
    return _opening[key] ??= () async {
      try {
        final fd = await open();
        if (fd == null) throw FileNotFound(path);
        final reader = _Reader(fd);
        // Reopening through procfs lets dart:io read without the channel, but
        // scoped storage refuses it for camera folders, so test it once.
        try {
          final raf = await File('/proc/self/fd/$fd').open();
          await raf.setPosition(0);
          await raf.close();
          reader.direct = true;
        } on FileSystemException {
          reader.direct = false;
        }
        if (logStreaming) {
          // ignore: avoid_print
          print('[DataCast] opened $path (${reader.direct ? 'direct' : 'channel, kept open'})');
        }
        reader.active = _waiting.remove(key) ?? 1;
        _readers[key] = reader;
        _evict();
        return reader;
      } catch (_) {
        _waiting.remove(key);
        rethrow;
      } finally {
        _opening.remove(key);
      }
    }();
  }

  Stream<List<int>> _readDirect(_Reader r, int start, int last) async* {
    final raf = await File('/proc/self/fd/${r.fd}').open();
    try {
      var pos = start;
      await raf.setPosition(pos);
      while (pos <= last) {
        final n = (last - pos + 1) < blockSize * 2 ? last - pos + 1 : blockSize * 2;
        final bytes = await raf.read(n);
        if (bytes.isEmpty) break;
        pos += bytes.length;
        yield bytes;
      }
    } finally {
      await raf.close();
    }
  }

  Stream<List<int>> _readBlocks(_Reader r, int start, int last, int size) async* {
    var pos = start;
    while (pos <= last) {
      final index = pos ~/ blockSize;
      for (var a = 1; a <= readAhead; a++) {
        if ((index + a) * blockSize < size) r.block(index + a, this).ignore();
      }
      final block = await r.block(index, this);
      final offset = pos - index * blockSize;
      if (offset >= block.length) break;
      final n = block.length - offset < last - pos + 1 ? block.length - offset : last - pos + 1;
      yield Uint8List.sublistView(block, offset, offset + n);
      pos += n;
    }
  }

  Stream<List<int>> _readSlow(Future<Uint8List> Function(int, int) readChunk, int start, int last) async* {
    var pos = start;
    while (pos <= last) {
      final want = (last - pos + 1) < blockSize * 2 ? last - pos + 1 : blockSize * 2;
      final bytes = await readChunk(pos, want);
      if (bytes.isEmpty) break;
      pos += bytes.length;
      yield bytes;
    }
  }

  Future<Uint8List> _fetch(_Reader r, int index) async {
    try {
      return await _bridge.readFd(r.fd, index * blockSize, blockSize);
    } on Exception catch (e) {
      // PlatformException from a provider that gave us a pipe (ESPIPE).
      if (e is FileNotFound) rethrow;
      throw _PipeException();
    }
  }

  void _scheduleIdle(String key, _Reader r) {
    if (r.active > 0) return;
    r.idle?.cancel();
    r.idle = Timer(idleClose, () {
      if (r.active == 0 && identical(_readers[key], r)) {
        _readers.remove(key);
        _close(r);
      }
    });
  }

  void _evict() {
    while (_readers.length > maxFiles) {
      final victim = _readers.entries.firstWhere((e) => e.value.active == 0, orElse: () => _readers.entries.first);
      if (victim.value.active > 0) return; // everything busy: allow a few extra
      _readers.remove(victim.key);
      _close(victim.value);
    }
  }

  void _close(_Reader r) {
    r.idle?.cancel();
    r.blocks.clear();
    _bridge.closeFd(r.fd).ignore();
  }

  Future<void> dispose() async {
    for (final r in _readers.values) {
      _close(r);
    }
    _readers.clear();
  }
}

class _PipeException implements Exception {}

class _Reader {
  _Reader(this.fd);
  final int fd;
  bool direct = false;
  bool pipe = false;
  int active = 0;
  Timer? idle;
  final blocks = <int, Uint8List>{}; // insertion order = least recently used first
  final pending = <int, Future<Uint8List>>{};

  Future<Uint8List> block(int index, DescriptorPool pool) {
    final hit = blocks.remove(index);
    if (hit != null) {
      blocks[index] = hit;
      return Future.value(hit);
    }
    return pending[index] ??= pool._fetch(this, index).then(
      (bytes) {
        pending.remove(index);
        blocks[index] = bytes;
        while (blocks.length > pool.blocksPerFile) {
          blocks.remove(blocks.keys.first);
        }
        return bytes;
      },
      onError: (Object e) {
        pending.remove(index);
        throw e;
      },
    );
  }
}
