import 'package:flutter/services.dart';

import '../models/shared_file.dart';

/// A folder chosen in the system picker.
class PickedFolder {
  const PickedFolder(this.uri, this.name);
  final String uri;
  final String name;
}

/// Dart side of the native Android code in `android/app/src/main/kotlin`.
///
/// One method channel covers the folder picker, Storage Access Framework
/// reads, the foreground service and device info.
class PlatformBridge {
  PlatformBridge({MethodChannel? channel}) : _channel = channel ?? const MethodChannel('datacast/native') {
    _channel.setMethodCallHandler(_onNativeCall);
  }

  final MethodChannel _channel;

  /// Called when the user taps "Stop" in the sharing notification.
  void Function()? onStopRequested;

  Future<dynamic> _onNativeCall(MethodCall call) async {
    if (call.method == 'stopRequested') onStopRequested?.call();
    return null;
  }

  Future<PickedFolder?> pickFolder() async {
    final r = await _channel.invokeMapMethod<String, Object?>('pickFolder');
    if (r == null) return null;
    return PickedFolder(r['uri'] as String, r['name'] as String);
  }

  /// Opens the system file picker (multi-select). Returns null if cancelled.
  Future<List<SharedFile>?> pickFiles() async {
    final r = await _channel.invokeListMethod<Object?>('pickFiles');
    if (r == null) return null;
    return [for (final e in r) SharedFile.fromJson(Map<String, Object?>.from(e as Map))];
  }

  /// Whether the app still has read access to a picked file.
  Future<bool> hasDocAccess(String uri) async =>
      await _channel.invokeMethod<bool>('hasDocAccess', {'uri': uri}) ?? false;

  /// Current metadata of a single picked file ({name, size, mime, modified}).
  Future<Map<String, Object?>?> docStat(String uri) =>
      _channel.invokeMapMethod<String, Object?>('docStat', {'uri': uri});

  Future<int?> docOpenFd(String uri) => _channel.invokeMethod<int>('docOpenFd', {'uri': uri});

  Future<Uint8List> docReadChunk(String uri, int offset, int length) async =>
      await _channel.invokeMethod<Uint8List>('docReadChunk', {'uri': uri, 'offset': offset, 'length': length}) ??
      Uint8List(0);

  /// Whether the app still has read access to a previously picked folder.
  Future<bool> hasFolderAccess(String uri) async =>
      await _channel.invokeMethod<bool>('hasFolderAccess', {'uri': uri}) ?? false;

  Future<String> deviceName() async => await _channel.invokeMethod<String>('deviceName') ?? 'Android device';

  Future<void> startForegroundService({required String text}) => _channel.invokeMethod('startService', {'text': text});

  /// Keeps the screen from turning off while the app is visible.
  Future<void> setKeepScreenOn(bool on) => _channel.invokeMethod('setKeepScreenOn', {'on': on});

  Future<void> stopForegroundService() => _channel.invokeMethod('stopService');

  // ------------------------------------------------------------- storage (SAF)

  Future<List<Map<String, Object?>>?> list(String treeUri, String path) async {
    final r = await _channel.invokeListMethod<Object?>('list', {'uri': treeUri, 'path': path});
    return r?.map((e) => Map<String, Object?>.from(e as Map)).toList();
  }

  Future<Map<String, Object?>?> stat(String treeUri, String path) =>
      _channel.invokeMapMethod<String, Object?>('stat', {'uri': treeUri, 'path': path});

  /// Opens a file and returns a raw file descriptor owned by the caller, who
  /// must hand it back with [closeFd].
  Future<int?> openFd(String treeUri, String path) =>
      _channel.invokeMethod<int>('openFd', {'uri': treeUri, 'path': path});

  Future<void> closeFd(int fd) => _channel.invokeMethod('closeFd', {'fd': fd});

  /// Slow fallback for providers whose files cannot be opened as a descriptor.
  Future<Uint8List> readChunk(String treeUri, String path, int offset, int length) async =>
      await _channel.invokeMethod<Uint8List>('readChunk', {
        'uri': treeUri,
        'path': path,
        'offset': offset,
        'length': length,
      }) ??
      Uint8List(0);
}
