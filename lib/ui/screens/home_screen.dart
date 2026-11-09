import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

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
    final hasFolder = (c.folderName ?? '').isNotEmpty;

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
                  Text('Share a folder', style: text.headlineMedium?.copyWith(fontSize: 34, letterSpacing: -1)),
                  const SizedBox(height: 10),
                  Text('Wi-Fi  ·  Link  ·  PIN',
                      style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
                  const SizedBox(height: 24),
                  DcCard(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      const SectionLabel('Folder to share'),
                      Row(children: [
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                              color: hasFolder ? t.accentSoft : t.surface2,
                              borderRadius: BorderRadius.circular(12)),
                          child: Icon(Icons.folder_outlined,
                              color: hasFolder ? t.accent : t.ink2, size: 24),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            hasFolder ? c.folderName! : 'No folder chosen yet',
                            style: hasFolder ? text.titleMedium : text.bodyMedium,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ]),
                      const SizedBox(height: 14),
                      OutlinedButton.icon(
                        onPressed: _busy ? null : () => _run(c.pickFolder),
                        icon: Icon(hasFolder ? Icons.swap_horiz_rounded : Icons.create_new_folder_outlined),
                        label: Text(hasFolder ? 'Change folder' : 'Choose a folder'),
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
              onPressed: _busy ? null : () => _run(hasFolder ? c.start : c.pickFolder),
              icon: _busy
                  ? const SizedBox(
                      width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : Icon(hasFolder ? Icons.wifi_tethering_rounded : Icons.folder_open_rounded),
              label: Text(hasFolder ? 'Start sharing' : 'Choose a folder to share'),
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
