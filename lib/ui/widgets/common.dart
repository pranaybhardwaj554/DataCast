import 'dart:math' as math;

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

/// The DataCast mark, drawn to match the launcher icon and the web logo
/// exactly (assets/brand/datacast-icon.svg): a #3B5BFD rounded square
/// with the white broadcast glyph.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 36});
  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
        label: 'DataCast',
        image: true,
        child: CustomPaint(size: Size.square(size), painter: const _BrandMarkPainter()),
      );
}

class _BrandMarkPainter extends CustomPainter {
  const _BrandMarkPainter();

  @override
  void paint(Canvas canvas, Size size) {
    // The icon SVG is a 96 box with rx 22; the 24-unit glyph is scaled by
    // 2.73 and its point (12, 11.05) sits at the centre.
    final box = size.width / 96;
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(22 * box)),
      Paint()..color = DcColors.accent,
    );
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(2.73 * box);
    canvas.translate(-12, -11.05);
    // The glyph's two arcs are 2-unit-thick half rings with round ends
    // (outer r 6 to 8, inner r 2.5 to 4.5, centred at 12, 12.5), which is
    // a round-capped stroke along the middle radius.
    final arc = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    const c = Offset(12, 12.5);
    canvas.drawArc(Rect.fromCircle(center: c, radius: 7), math.pi, math.pi, false, arc);
    canvas.drawArc(Rect.fromCircle(center: c, radius: 3.5), math.pi, math.pi, false, arc);
    canvas.drawCircle(const Offset(12, 16), 1.6, Paint()..color = Colors.white);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_BrandMarkPainter oldDelegate) => false;
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
    // Pops in when sharing starts.
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: reduceMotion ? 1 : 0.6, end: 1),
      duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 420),
      curve: Curves.easeOutBack,
      builder: (context, v, child) => Transform.scale(scale: v, child: Opacity(opacity: v.clamp(0.0, 1.0), child: child)),
      child: Semantics(
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
