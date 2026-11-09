import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/shared_file.dart';

/// Persisted app settings.
class SettingsStore {
  SettingsStore(this._prefs);

  static Future<SettingsStore> load() async => SettingsStore(await SharedPreferences.getInstance());

  final SharedPreferences _prefs;

  String? get deviceId => _prefs.getString('deviceId');
  set deviceId(String? v) => _set('deviceId', v);

  String? get deviceName => _prefs.getString('deviceName');
  set deviceName(String? v) => _set('deviceName', v);

  /// Android: a `content://` tree URI. Elsewhere: a filesystem path.
  String? get folderUri => _prefs.getString('folderUri');
  set folderUri(String? v) => _set('folderUri', v);

  String? get folderName => _prefs.getString('folderName');
  set folderName(String? v) => _set('folderName', v);

  String? get pin => _prefs.getString('pin');
  set pin(String? v) => _set('pin', v);

  ShareMode get shareMode => _prefs.getString('shareMode') == 'files' ? ShareMode.files : ShareMode.folder;
  set shareMode(ShareMode v) => _prefs.setString('shareMode', v.name);

  List<SharedFile> get sharedFiles {
    final raw = _prefs.getString('sharedFiles');
    if (raw == null) return const [];
    try {
      return [for (final e in jsonDecode(raw) as List) SharedFile.fromJson(Map<String, Object?>.from(e as Map))];
    } on Object {
      return const [];
    }
  }

  set sharedFiles(List<SharedFile> v) => _prefs.setString('sharedFiles', jsonEncode([for (final f in v) f.toJson()]));

  /// True while sharing; still true on launch if the app was killed mid-share.
  bool get wasSharing => _prefs.getBool('wasSharing') ?? false;
  set wasSharing(bool v) => _prefs.setBool('wasSharing', v);

  int get port => _prefs.getInt('port') ?? 8080;
  set port(int v) => _prefs.setInt('port', v);

  bool get allowZip => _prefs.getBool('allowZip') ?? false;
  set allowZip(bool v) => _prefs.setBool('allowZip', v);

  bool get newPinEachStart => _prefs.getBool('newPinEachStart') ?? true;
  set newPinEachStart(bool v) => _prefs.setBool('newPinEachStart', v);

  bool get keepScreenOn => _prefs.getBool('keepScreenOn') ?? true;
  set keepScreenOn(bool v) => _prefs.setBool('keepScreenOn', v);

  void _set(String key, String? v) => v == null ? _prefs.remove(key) : _prefs.setString(key, v);
}
