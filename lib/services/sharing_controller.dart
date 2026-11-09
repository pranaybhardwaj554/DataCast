import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../models/device_identity.dart';
import '../models/peer_device.dart';
import '../server/datacast_server.dart';
import '../server/pin_auth.dart';
import 'discovery_service.dart';
import 'file_source.dart';
import 'network_utils.dart';
import 'platform_bridge.dart';
import 'saf_file_source.dart';
import 'settings_store.dart';

/// App state for sharing a folder. The UI listens to this and calls its
/// methods; it never talks to the server or native code directly.
class SharingController extends ChangeNotifier {
  SharingController({
    required this.settings,
    required this.bridge,
    required AssetLoader assets,
    DiscoveryService? discovery,
  })  : _discovery = discovery ?? BonsoirDiscoveryService(),
        _assets = assets; // ignore: prefer_initializing_formals

  final SettingsStore settings;
  final PlatformBridge bridge;
  final DiscoveryService _discovery;
  final AssetLoader _assets;

  late final PinAuth _auth;
  late DeviceIdentity _identity;
  DataCastServer? _server;
  FileSource? _source;
  StreamSubscription<void>? _peerSub;
  Timer? _networkTimer;
  bool _busy = false;

  // ------------------------------------------------------------------- state

  bool _initialized = false;
  bool get initialized => _initialized;

  bool get isSharing => _server?.isRunning ?? false;

  /// True while starting or stopping.
  bool get busy => _busy;

  /// Name of the shared folder, or null if none picked yet.
  String? get folderName => settings.folderName;
  bool get hasFolder => settings.folderUri != null;

  /// Address other devices open in their browser, e.g. `http://192.168.1.5:8080`.
  String? _url;
  String? get url => isSharing ? _url : null;

  String get pin => _auth.pin;

  int get connectedClients => _auth.connectedClients;

  String get deviceName => _identity.name;

  // Settings (persisted).
  /// Port the server tries first; the next free one is used if it's taken.
  int get port => settings.port;

  /// Port actually in use while sharing.
  int? get activePort => _server?.port;
  bool get allowZip => settings.allowZip;
  bool get newPinEachStart => settings.newPinEachStart;
  bool get keepScreenOn => settings.keepScreenOn;

  /// Other DataCast devices found on this network.
  List<PeerDevice> get peers => _discovery.peers;

  /// Last user-facing error, cleared on the next successful action.
  String? _error;
  String? get error => _error;

  // ------------------------------------------------------------------ actions

  Future<void> init() async {
    final id = settings.deviceId ?? _randomId();
    settings.deviceId = id;
    var name = settings.deviceName;
    if (name == null) {
      try {
        name = await bridge.deviceName();
      } catch (_) {
        name = 'DataCast device';
      }
    }
    _identity = DeviceIdentity(
      deviceId: id,
      name: name,
      platform: Platform.operatingSystem,
    );
    final pin = settings.pin;
    _auth = PinAuth(pin: pin != null && RegExp(r'^\d{4}$').hasMatch(pin) ? pin : null);
    settings.pin = _auth.pin;
    _auth.onClientsChanged = notifyListeners;
    bridge.onStopRequested = () => unawaited(stop());
    _peerSub = _discovery.changes.listen((_) => notifyListeners());
    _initialized = true;
    notifyListeners();
  }

  Future<void> pickFolder() async {
    try {
      final picked = await bridge.pickFolder();
      if (picked == null) return;
      settings
        ..folderUri = picked.uri
        ..folderName = picked.name;
      _source = null;
      _error = null;
      notifyListeners();
    } catch (e) {
      _fail('Could not open the folder picker: $e');
    }
  }

  Future<void> start() async {
    if (isSharing || _busy) return;
    final uri = settings.folderUri;
    if (uri == null) return _fail('Pick a folder to share first.');
    _setBusy(true);
    try {
      final ip = await findLocalIpv4();
      if (ip == null) {
        return _fail('Connect to Wi-Fi (or turn on your hotspot) to start sharing.');
      }
      if (Platform.isAndroid && !await bridge.hasFolderAccess(uri)) {
        settings.folderUri = null;
        return _fail('DataCast lost access to the folder. Please pick it again.');
      }
      if (settings.newPinEachStart) settings.pin = _auth.regeneratePin();
      _source = _makeSource(uri);
      final server = DataCastServer(
        auth: _auth,
        identity: () => _identity,
        source: () => _source,
        peers: () => _discovery.peers,
        assets: _assets,
        allowZip: () => settings.allowZip,
      );
      final port = await server.start(preferredPort: settings.port, localIp: ip);
      _server = server;
      _url = 'http://$ip:$port';
      _error = null;
      if (Platform.isAndroid) {
        await bridge.startForegroundService(text: 'Open $_url · PIN ${_auth.pin}');
      }
      try {
        await _discovery.start(_identity, port);
      } catch (e) {
        debugPrint('DataCast: discovery failed to start: $e');
      }
      _applyKeepScreenOn();
      _networkTimer = Timer.periodic(const Duration(seconds: 10), (_) => _checkNetwork());
    } catch (e) {
      await _teardown();
      _fail('Could not start sharing: $e');
    } finally {
      _setBusy(false);
    }
  }

  Future<void> stop() async {
    if (!isSharing || _busy) return;
    _setBusy(true);
    try {
      await _teardown();
    } finally {
      _setBusy(false);
    }
  }

  /// Picks a new PIN and signs out everyone currently connected.
  void regeneratePin() {
    settings.pin = _auth.regeneratePin();
    _refreshNotification();
    notifyListeners();
  }

  /// Saves settings. A new port applies the next time sharing starts.
  Future<void> updateSettings({
    String? deviceName,
    int? port,
    bool? allowZip,
    bool? newPinEachStart,
    bool? keepScreenOn,
  }) async {
    final trimmed = deviceName?.trim();
    final renamed = trimmed != null && trimmed.isNotEmpty && trimmed != _identity.name;
    if (renamed) {
      settings.deviceName = trimmed;
      _identity = _identity.copyWith(name: trimmed);
    }
    if (port != null) {
      if (port < 1024 || port > 65535) return _fail('Port must be between 1024 and 65535.');
      settings.port = port;
    }
    if (allowZip != null) settings.allowZip = allowZip;
    if (newPinEachStart != null) settings.newPinEachStart = newPinEachStart;
    if (keepScreenOn != null) {
      settings.keepScreenOn = keepScreenOn;
      _applyKeepScreenOn();
    }
    notifyListeners();
    if (renamed && isSharing) {
      try {
        await _discovery.start(_identity, _server!.port!);
      } catch (_) {}
    }
  }

  void _applyKeepScreenOn() {
    unawaited(bridge.setKeepScreenOn(isSharing && settings.keepScreenOn).catchError((_) {}));
  }

  // ------------------------------------------------------------------ helpers

  FileSource _makeSource(String uri) {
    final name = settings.folderName ?? 'Shared folder';
    if (uri.startsWith('content://')) return SafFileSource(bridge, uri, name);
    return IoFileSource(Directory(uri), displayName: name);
  }

  Future<void> _teardown() async {
    _networkTimer?.cancel();
    _networkTimer = null;
    await _discovery.stop();
    await _server?.stop();
    _server = null;
    await _source?.dispose();
    _source = null;
    _url = null;
    _auth.revokeAll();
    _applyKeepScreenOn();
    if (Platform.isAndroid) {
      try {
        await bridge.stopForegroundService();
      } catch (_) {}
    }
  }

  Future<void> _checkNetwork() async {
    final server = _server;
    if (server == null) return;
    final ip = await findLocalIpv4();
    if (ip == null) {
      _fail('Wi-Fi disconnected. Sharing stopped.');
      await stop();
      return;
    }
    final newUrl = 'http://$ip:${server.port}';
    if (newUrl != _url) {
      _url = newUrl;
      server.localIp = ip;
      _refreshNotification();
      try {
        await _discovery.start(_identity, server.port!);
      } catch (_) {}
      notifyListeners();
    }
  }

  void _refreshNotification() {
    if (isSharing && Platform.isAndroid) {
      unawaited(bridge.startForegroundService(text: 'Open $_url · PIN ${_auth.pin}'));
    }
  }

  void _setBusy(bool v) {
    _busy = v;
    notifyListeners();
  }

  void _fail(String message) {
    _error = message;
    notifyListeners();
  }

  static String _randomId() {
    final r = Random.secure();
    return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  @override
  void dispose() {
    unawaited(_teardown());
    _peerSub?.cancel();
    super.dispose();
  }
}
