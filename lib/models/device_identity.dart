/// Stable identity of this device, persisted across launches.
class DeviceIdentity {
  const DeviceIdentity({
    required this.deviceId,
    required this.name,
    required this.platform,
  });

  final String deviceId;
  final String name;

  /// `android`, `ios`, `macos`, ...
  final String platform;

  DeviceIdentity copyWith({String? name}) => DeviceIdentity(
        deviceId: deviceId,
        name: name ?? this.name,
        platform: platform,
      );
}
