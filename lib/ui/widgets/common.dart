import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Small caps label above a group ("FOLDER TO SHARE").
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text.toUpperCase(), style: Theme.of(context).textTheme.labelSmall),
      );
}

/// The DataCast mark: rounded square with a broadcast glyph.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 36});
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: DcColors.accent,
          borderRadius: BorderRadius.circular(size * 0.28),
        ),
        child: Icon(Icons.wifi_tethering_rounded, color: Colors.white, size: size * 0.58),
      );
}

/// Green pill with a pulsing dot, shown while sharing.
class LiveBadge extends StatefulWidget {
  const LiveBadge({super.key});

  @override
  State<LiveBadge> createState() => _LiveBadgeState();
}

class _LiveBadgeState extends State<LiveBadge> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))
        ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = DcTheme.of(context);
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    return Semantics(
      label: 'Sharing is live',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(color: t.liveSoft, borderRadius: BorderRadius.circular(999)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          FadeTransition(
            opacity: reduceMotion ? const AlwaysStoppedAnimation(1) : Tween(begin: 1.0, end: 0.35).animate(_c),
            child: Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(color: DcColors.live, shape: BoxShape.circle),
            ),
          ),
          const SizedBox(width: 8),
          Text('Live', style: TextStyle(color: t.liveInk, fontWeight: FontWeight.w600, fontSize: 13)),
        ]),
      ),
    );
  }
}

/// White rounded card with a hairline border.
class DcCard extends StatelessWidget {
  const DcCard({super.key, required this.child, this.padding = const EdgeInsets.all(16)});
  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final t = DcTheme.of(context);
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: t.line),
      ),
      child: child,
    );
  }
}

/// Amber or red notice with an icon.
class NoticeBanner extends StatelessWidget {
  const NoticeBanner({super.key, required this.text, this.isError = false, this.icon});
  final String text;
  final bool isError;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final t = DcTheme.of(context);
    final bg = isError ? DcColors.danger.withValues(alpha: 0.10) : t.warnSoft;
    final fg = isError ? DcColors.danger : t.warnInk;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon ?? (isError ? Icons.error_outline_rounded : Icons.info_outline_rounded), size: 18, color: fg),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: TextStyle(color: fg, fontSize: 13, height: 1.45))),
      ]),
    );
  }
}
