import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../models/shared_file.dart';
import '../../services/sharing_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import '../widgets/motion.dart';
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
        final Widget screen;
        if (controller.isSharing) {
          screen = _SharingView(key: const ValueKey('sharing'), controller: controller);
        } else if (!controller.hasNetwork) {
          screen = _NoWifiView(key: const ValueKey('nowifi'), controller: controller);
        } else {
          screen = _IdleView(key: const ValueKey('idle'), controller: controller);
        }
        return FadeThroughSwitcher(duration: DcMotion.screen, dy: 0.04, child: screen);
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
                  FadeThroughSwitcher(
                    alignment: Alignment.centerLeft,
                    duration: DcMotion.quick,
                    child: Text(_mode == ShareMode.folder ? 'Share a folder' : 'Share files',
                        key: ValueKey(_mode),
                        style: text.headlineMedium?.copyWith(fontSize: 34, letterSpacing: -1)),
                  ),
                  const SizedBox(height: 10),
                  Text('Wi-Fi  ·  Link  ·  PIN',
                      style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
                  const SizedBox(height: 24),
                  Reveal(
                    visible: c.stopReason != null,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: c.stopReason == null
                          ? const SizedBox.shrink()
                          : _StoppedCard(reason: c.stopReason!, onDismiss: c.clearStopReason),
                    ),
                  ),
                  _ModeSwitch(
                    mode: _mode,
                    onChanged: _busy ? null : (m) => setState(() => _mode = m),
                  ),
                  const SizedBox(height: 14),
                  AnimatedSize(
                    duration: DcMotion.of(context, DcMotion.medium),
                    curve: DcMotion.resize,
                    alignment: Alignment.topCenter,
                    child: FadeThroughSwitcher(
                      duration: DcMotion.medium,
                      dy: 0.02,
                      child: _mode == ShareMode.folder
                  ? DcCard(
                      key: const ValueKey('folder-card'),
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
                  : DcCard(
                      key: const ValueKey('files-card'),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        SectionLabel(filesPicked ? _filesSummary(c.sharedFiles) : 'Files'),
                        if (!filesPicked)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text('No files yet', style: text.bodyMedium),
                          ),
                        if (filesPicked)
                          for (var i = 0; i < c.sharedFiles.length; i++)
                            EnterOnce(
                              key: ValueKey(c.sharedFiles[i].uri),
                              delay: Duration(milliseconds: 40 * (i < 8 ? i : 8)),
                              child: _PickedFileRow(
                                file: c.sharedFiles[i],
                                onRemove: _busy ? null : () => c.removeSharedFile(i),
                              ),
                            ),
                        const SizedBox(height: 10),
                        OutlinedButton.icon(
                          onPressed: _busy ? null : () => _run(c.pickFiles),
                          icon: Icon(filesPicked ? Icons.swap_horiz_rounded : Icons.note_add_outlined),
                          label: Text(filesPicked ? 'Choose other files' : 'Choose files'),
                        ),
                      ]),
                    ),
                    ),
                  ),
                  Reveal(
                    visible: c.error != null,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: NoticeBanner(text: c.error ?? '', isError: true),
                    ),
                  ),
                ],
              ),
            ),
            FilledButton.icon(
              onPressed: _busy ? null : () => _run(ready ? c.start : pick),
              icon: AnimatedSwitcher(
                duration: DcMotion.of(context, DcMotion.quick),
                transitionBuilder: (c, a) => ScaleTransition(scale: a, child: FadeTransition(opacity: a, child: c)),
                child: _busy
                    ? const SizedBox(
                        key: ValueKey('busy'),
                        width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : Icon(ready ? Icons.wifi_tethering_rounded : Icons.add_rounded, key: ValueKey(ready)),
              ),
              label: AnimatedSwitcher(
                duration: DcMotion.of(context, DcMotion.quick),
                child: Text(
                  ready ? (c.stopReason != null ? 'Start again' : 'Start sharing') : (_mode == ShareMode.folder ? 'Choose a folder' : 'Choose files'),
                  key: ValueKey('$ready${_mode.name}${c.stopReason != null}'),
                ),
              ),
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

/// Full-screen state when the phone has no Wi-Fi or hotspot address.
class _NoWifiView extends StatelessWidget {
  const _NoWifiView({super.key, required this.controller});
  final SharingController controller;

  @override
  Widget build(BuildContext context) {
    final t = DcTheme.of(context);
    final text = Theme.of(context).textTheme;
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
                      fontFamily: AppTheme.display, fontWeight: FontWeight.w700, fontSize: 22, letterSpacing: -0.4, color: t.ink)),
            ]),
            Expanded(
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Container(
                  width: 88,
                  height: 88,
                  decoration: BoxDecoration(
                    color: t.surface,
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(color: t.line),
                  ),
                  child: Icon(Icons.wifi_off_rounded, size: 40, color: t.ink2),
                ),
                const SizedBox(height: 16),
                Text('No Wi-Fi', style: text.headlineMedium?.copyWith(fontSize: 30)),
                const SizedBox(height: 6),
                Text('Wi-Fi or hotspot needed', style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
                if (controller.stopReason == StopReason.wifiLost) ...[
                  const SizedBox(height: 18),
                  const NoticeBanner(text: 'Sharing stopped when Wi-Fi was lost', icon: Icons.stop_circle_outlined),
                ],
              ]),
            ),
            FilledButton.icon(
              onPressed: controller.openWifiSettings,
              icon: const Icon(Icons.wifi_rounded),
              label: const Text('Open Wi-Fi settings'),
            ),
            const SizedBox(height: 10),
            const FilledButton(
              onPressed: null,
              style: ButtonStyle(minimumSize: WidgetStatePropertyAll(Size.fromHeight(52))),
              child: Text('Start sharing'),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Shown on Home after sharing ended without the user tapping Stop.
class _StoppedCard extends StatelessWidget {
  const _StoppedCard({required this.reason, required this.onDismiss});
  final StopReason reason;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final t = DcTheme.of(context);
    final (IconData icon, String why) = switch (reason) {
      StopReason.wifiLost => (Icons.wifi_off_rounded, 'Wi-Fi lost'),
      StopReason.accessLost => (Icons.folder_off_outlined, 'Lost access to files · pick again'),
      StopReason.system => (Icons.phonelink_erase_rounded, 'Stopped by the phone'),
    };
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
        decoration: BoxDecoration(color: t.warnSoft, borderRadius: BorderRadius.circular(16)),
        child: Row(children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: t.surface, borderRadius: BorderRadius.circular(12)),
            child: Icon(icon, size: 20, color: t.warnInk),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Sharing stopped', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16, color: t.warnInk)),
              Text(why, style: TextStyle(fontSize: 13, color: t.warnInk)),
            ]),
          ),
          IconButton(
            tooltip: 'Dismiss',
            icon: Icon(Icons.close_rounded, color: t.warnInk, size: 20),
            onPressed: onDismiss,
          ),
        ]),
      ),
    );
  }
}

/// Shown on the sharing screen when the phone moved networks and the link changed.
class _LinkChangedNotice extends StatelessWidget {
  const _LinkChangedNotice({required this.onAck});
  final VoidCallback onAck;

  @override
  Widget build(BuildContext context) {
    final t = DcTheme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
      decoration: BoxDecoration(color: t.warnSoft, borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        Icon(Icons.sync_alt_rounded, size: 18, color: t.warnInk),
        const SizedBox(width: 10),
        Expanded(
          child: Text('New link · share the QR again',
              style: TextStyle(color: t.warnInk, fontSize: 13, fontWeight: FontWeight.w600)),
        ),
        TextButton(onPressed: onAck, child: Text('Got it', style: TextStyle(color: t.warnInk))),
      ]),
    );
  }
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
                    EnterOnce(
                      dy: 16,
                      child: DcCard(
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
                            child: FadeThroughSwitcher(
                              duration: DcMotion.medium,
                              dy: 0,
                              alignment: Alignment.center,
                              child: QrImageView(
                              key: ValueKey(url),
                              data: url,
                              size: 168,
                              padding: EdgeInsets.zero,
                              eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: DcColors.ink),
                              dataModuleStyle: const QrDataModuleStyle(
                                  dataModuleShape: QrDataModuleShape.square, color: DcColors.ink),
                            ),
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
                              child: FadeThroughSwitcher(
                                alignment: Alignment.centerLeft,
                                duration: DcMotion.medium,
                                child: SelectableText(shortUrl,
                                    key: ValueKey(shortUrl),
                                    maxLines: 1,
                                    style: TextStyle(
                                        fontFamily: AppTheme.display,
                                        fontWeight: FontWeight.w600,
                                        fontSize: 17,
                                        color: t.ink)),
                              ),
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
                    ),
                    const SizedBox(height: 14),
                    EnterOnce(
                      dy: 16,
                      delay: const Duration(milliseconds: 60),
                      child: DcCard(
                      padding: const EdgeInsets.fromLTRB(18, 14, 14, 14),
                      child: Row(children: [
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            const SectionLabel('PIN for visitors'),
                            Semantics(
                              label: 'PIN ${c.pin.split('').join(' ')}',
                              excludeSemantics: true,
                              // New PIN rolls up into place, like a counter.
                              child: AnimatedSwitcher(
                                duration: DcMotion.of(context, DcMotion.medium),
                                layoutBuilder: (cur, prev) => Stack(
                                    alignment: Alignment.centerLeft, children: [...prev, if (cur != null) cur]),
                                transitionBuilder: (child, a) {
                                  final incoming = child.key == ValueKey(c.pin);
                                  final curved = CurvedAnimation(parent: a, curve: DcMotion.enter);
                                  return ClipRect(
                                    child: SlideTransition(
                                      position: Tween(
                                              begin: Offset(0, incoming ? 0.6 : -0.6), end: Offset.zero)
                                          .animate(curved),
                                      child: FadeTransition(opacity: curved, child: child),
                                    ),
                                  );
                                },
                                child: Text(c.pin.isEmpty ? '----' : c.pin,
                                    key: ValueKey(c.pin),
                                    style: TextStyle(
                                        fontFamily: AppTheme.display,
                                        fontWeight: FontWeight.w700,
                                        fontSize: 34,
                                        letterSpacing: 9,
                                        color: t.ink)),
                              ),
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
                          child: FadeThroughSwitcher(
                            alignment: Alignment.centerLeft,
                            duration: DcMotion.quick,
                            child: Text(
                              clients == 0
                                  ? 'Waiting for someone to open the link'
                                  : '$clients ${clients == 1 ? 'device has' : 'devices have'} unlocked with your PIN',
                              key: ValueKey(clients),
                              style: text.bodyMedium,
                            ),
                          ),
                        ),
                      ]),
                    ),
                    Reveal(
                      visible: c.urlChanged,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 14),
                        child: _LinkChangedNotice(onAck: c.acknowledgeUrlChange),
                      ),
                    ),
                    if (_isIos) ...[
                      const SizedBox(height: 14),
                      const NoticeBanner(
                        text:
                            'Keep DataCast open on screen. iPhone pauses sharing when you switch apps or lock the phone.',
                      ),
                    ],
                    Reveal(
                      visible: c.error != null,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 14),
                        child: NoticeBanner(text: c.error ?? '', isError: true),
                      ),
                    ),
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
