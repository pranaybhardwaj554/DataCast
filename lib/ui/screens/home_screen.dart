import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../models/shared_file.dart';
import '../../services/sharing_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import 'settings_screen.dart';

/// The app's only top-level screen. Shows the idle "choose a folder" state,
/// or the live sharing panel (link, QR, PIN, visitors) while sharing.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.controller});
  final SharingController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: controller.isSharing
              ? _SharingView(key: const ValueKey('sharing'), controller: controller)
              : _IdleView(key: const ValueKey('idle'), controller: controller),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Idle
// ---------------------------------------------------------------------------

class _IdleView extends StatefulWidget {
  const _IdleView({super.key, required this.controller});
  final SharingController controller;

  @override
  State<_IdleView> createState() => _IdleViewState();
}

class _IdleViewState extends State<_IdleView> {
  bool _busy = false;
  // Which tab is shown. Starts on whatever is currently selected; switching
  // tabs changes nothing until the user picks something in that tab.
  late ShareMode _mode = widget.controller.shareMode;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final t = DcTheme.of(context);
    final text = Theme.of(context).textTheme;
    final folderPicked = c.hasSelection && c.shareMode == ShareMode.folder;
    final filesPicked = c.hasSelection && c.shareMode == ShareMode.files && c.sharedFiles.isNotEmpty;
    final ready = _mode == ShareMode.folder ? folderPicked : filesPicked;
    final Future<void> Function() pick = _mode == ShareMode.folder ? c.pickFolder : c.pickFiles;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              const BrandMark(),
              const SizedBox(width: 10),
              Text('DataCast',
                  style: TextStyle(
                      fontFamily: AppTheme.display,
                      fontWeight: FontWeight.w700,
                      fontSize: 22,
                      letterSpacing: -0.4,
                      color: t.ink)),
              const Spacer(),
              IconButton.outlined(
                tooltip: 'Settings',
                icon: const Icon(Icons.settings_outlined),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => SettingsScreen(controller: c),
                )),
              ),
            ]),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(top: 24),
                children: [
                  Text(_mode == ShareMode.folder ? 'Share a folder' : 'Share files',
                      style: text.headlineMedium?.copyWith(fontSize: 34, letterSpacing: -1)),
                  const SizedBox(height: 10),
                  Text('Wi-Fi  ·  Link  ·  PIN',
                      style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
                  const SizedBox(height: 24),
                  _ModeSwitch(
                    mode: _mode,
                    onChanged: _busy ? null : (m) => setState(() => _mode = m),
                  ),
                  const SizedBox(height: 14),
                  if (_mode == ShareMode.folder)
                    DcCard(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        const SectionLabel('Folder'),
                        Row(children: [
                          Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                                color: folderPicked ? t.accentSoft : t.surface2,
                                borderRadius: BorderRadius.circular(12)),
                            child: Icon(Icons.folder_outlined,
                                color: folderPicked ? t.accent : t.ink2, size: 24),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              folderPicked ? (c.folderName ?? 'Folder') : 'No folder yet',
                              style: folderPicked ? text.titleMedium : text.bodyMedium,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ]),
                        const SizedBox(height: 14),
                        OutlinedButton.icon(
                          onPressed: _busy ? null : () => _run(c.pickFolder),
                          icon: Icon(folderPicked ? Icons.swap_horiz_rounded : Icons.create_new_folder_outlined),
                          label: Text(folderPicked ? 'Change folder' : 'Choose folder'),
                        ),
                      ]),
                    )
                  else
                    DcCard(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        SectionLabel(filesPicked ? _filesSummary(c.sharedFiles) : 'Files'),
                        if (!filesPicked)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text('No files yet', style: text.bodyMedium),
                          ),
                        if (filesPicked)
                          for (var i = 0; i < c.sharedFiles.length; i++)
                            _PickedFileRow(
                              file: c.sharedFiles[i],
                              onRemove: _busy ? null : () => c.removeSharedFile(i),
                            ),
                        const SizedBox(height: 10),
                        OutlinedButton.icon(
                          onPressed: _busy ? null : () => _run(c.pickFiles),
                          icon: Icon(filesPicked ? Icons.swap_horiz_rounded : Icons.note_add_outlined),
                          label: Text(filesPicked ? 'Choose other files' : 'Choose files'),
                        ),
                      ]),
                    ),
                  if (c.error != null) ...[
                    const SizedBox(height: 16),
                    NoticeBanner(text: c.error!, isError: true),
                  ],
                ],
              ),
            ),
            FilledButton.icon(
              onPressed: _busy ? null : () => _run(ready ? c.start : pick),
              icon: _busy
                  ? const SizedBox(
                      width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : Icon(ready ? Icons.wifi_tethering_rounded : Icons.add_rounded),
              label: Text(ready ? 'Start sharing' : (_mode == ShareMode.folder ? 'Choose a folder' : 'Choose files')),
            ),
            const SizedBox(height: 10),
            Text('View & download only',
                textAlign: TextAlign.center, style: text.bodySmall),
          ]),
        ),
      ),
    );
  }
}

String _filesSummary(List<SharedFile> files) {
  final total = files.fold<int>(0, (s, f) => s + f.size);
  return '${files.length} ${files.length == 1 ? 'file' : 'files'} · ${formatBytes(total)}';
}

String formatBytes(int b) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = b.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return i == 0 ? '$b B' : '${v.toStringAsFixed(v < 10 ? 1 : 0)} ${units[i]}';
}

/// Folder | Files segmented switch.
class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({required this.mode, required this.onChanged});
  final ShareMode mode;
  final ValueChanged<ShareMode>? onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: SegmentedButton<ShareMode>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: ShareMode.folder, icon: Icon(Icons.folder_outlined), label: Text('Folder')),
          ButtonSegment(value: ShareMode.files, icon: Icon(Icons.description_outlined), label: Text('Files')),
        ],
        selected: {mode},
        onSelectionChanged: onChanged == null ? null : (s) => onChanged!(s.first),
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(0, 44)),
          textStyle: const WidgetStatePropertyAll(TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
        ),
      ),
    );
  }
}

/// One picked file with a remove button.
class _PickedFileRow extends StatelessWidget {
  const _PickedFileRow({required this.file, required this.onRemove});
  final SharedFile file;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final t = DcTheme.of(context);
    final text = Theme.of(context).textTheme;
    return SizedBox(
      height: 52,
      child: Row(children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(color: t.surface2, borderRadius: BorderRadius.circular(9)),
          child: Icon(Icons.description_outlined, size: 18, color: t.ink2),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
            Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: t.ink)),
            Text(formatBytes(file.size), style: text.bodySmall),
          ]),
        ),
        IconButton(
          tooltip: 'Remove ${file.name}',
          icon: const Icon(Icons.close_rounded, size: 20),
          onPressed: onRemove,
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Sharing
// ---------------------------------------------------------------------------

class _SharingView extends StatelessWidget {
  const _SharingView({super.key, required this.controller});
  final SharingController controller;

  bool get _isIos => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  Future<void> _confirmStop(BuildContext context) async {
    final clients = controller.connectedClients;
    if (clients > 0) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Stop sharing?'),
          content: Text(
              '$clients ${clients == 1 ? 'device is' : 'devices are'} connected. Downloads in progress will stop.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep sharing')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Stop')),
          ],
        ),
      );
      if (ok != true) return;
    }
    await controller.stop();
  }

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final t = DcTheme.of(context);
    final text = Theme.of(context).textTheme;
    final url = c.url ?? '';
    final shortUrl = url.replaceFirst(RegExp(r'^https?://'), '').replaceFirst(RegExp(r'/$'), '');
    final clients = c.connectedClients;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmStop(context);
      },
      child: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Sharing',
                        style: TextStyle(
                            fontFamily: AppTheme.display,
                            fontWeight: FontWeight.w700,
                            fontSize: 22,
                            letterSpacing: -0.4,
                            color: t.ink)),
                    Text(c.folderName ?? '', style: text.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ]),
                ),
                const LiveBadge(),
              ]),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.only(top: 16, bottom: 12),
                  children: [
                    DcCard(
                      padding: const EdgeInsets.all(18),
                      child: Column(children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Colors.white, // QR must stay dark-on-white to scan
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: t.line),
                          ),
                          child: Semantics(
                            label: 'QR code for $shortUrl',
                            child: QrImageView(
                              data: url,
                              size: 168,
                              padding: EdgeInsets.zero,
                              eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: DcColors.ink),
                              dataModuleStyle: const QrDataModuleStyle(
                                  dataModuleShape: QrDataModuleShape.square, color: DcColors.ink),
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),
                        Text('Scan with a phone camera, or open this link on any device on the same Wi-Fi.',
                            textAlign: TextAlign.center, style: text.bodySmall),
                        const SizedBox(height: 14),
                        Container(
                          padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
                          decoration:
                              BoxDecoration(color: t.surface2, borderRadius: BorderRadius.circular(12)),
                          child: Row(children: [
                            Expanded(
                              child: SelectableText(shortUrl,
                                  maxLines: 1,
                                  style: TextStyle(
                                      fontFamily: AppTheme.display,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 17,
                                      color: t.ink)),
                            ),
                            IconButton.filled(
                              tooltip: 'Copy link',
                              icon: const Icon(Icons.copy_rounded, size: 18),
                              onPressed: () {
                                Clipboard.setData(ClipboardData(text: url));
                                ScaffoldMessenger.of(context)
                                    .showSnackBar(const SnackBar(content: Text('Link copied')));
                              },
                            ),
                          ]),
                        ),
                      ]),
                    ),
                    const SizedBox(height: 14),
                    DcCard(
                      padding: const EdgeInsets.fromLTRB(18, 14, 14, 14),
                      child: Row(children: [
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            const SectionLabel('PIN for visitors'),
                            Semantics(
                              label: 'PIN ${c.pin.split('').join(' ')}',
                              excludeSemantics: true,
                              child: Text(c.pin.isEmpty ? '----' : c.pin,
                                  style: TextStyle(
                                      fontFamily: AppTheme.display,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 34,
                                      letterSpacing: 9,
                                      color: t.ink)),
                            ),
                          ]),
                        ),
                        OutlinedButton.icon(
                          onPressed: c.regeneratePin,
                          icon: const Icon(Icons.refresh_rounded, size: 18),
                          label: const Text('New'),
                        ),
                      ]),
                    ),
                    const SizedBox(height: 18),
                    SectionLabel('Connected now · $clients'),
                    DcCard(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      child: Row(children: [
                        Container(
                          width: 32,
                          height: 32,
                          decoration:
                              BoxDecoration(color: t.accentSoft, borderRadius: BorderRadius.circular(8)),
                          child: Icon(Icons.devices_rounded, size: 18, color: t.accent),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            clients == 0
                                ? 'Waiting for someone to open the link'
                                : '$clients ${clients == 1 ? 'device has' : 'devices have'} unlocked with your PIN',
                            style: text.bodyMedium,
                          ),
                        ),
                      ]),
                    ),
                    if (_isIos) ...[
                      const SizedBox(height: 14),
                      const NoticeBanner(
                        text:
                            'Keep DataCast open on screen. iPhone pauses sharing when you switch apps or lock the phone.',
                      ),
                    ],
                    if (c.error != null) ...[
                      const SizedBox(height: 14),
                      NoticeBanner(text: c.error!, isError: true),
                    ],
                  ],
                ),
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                  side: BorderSide(color: t.ink, width: 1.5),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                ),
                onPressed: () => _confirmStop(context),
                icon: const Icon(Icons.stop_rounded),
                label: const Text('Stop sharing'),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
