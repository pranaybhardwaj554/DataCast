import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/widgets.dart';

import '../models/device_identity.dart';
import '../models/peer_device.dart';
import '../models/shared_file.dart';
import '../server/datacast_server.dart';
import '../server/pin_auth.dart';
import 'discovery_service.dart';
import 'file_source.dart';
import 'network_utils.dart';
import 'platform_bridge.dart';
import 'saf_file_source.dart';
import 'selection_file_source.dart';
import 'settings_store.dart';

/// App state for sharing a folder. The UI listens to this and calls its
/// methods; it never talks to the server or native code directly.
class SharingController extends ChangeNotifier {
  SharingController({
    required this.settings,
    required this.bridge,
    required AssetLoader assets,
    DiscoveryService? discovery,
  }) : _discovery = discovery ?? BonsoirDiscoveryService(),
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
  AppLifecycleListener? _lifecycle;
  int _missedNetworkChecks = 0;
  int _lastClientCount = 0;
  bool _busy = false;

  // ------------------------------------------------------------------- state

  bool _initialized = false;
  bool get initialized => _initialized;

  bool get isSharing => _server?.isRunning ?? false;

  /// True while starting or stopping.
  bool get busy => _busy;

  /// Whether a whole folder or individually picked files are shared.
  ShareMode get shareMode => settings.shareMode;

  /// Files picked in [ShareMode.files] (empty in folder mode).
  List<SharedFile> get sharedFiles => shareMode == ShareMode.files ? settings.sharedFiles : const [];

  /// What is being shared: the folder's name, or e.g. "3 files". Null if
  /// nothing is selected yet.
  String? get folderName {
    if (shareMode == ShareMode.files) {
      final n = settings.sharedFiles.length;
      return n == 0 ? null : (n == 1 ? '1 file' : '$n files');
    }
    return settings.folderUri == null ? null : settings.folderName;
  }

  /// True when a folder or at least one file is selected.
  bool get hasSelection => shareMode == ShareMode.files ? settings.sharedFiles.isNotEmpty : settings.folderUri != null;

  /// Same as [hasSelection]; kept for older UI code.
  bool get hasFolder => hasSelection;

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

  /// True when this device has a usable Wi-Fi or hotspot address. Updated on
  /// app resume and every 5 seconds.
  bool _hasNetwork = false;
  bool get hasNetwork => _hasNetwork;

  /// Why sharing last ended on its own; null after the user tapped Stop.
  StopReason? _stopReason;
  StopReason? get stopReason => _stopReason;

  void clearStopReason() {
    if (_stopReason == null) return;
    _stopReason = null;
    notifyListeners();
  }

  /// True after the sharing address changed (e.g. the phone joined another
  /// network) until the UI calls [acknowledgeUrlChange].
  bool _urlChanged = false;
  bool get urlChanged => _urlChanged;

  void acknowledgeUrlChange() {
    if (!_urlChanged) return;
    _urlChanged = false;
    notifyListeners();
  }

  /// Opens the system Wi-Fi settings.
  Future<void> openWifiSettings() async {
    try {
      await bridge.openWifiSettings();
    } catch (_) {}
  }

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
    _identity = DeviceIdentity(deviceId: id, name: name, platform: Platform.operatingSystem);
    final pin = settings.pin;
    _auth = PinAuth(pin: pin != null && RegExp(r'^\d{4}$').hasMatch(pin) ? pin : null);
    settings.pin = _auth.pin;
    _auth.onClientsChanged = notifyListeners;
    bridge.onStopRequested = () => unawaited(_stopWith(StopReason.system));
    _peerSub = _discovery.changes.listen((_) => notifyListeners());
    // The process died while sharing last time (OS killed it, crash, ...).
    if (settings.wasSharing) {
      settings.wasSharing = false;
      _stopReason = StopReason.system;
    }
    _hasNetwork = await findLocalIpv4() != null;
    _networkTimer = Timer.periodic(const Duration(seconds: 5), (_) => unawaited(refreshNetwork()));
    _lifecycle = AppLifecycleListener(onResume: () => unawaited(refreshNetwork()));
    _initialized = true;
    notifyListeners();
  }

  Future<void> pickFolder() async {
    try {
      final picked = await bridge.pickFolder();
      if (picked == null) return;
      settings
        ..folderUri = picked.uri
        ..folderName = picked.name
        ..shareMode = ShareMode.folder;
      _error = null;
      _refreshSource();
      notifyListeners();
    } catch (e) {
      _fail('Could not open the folder picker: $e');
    }
  }

  /// Picks one or more files to share instead of a folder. Replaces the
  /// current selection.
  Future<void> pickFiles() async {
    try {
      final picked = await bridge.pickFiles();
      if (picked == null || picked.isEmpty) return;
      settings
        ..sharedFiles = picked
        ..shareMode = ShareMode.files;
      _error = null;
      _refreshSource();
      notifyListeners();
    } catch (e) {
      _fail('Could not open the file picker: $e');
    }
  }

  /// Stops sharing one picked file. Takes effect immediately, even while
  /// sharing. Removing the last file stops sharing.
  Future<void> removeSharedFile(int index) async {
    final files = [...settings.sharedFiles];
    if (shareMode != ShareMode.files || index < 0 || index >= files.length) return;
    files.removeAt(index);
    settings.sharedFiles = files;
    if (files.isEmpty && isSharing) {
      await stop();
    } else {
      _refreshSource();
    }
    notifyListeners();
  }

  Future<void> start() async {
    if (isSharing || _busy) return;
    if (!hasSelection) return _fail('Pick a folder or some files to share first.');
    _setBusy(true);
    try {
      final ip = await findLocalIpv4();
      if (ip == null) {
        return _fail('Connect to Wi-Fi (or turn on your hotspot) to start sharing.');
      }
      if (!await _checkAccess()) return;
      if (settings.newPinEachStart) settings.pin = _auth.regeneratePin();
      _source = _makeSource();
      final server = DataCastServer(
        auth: _auth,
        identity: () => _identity,
        source: () => _source,
        peers: () => _discovery.peers,
        assets: _assets,
        allowZip: () => settings.allowZip,
        mode: () => shareMode.name,
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
      _stopReason = null;
      _urlChanged = false;
      _missedNetworkChecks = 0;
      settings.wasSharing = true;
    } catch (e) {
      await _teardown();
      _fail('Could not start sharing: $e');
    } finally {
      _setBusy(false);
    }
  }

  /// Stops sharing because the user asked to.
  Future<void> stop() => _stopWith(null);

  Future<void> _stopWith(StopReason? reason) async {
    if (!isSharing || _busy) return;
    _setBusy(true);
    try {
      await _teardown();
      _stopReason = reason;
      _urlChanged = false;
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

  /// Drops anything the app can no longer read. Returns false (with an
  /// error set) if nothing is left to share.
  Future<bool> _checkAccess() async {
    if (!Platform.isAndroid) return true;
    if (shareMode == ShareMode.files) {
      final files = settings.sharedFiles;
      final ok = <SharedFile>[];
      for (final f in files) {
        if (!f.uri.startsWith('content://') || await bridge.hasDocAccess(f.uri)) ok.add(f);
      }
      if (ok.length != files.length) settings.sharedFiles = ok;
      if (ok.isEmpty) {
        _fail('DataCast lost access to those files. Please pick them again.');
        return false;
      }
      return true;
    }
    final uri = settings.folderUri!;
    if (uri.startsWith('content://') && !await bridge.hasFolderAccess(uri)) {
      settings.folderUri = null;
      _fail('DataCast lost access to the folder. Please pick it again.');
      return false;
    }
    return true;
  }

  /// Swaps the shared content in place while sharing.
  void _refreshSource() {
    if (isSharing && hasSelection) _source = _makeSource();
  }

  FileSource _makeSource() {
    if (shareMode == ShareMode.files) {
      return SelectionFileSource(bridge, settings.sharedFiles, displayName: folderName ?? 'Shared files');
    }
    final uri = settings.folderUri!;
    final name = settings.folderName ?? 'Shared folder';
    if (uri.startsWith('content://')) return SafFileSource(bridge, uri, name);
    return IoFileSource(Directory(uri), displayName: name);
  }

  Future<void> _teardown() async {
    settings.wasSharing = false;
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

  /// Re-checks Wi-Fi (and, while sharing, access to the shared items).
  Future<void> refreshNetwork() async {
    // Runs every 5 s: also lets the "connected" count drop when a browser
    // simply goes away (no request marks that moment).
    final clients = _auth.connectedClients;
    if (clients != _lastClientCount) {
      _lastClientCount = clients;
      notifyListeners();
    }
    if (_busy) return;
    final ip = await findLocalIpv4();
    final had = _hasNetwork;
    _hasNetwork = ip != null;
    final server = _server;
    if (server == null) {
      if (had != _hasNetwork) notifyListeners();
      return;
    }
    if (ip == null) {
      // Allow one missed check so a brief blip doesn't stop sharing.
      if (++_missedNetworkChecks >= 2) {
        await _stopWith(StopReason.wifiLost);
      } else if (had) {
        notifyListeners();
      }
      return;
    }
    _missedNetworkChecks = 0;
    if (!await _stillHasAccess()) {
      await _stopWith(StopReason.accessLost);
      return;
    }
    final newUrl = 'http://$ip:${server.port}';
    if (newUrl != _url) {
      _url = newUrl;
      _urlChanged = true;
      server.localIp = ip;
      _refreshNotification();
      try {
        await _discovery.start(_identity, server.port!);
      } catch (_) {}
      notifyListeners();
    } else if (had != _hasNetwork) {
      notifyListeners();
    }
  }

  Future<bool> _stillHasAccess() async {
    if (!Platform.isAndroid) return true;
    try {
      if (shareMode == ShareMode.folder) {
        final uri = settings.folderUri;
        return uri == null || !uri.startsWith('content://') || await bridge.hasFolderAccess(uri);
      }
      final files = settings.sharedFiles;
      final ok = <SharedFile>[];
      for (final f in files) {
        if (!f.uri.startsWith('content://') || await bridge.hasDocAccess(f.uri)) ok.add(f);
      }
      if (ok.length != files.length) {
        settings.sharedFiles = ok;
        _refreshSource();
        notifyListeners();
      }
      return ok.isNotEmpty;
    } catch (_) {
      return true; // don't stop sharing because a check itself failed
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
    _networkTimer?.cancel();
    _lifecycle?.dispose();
    unawaited(_teardown());
    _peerSub?.cancel();
    super.dispose();
  }
}
