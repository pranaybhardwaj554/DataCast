import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'services/platform_bridge.dart';
import 'services/settings_store.dart';
import 'services/sharing_controller.dart';
import 'ui/screens/home_screen.dart';
import 'ui/theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = SharingController(
    settings: await SettingsStore.load(),
    bridge: PlatformBridge(),
    assets: loadWebAsset,
  );
  await controller.init();
  runApp(DataCastApp(controller: controller));
}

/// Serves the browser UI bundled under `assets/web/`.
Future<List<int>?> loadWebAsset(String path) async {
  try {
    final data = await rootBundle.load('assets/web/$path');
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } catch (_) {
    return null;
  }
}

class DataCastApp extends StatelessWidget {
  const DataCastApp({super.key, required this.controller});

  final SharingController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DataCast',
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: HomeScreen(controller: controller),
    );
  }
}
