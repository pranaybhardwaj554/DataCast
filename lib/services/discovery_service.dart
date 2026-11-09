import 'dart:async';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/foundation.dart';

import '../models/device_identity.dart';
import '../models/peer_device.dart';

/// mDNS service type every DataCast device advertises.
const datacastServiceType = '_datacast._tcp';

/// Finds other DataCast devices on the local network and advertises this one.
abstract class DiscoveryService {
  List<PeerDevice> get peers;

  /// Fires whenever [peers] changes.
  Stream<void> get changes;

  Future<void> start(DeviceIdentity identity, int port);
  Future<void> stop();
}

/// [DiscoveryService] built on the `bonsoir` package (Android NSD / Apple
/// Bonjour).
class BonsoirDiscoveryService implements DiscoveryService {
  BonsoirBroadcast? _broadcast;
  BonsoirDiscovery? _discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? _sub;
  String? _selfId;
  final Map<String, PeerDevice> _peers = {}; // keyed by mDNS service name
  final _changes = StreamController<void>.broadcast();

  @override
  List<PeerDevice> get peers => _peers.values.toList(growable: false);

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<void> start(DeviceIdentity identity, int port) async {
    await stop();
    _selfId = identity.deviceId;

    final broadcast = BonsoirBroadcast(
      service: BonsoirService(
        name: identity.name,
        type: datacastServiceType,
        port: port,
        attributes: {'id': identity.deviceId, 'pf': identity.platform, 'v': '1'},
      ),
    );
    await broadcast.initialize();
    await broadcast.start();
    _broadcast = broadcast;

    final discovery = BonsoirDiscovery(type: datacastServiceType);
    await discovery.initialize();
    _sub = discovery.eventStream?.listen((event) => _onEvent(discovery, event));
    await discovery.start();
    _discovery = discovery;
  }

  void _onEvent(BonsoirDiscovery discovery, BonsoirDiscoveryEvent event) {
    switch (event) {
      case BonsoirDiscoveryServiceFoundEvent(:final service):
        if (service.attributes['id'] == _selfId) return;
        discovery.serviceResolver.resolveService(service);
      case BonsoirDiscoveryServiceResolvedEvent(:final service):
      case BonsoirDiscoveryServiceUpdatedEvent(:final service):
        _upsert(service);
      case BonsoirDiscoveryServiceLostEvent(:final service):
        if (_peers.remove(service.name) != null) _changes.add(null);
      default:
        break;
    }
  }

  void _upsert(BonsoirService service) {
    final id = service.attributes['id'];
    if (id == null || id == _selfId) return;
    final ip = service.hostAddresses.firstWhere(
      (a) => InternetAddress.tryParse(a)?.type == InternetAddressType.IPv4,
      orElse: () => '',
    );
    if (ip.isEmpty) return;
    _peers[service.name] = PeerDevice(
      deviceId: id,
      name: service.name,
      ip: ip,
      port: service.port,
      platform: service.attributes['pf'] ?? 'unknown',
    );
    _changes.add(null);
  }

  @override
  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    try {
      await _discovery?.stop();
      await _broadcast?.stop();
    } catch (e) {
      debugPrint('DataCast discovery stop failed: $e');
    }
    _discovery = null;
    _broadcast = null;
    if (_peers.isNotEmpty) {
      _peers.clear();
      _changes.add(null);
    }
  }
}
