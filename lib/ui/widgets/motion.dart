import 'package:flutter/material.dart';

/// Motion tokens shared by every DataCast screen, so transitions feel like
/// one system: quick for small changes, a little longer for whole screens,
/// always decelerating into place.
class DcMotion {
  static const quick = Duration(milliseconds: 180);
  static const medium = Duration(milliseconds: 280);
  static const screen = Duration(milliseconds: 420);

  /// Things arriving: fast start, soft landing.
  static const enter = Curves.easeOutCubic;

  /// Things leaving: get out of the way quickly.
  static const exit = Curves.easeInCubic;

  /// Size changes.
  static const resize = Curves.easeInOutCubic;

  /// Returns [d], or zero when the user turned animations off in the OS.
  static Duration of(BuildContext context, Duration d) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false ? Duration.zero : d;
}

/// Fade plus a short upward slide and a hint of scale. Used for switching
/// between whole screens (idle, sharing, no Wi-Fi) and for content swaps.
Widget dcFadeThrough(Widget child, Animation<double> animation, {double dy = 0.03, double scale = 0.985}) {
  final curved = CurvedAnimation(parent: animation, curve: DcMotion.enter, reverseCurve: DcMotion.exit);
  return FadeTransition(
    opacity: curved,
    child: SlideTransition(
      position: Tween(begin: Offset(0, dy), end: Offset.zero).animate(curved),
      child: ScaleTransition(scale: Tween(begin: scale, end: 1.0).animate(curved), child: child),
    ),
  );
}

/// Cross-fades between children keyed differently, with [dcFadeThrough].
/// The outgoing child is laid out on top of the incoming one so heights
/// don't jump; wrap in [AnimatedSize] when they differ.
class FadeThroughSwitcher extends StatelessWidget {
  const FadeThroughSwitcher({
    super.key,
    required this.child,
    this.duration = DcMotion.medium,
    this.dy = 0.03,
    this.alignment = Alignment.topCenter,
  });

  final Widget child;
  final Duration duration;
  final double dy;
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: DcMotion.of(context, duration),
      reverseDuration: DcMotion.of(context, duration * 0.6),
      switchInCurve: Curves.linear,
      switchOutCurve: Curves.linear,
      layoutBuilder: (current, previous) => Stack(
        alignment: alignment,
        children: [...previous, ?current],
      ),
      transitionBuilder: (c, a) => dcFadeThrough(c, a, dy: dy),
      child: child,
    );
  }
}

/// Shows [child] when [visible], growing open and fading in; collapses and
/// fades out when hidden. For banners, notices and optional rows.
class Reveal extends StatelessWidget {
  const Reveal({super.key, required this.visible, required this.child, this.duration = DcMotion.medium});

  final bool visible;
  final Widget child;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: DcMotion.of(context, duration),
      switchInCurve: Curves.linear,
      switchOutCurve: Curves.linear,
      transitionBuilder: (c, a) {
        final curved = CurvedAnimation(parent: a, curve: DcMotion.enter, reverseCurve: DcMotion.exit);
        // Grows downward from the top edge.
        return ClipRect(
          child: AnimatedBuilder(
            animation: curved,
            builder: (context, child) => Align(
              alignment: Alignment.topCenter,
              heightFactor: curved.value.clamp(0.0, 1.0),
              child: child,
            ),
            child: FadeTransition(opacity: curved, child: c),
          ),
        );
      },
      child: visible ? KeyedSubtree(key: const ValueKey(true), child: child) : const SizedBox(key: ValueKey(false), width: double.infinity),
    );
  }
}

/// Plays a one-off fade and slide-in the first time it is built. Used for
/// rows added to a list (each needs a stable key).
class EnterOnce extends StatelessWidget {
  const EnterOnce({super.key, required this.child, this.delay = Duration.zero, this.dy = 12});

  final Widget child;
  final Duration delay;
  final double dy;

  @override
  Widget build(BuildContext context) {
    final total = DcMotion.of(context, DcMotion.medium + delay);
    if (total == Duration.zero) return child;
    final start = delay.inMicroseconds / total.inMicroseconds;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: total,
      curve: Interval(start.clamp(0.0, 0.9), 1, curve: DcMotion.enter),
      child: child,
      builder: (context, v, child) => Opacity(
        opacity: v,
        child: Transform.translate(offset: Offset(0, (1 - v) * dy), child: child),
      ),
    );
  }
}
