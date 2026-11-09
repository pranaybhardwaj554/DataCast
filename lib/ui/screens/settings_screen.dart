import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/sharing_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.controller});
  final SharingController controller;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _name =
      TextEditingController(text: widget.controller.deviceName);
  late final TextEditingController _port =
      TextEditingController(text: widget.controller.port.toString());
  String? _portError;

  @override
  void dispose() {
    // Save after this frame: notifying listeners while the tree is being
    // torn down would trip a "markNeedsBuild during finalize" assert.
    final name = _name.text, port = _port.text, c = widget.controller;
    Future.microtask(() => _save(name, port, c));
    _name.dispose();
    _port.dispose();
    super.dispose();
  }

  void _saveTextFields() => _save(_name.text, _port.text, widget.controller);

  void _save(String rawName, String rawPort, SharingController c) {
    final name = rawName.trim();
    final port = int.tryParse(rawPort);
    final validPort = port != null && port >= 1024 && port <= 65535;
    if ((name.isNotEmpty && name != c.deviceName) || (validPort && port != c.port)) {
      c.updateSettings(
        deviceName: name.isNotEmpty ? name : null,
        port: validPort ? port : null,
      );
    }
  }

  void _validatePort(String v) {
    final p = int.tryParse(v);
    setState(() => _portError =
        (p == null || p < 1024 || p > 65535) ? 'Use a number from 1024 to 65535' : null);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final t = DcTheme.of(context);
    final text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: c,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            if (c.isSharing) ...[
              const NoticeBanner(text: 'Name and port changes apply the next time you start sharing.'),
              const SizedBox(height: 16),
            ],
            const SectionLabel('This device'),
            DcCard(
              padding: EdgeInsets.zero,
              child: Column(children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                  child: TextField(
                    controller: _name,
                    textInputAction: TextInputAction.done,
                    maxLength: 40,
                    decoration: const InputDecoration(
                      labelText: 'Name shown to visitors',
                      border: InputBorder.none,
                      counterText: '',
                    ),
                    style: text.titleMedium,
                    onSubmitted: (_) => _saveTextFields(),
                  ),
                ),
                const Divider(),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Row(children: [
                    Expanded(child: Text('Port', style: text.titleMedium?.copyWith(fontWeight: FontWeight.w400))),
                    SizedBox(
                      width: 96,
                      child: TextField(
                        controller: _port,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(5)],
                        textAlign: TextAlign.right,
                        decoration: const InputDecoration(border: InputBorder.none),
                        style: TextStyle(
                            fontFamily: AppTheme.display, fontWeight: FontWeight.w600, fontSize: 16, color: t.ink),
                        onChanged: _validatePort,
                        onSubmitted: (_) => _saveTextFields(),
                      ),
                    ),
                  ]),
                ),
                if (_portError != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Text(_portError!, style: const TextStyle(color: DcColors.danger, fontSize: 12)),
                    ),
                  ),
              ]),
            ),
            const SizedBox(height: 24),
            const SectionLabel('Access'),
            DcCard(
              padding: EdgeInsets.zero,
              child: Column(children: [
                _toggle(
                  title: 'New PIN every time',
                  subtitle: 'A fresh PIN each time you start sharing',
                  value: c.newPinEachStart,
                  onChanged: (v) => c.updateSettings(newPinEachStart: v),
                ),
                const Divider(),
                _toggle(
                  title: 'Allow folder download',
                  subtitle: 'Visitors can download a whole folder as .zip',
                  value: c.allowZip,
                  onChanged: (v) => c.updateSettings(allowZip: v),
                ),
              ]),
            ),
            const SizedBox(height: 24),
            const SectionLabel('While sharing'),
            DcCard(
              padding: EdgeInsets.zero,
              child: _toggle(
                title: 'Keep screen on',
                subtitle: 'Needed on iPhone, optional on Android',
                value: c.keepScreenOn,
                onChanged: (v) => c.updateSettings(keepScreenOn: v),
              ),
            ),
            const SizedBox(height: 32),
            Text('Files never leave your Wi-Fi. Visitors can view and download, never upload or delete.',
                textAlign: TextAlign.center, style: text.bodySmall),
          ],
        ),
      ),
    );
  }

  Widget _toggle({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      title: Text(title, style: const TextStyle(fontSize: 15)),
      subtitle: Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
      value: value,
      onChanged: onChanged,
    );
  }
}
