/// A DataCast device on the local network (including this one).
class PeerDevice {
  const PeerDevice({
    required this.deviceId,
    required this.name,
    required this.ip,
    required this.port,
    required this.platform,
    this.self = false,
  });

  final String deviceId;
  final String name;
  final String ip;
  final int port;
  final String platform;

  /// True for the device that served the request.
  final bool self;

  String get url => 'http://$ip:$port/';

  Map<String, Object?> toJson() => {
        'deviceId': deviceId,
        'name': name,
        'ip': ip,
        'port': port,
        'platform': platform,
        'url': url,
        'self': self,
      };
}
