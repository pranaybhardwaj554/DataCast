import 'dart:io';

/// Best guess at this device's Wi-Fi / hotspot IPv4 address, or null when not
/// on a local network.
Future<String?> findLocalIpv4() async {
  final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
  int score(NetworkInterface i) {
    final n = i.name.toLowerCase();
    if (n.startsWith('wlan') || n.startsWith('en') || n.startsWith('wl')) return 0;
    if (n.contains('ap') || n.startsWith('swlan')) return 1; // hotspot
    if (n.startsWith('eth')) return 2;
    if (n.startsWith('rmnet') || n.startsWith('pdp') || n.startsWith('ccmni')) return 9; // mobile data
    return 5;
  }

  bool isPrivate(InternetAddress a) {
    final b = a.rawAddress;
    return b[0] == 10 || (b[0] == 172 && b[1] >= 16 && b[1] <= 31) || (b[0] == 192 && b[1] == 168);
  }

  final candidates = [
    for (final i in interfaces)
      for (final a in i.addresses)
        if (isPrivate(a)) (i, a),
  ]..sort((x, y) => score(x.$1).compareTo(score(y.$1)));
  return candidates.isEmpty ? null : candidates.first.$2.address;
}
