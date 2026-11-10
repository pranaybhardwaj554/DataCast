import 'dart:convert';
import 'dart:typed_data';

import '../models/file_entry.dart';
import '../services/file_source.dart';

/// Streams a folder as an uncompressed ("stored") ZIP without buffering it.
///
/// Uses data descriptors for the CRC (computed on the fly) and ZIP64 records
/// when a file or the archive passes 4 GB. Photos and videos are already
/// compressed, so storing keeps CPU use low on the phone.
Stream<List<int>> zipFolder(FileSource src, String root) async* {
  final files = <({FileEntry entry, String name})>[];
  Future<void> walk(String path, String prefix) async {
    final entries = await src.list(path);
    for (final e in entries) {
      final name = '$prefix${zipSafeName(e.name)}';
      if (e.isDir) {
        files.add((entry: e, name: '$name/'));
        await walk(e.path, '$name/');
      } else {
        files.add((entry: e, name: name));
      }
    }
  }

  await walk(root, '');

  final central = BytesBuilder(copy: false);
  var offset = 0;
  for (final f in files) {
    final isDir = f.entry.isDir;
    final size = isDir ? 0 : f.entry.size;
    final name = utf8.encode(f.name);
    final zip64 = size >= 0xFFFFFFFF;
    final (dosTime, dosDate) = _dos(f.entry.modified ?? DateTime(1980));
    final headerOffset = offset;

    // Local file header (CRC comes later in the data descriptor).
    final local = _Writer()
      ..u32(0x04034b50)
      ..u16(zip64 ? 45 : 20)
      ..u16(0x0808) // bit 3: data descriptor, bit 11: UTF-8 names
      ..u16(0) // stored
      ..u16(dosTime)
      ..u16(dosDate)
      ..u32(0)
      ..u32(zip64 ? 0xFFFFFFFF : size)
      ..u32(zip64 ? 0xFFFFFFFF : size)
      ..u16(name.length)
      ..u16(zip64 ? 20 : 0)
      ..bytes(name);
    if (zip64) {
      local
        ..u16(0x0001)
        ..u16(16)
        ..u64(size)
        ..u64(size);
    }
    final lb = local.take();
    offset += lb.length;
    yield lb;

    var crc = 0;
    var written = 0;
    if (!isDir) {
      await for (final chunk in src.read(f.entry.path)) {
        crc = _crc32(chunk, crc);
        written += chunk.length;
        offset += chunk.length;
        yield chunk;
      }
      if (written != size) {
        throw StateError('${f.entry.path} changed size while zipping');
      }
    }

    final desc = _Writer()
      ..u32(0x08074b50)
      ..u32(crc);
    if (zip64) {
      desc
        ..u64(size)
        ..u64(size);
    } else {
      desc
        ..u32(size)
        ..u32(size);
    }
    final db = desc.take();
    offset += db.length;
    yield db;

    // Central directory entry.
    final needOffset64 = headerOffset >= 0xFFFFFFFF;
    final extraLen = (zip64 ? 16 : 0) + (needOffset64 ? 8 : 0);
    final c = _Writer()
      ..u32(0x02014b50)
      ..u16(0x0300 | 45) // made by: Unix, v4.5
      ..u16(zip64 || needOffset64 ? 45 : 20)
      ..u16(0x0808)
      ..u16(0)
      ..u16(dosTime)
      ..u16(dosDate)
      ..u32(crc)
      ..u32(zip64 ? 0xFFFFFFFF : size)
      ..u32(zip64 ? 0xFFFFFFFF : size)
      ..u16(name.length)
      ..u16(extraLen == 0 ? 0 : extraLen + 4)
      ..u16(0)
      ..u16(0)
      ..u16(0)
      ..u32((isDir ? 0x41ED : 0x81A4) << 16) // unix mode 755 dir / 644 file
      ..u32(needOffset64 ? 0xFFFFFFFF : headerOffset)
      ..bytes(name);
    if (extraLen > 0) {
      c
        ..u16(0x0001)
        ..u16(extraLen);
      if (zip64) {
        c
          ..u64(size)
          ..u64(size);
      }
      if (needOffset64) c.u64(headerOffset);
    }
    central.add(c.take());
  }

  final cd = central.takeBytes();
  final cdOffset = offset;
  yield cd;
  offset += cd.length;

  final needZip64 = files.length >= 0xFFFF || cdOffset >= 0xFFFFFFFF || cd.length >= 0xFFFFFFFF;
  final end = _Writer();
  if (needZip64) {
    final zip64EndOffset = offset;
    end
      ..u32(0x06064b50)
      ..u64(44)
      ..u16(45)
      ..u16(45)
      ..u32(0)
      ..u32(0)
      ..u64(files.length)
      ..u64(files.length)
      ..u64(cd.length)
      ..u64(cdOffset)
      ..u32(0x07064b50)
      ..u32(0)
      ..u64(zip64EndOffset)
      ..u32(1);
  }
  end
    ..u32(0x06054b50)
    ..u16(0)
    ..u16(0)
    ..u16(needZip64 ? 0xFFFF : files.length)
    ..u16(needZip64 ? 0xFFFF : files.length)
    ..u32(needZip64 ? 0xFFFFFFFF : cd.length)
    ..u32(needZip64 ? 0xFFFFFFFF : cdOffset)
    ..u16(0);
  yield end.take();
}

/// Makes one file name safe as a ZIP path segment. Names come from the
/// shared folder's provider (SAF display names, iOS, desktop), which may
/// contain `/`, `\`, `..` or control characters; left alone those would let
/// the archive write outside the folder it is unzipped into ("zip slip").
String zipSafeName(String name) {
  var n = name.replaceAll(RegExp(r'[/\\\x00-\x1F\x7F]'), '_');
  if (RegExp(r'^\.+$').hasMatch(n)) n = n.replaceAll('.', '_');
  if (RegExp(r'^[A-Za-z]:').hasMatch(n)) n = n.replaceFirst(':', '_'); // C:foo on Windows
  return n.isEmpty ? '_' : n;
}

(int, int) _dos(DateTime t) {
  final d = t.year < 1980 ? DateTime(1980) : t;
  final time = (d.hour << 11) | (d.minute << 5) | (d.second ~/ 2);
  final date = ((d.year - 1980) << 9) | (d.month << 5) | d.day;
  return (time, date);
}

class _Writer {
  final _b = BytesBuilder();
  void u16(int v) => _b.add([v & 0xFF, (v >> 8) & 0xFF]);
  void u32(int v) => _b.add([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);
  void u64(int v) {
    u32(v & 0xFFFFFFFF);
    u32(v >> 32);
  }

  void bytes(List<int> b) => _b.add(b);
  Uint8List take() => _b.takeBytes();
}

final Uint32List _crcTable = () {
  final t = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    t[n] = c;
  }
  return t;
}();

int _crc32(List<int> data, int crc) {
  var c = crc ^ 0xFFFFFFFF;
  for (final b in data) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFF;
}
