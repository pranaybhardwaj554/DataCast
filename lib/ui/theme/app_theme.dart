import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// DataCast design tokens. Kept in sync with assets/web/app.css.
class DcColors {
  static const paper = Color(0xFFF6F7F9);
  static const surface = Color(0xFFFFFFFF);
  static const surface2 = Color(0xFFF1F3F7);
  static const line = Color(0xFFE3E6EC);
  static const lineStrong = Color(0xFFD5DAE3);
  static const ink = Color(0xFF14161F);
  static const ink2 = Color(0xFF4A5060);
  static const ink3 = Color(0xFF5B6170);
  static const accent = Color(0xFF3B5BFD);
  static const accentSoft = Color(0xFFEAEEFF);
  static const live = Color(0xFF0E9F6E);
  static const liveInk = Color(0xFF0B7A55);
  static const liveSoft = Color(0xFFE3F5EE);
  static const warnSoft = Color(0xFFFFF6E5);
  static const warnInk = Color(0xFF7A4B00);
  static const danger = Color(0xFFB42318);

  // Dark
  static const dPaper = Color(0xFF0E1016);
  static const dSurface = Color(0xFF161922);
  static const dSurface2 = Color(0xFF1E222C);
  static const dLine = Color(0xFF262A35);
  static const dInk = Color(0xFFF2F3F6);
  static const dInk2 = Color(0xFFB9BECB);
  static const dAccent = Color(0xFF6F86FF);
  static const dAccentSoft = Color(0xFF1F2747);
}

/// Colors that differ between light and dark, read with `DcTheme.of(context)`.
@immutable
class DcTheme extends ThemeExtension<DcTheme> {
  const DcTheme({
    required this.paper,
    required this.surface,
    required this.surface2,
    required this.line,
    required this.ink,
    required this.ink2,
    required this.accent,
    required this.accentSoft,
    required this.liveSoft,
    required this.liveInk,
    required this.warnSoft,
    required this.warnInk,
  });

  final Color paper, surface, surface2, line, ink, ink2, accent, accentSoft;
  final Color liveSoft, liveInk, warnSoft, warnInk;

  static const light = DcTheme(
    paper: DcColors.paper,
    surface: DcColors.surface,
    surface2: DcColors.surface2,
    line: DcColors.line,
    ink: DcColors.ink,
    ink2: DcColors.ink3,
    accent: DcColors.accent,
    accentSoft: DcColors.accentSoft,
    liveSoft: DcColors.liveSoft,
    liveInk: DcColors.liveInk,
    warnSoft: DcColors.warnSoft,
    warnInk: DcColors.warnInk,
  );

  static const dark = DcTheme(
    paper: DcColors.dPaper,
    surface: DcColors.dSurface,
    surface2: DcColors.dSurface2,
    line: DcColors.dLine,
    ink: DcColors.dInk,
    ink2: DcColors.dInk2,
    accent: DcColors.dAccent,
    accentSoft: DcColors.dAccentSoft,
    liveSoft: Color(0xFF12302A),
    liveInk: Color(0xFF4ED6A0),
    warnSoft: Color(0xFF332A14),
    warnInk: Color(0xFFF5C46B),
  );

  static DcTheme of(BuildContext context) =>
      Theme.of(context).extension<DcTheme>() ?? light;

  @override
  DcTheme copyWith() => this;

  @override
  DcTheme lerp(ThemeExtension<DcTheme>? other, double t) =>
      (other is DcTheme && t > 0.5) ? other : this;
}

class AppTheme {
  /// Display face for headings, the URL and the PIN. Falls back to the
  /// platform font if 'SpaceGrotesk' is not bundled in pubspec.yaml.
  static const display = 'SpaceGrotesk';

  static ThemeData light() => _build(Brightness.light, DcTheme.light);
  static ThemeData dark() => _build(Brightness.dark, DcTheme.dark);

  static ThemeData _build(Brightness b, DcTheme t) {
    final scheme = ColorScheme.fromSeed(
      seedColor: DcColors.accent,
      brightness: b,
    ).copyWith(
      primary: t.accent,
      onPrimary: Colors.white,
      surface: t.surface,
      onSurface: t.ink,
      error: DcColors.danger,
    );
    final radius = BorderRadius.circular(14);
    return ThemeData(
      useMaterial3: true,
      brightness: b,
      colorScheme: scheme,
      scaffoldBackgroundColor: t.paper,
      extensions: [t],
      appBarTheme: AppBarTheme(
        backgroundColor: t.paper,
        foregroundColor: t.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontFamily: display,
          fontWeight: FontWeight.w700,
          fontSize: 22,
          letterSpacing: -0.4,
          color: t.ink,
        ),
      ),
      textTheme: TextTheme(
        headlineMedium: TextStyle(
          fontFamily: display,
          fontWeight: FontWeight.w600,
          fontSize: 28,
          height: 1.15,
          letterSpacing: -0.5,
          color: t.ink,
        ),
        titleMedium: TextStyle(fontWeight: FontWeight.w600, fontSize: 16, color: t.ink),
        bodyMedium: TextStyle(fontSize: 15, height: 1.45, color: t.ink2),
        bodySmall: TextStyle(fontSize: 13, color: t.ink2),
        labelSmall: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.7,
          color: t.ink2,
        ),
      ),
      cardTheme: CardThemeData(
        color: t.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: t.line),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(56),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 17),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(44, 44),
          foregroundColor: t.ink,
          side: BorderSide(color: b == Brightness.light ? DcColors.lineStrong : t.line),
          shape: RoundedRectangleBorder(borderRadius: radius),
          textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? Colors.white : null),
        trackColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? t.accent : null),
      ),
      dividerTheme: DividerThemeData(color: t.line, space: 1, thickness: 1),
      // Screen-to-screen motion: Android's fade-forwards (matches the
      // predictive back gesture), iOS keeps its native slide.
      pageTransitionsTheme: const PageTransitionsTheme(builders: {
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      }),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}
