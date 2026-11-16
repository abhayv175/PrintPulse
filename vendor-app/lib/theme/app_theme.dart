import 'package:flutter/material.dart';

class AppColors {
  // Brand Purples
  static const Color primaryPurple = Color(0xFF7C3AED); // Vibrant Violet
  static const Color secondaryPurple = Color(0xFFA78BFA); // Soft Lavender
  static const Color lightLavender = Color(0xFFC4B5FD); // Accent highlight
  static const Color activePurple = Color(0xFF6D28D9); // Deep Royal Purple
  static const Color glowPurple = Color(0x3D7C3AED);

  // Light Mode Tokens
  static const Color lightBg1 = Color(0xFFFAF7FF);
  static const Color lightBg2 = Color(0xFFF3E8FF);
  static const Color lightBg3 = Color(0xFFFFFFFF);
  static const Color lightGlassSurface = Color(0xB8FFFFFF); // rgba(255, 255, 255, 0.72)
  static const Color lightGlassBorder = Color(0x1F7C3AED); // rgba(124, 58, 237, 0.12)
  static const Color lightTextPrimary = Color(0xFF1F2937);
  static const Color lightTextSecondary = Color(0xFF6B7280);

  // Dark Mode Tokens
  static const Color darkBg1 = Color(0xFF0F0C20);
  static const Color darkBg2 = Color(0xFF181033);
  static const Color darkBg3 = Color(0xFF0B0716);
  static const Color darkGlassSurface = Color(0xA61A103C); // rgba(26, 16, 60, 0.65)
  static const Color darkGlassBorder = Color(0x2EA78BFA); // rgba(167, 139, 250, 0.18)
  static const Color darkTextPrimary = Color(0xFFF9FAFB);
  static const Color darkTextSecondary = Color(0xFF9CA3AF);

  // Status Colors
  static const Color successGreen = Color(0xFF10B981);
  static const Color warningOrange = Color(0xFFF59E0B);
  static const Color dangerRed = Color(0xFFEF4444);
}

@immutable
class PrintPulsePalette extends ThemeExtension<PrintPulsePalette> {
  final Color bg1;
  final Color bg2;
  final Color bg3;
  final Color cardSurface;
  final Color cardBorder;
  final Color cardPurpleShadow;
  final Color cardDarkShadow;
  final Color navTrackColor;
  final Color navTrackBorder;
  final Color navTrackShadow;
  final Color navPillColor;
  final Color navPillBorder;
  final Color navPillShadow;
  final Color navActiveColor;
  final Color navInactiveColor;
  final Color subtlePillBg;
  final Color subtlePillBorder;
  final Color chipBg;
  final Color chipBorder;
  final Color chipText;
  final Color devCardBorder;
  final Color sheetBg;
  final Color sheetBorder;
  final Color sheetHandle;
  final Color sheetCloseBg;
  final Color sheetQrGlow;
  final Color sheetShadow;
  final Color sheetSecondaryBtnBg;
  final Color sheetSecondaryBtnFg;
  final Color primaryTextColor;
  final Color secondaryTextColor;

  const PrintPulsePalette({
    required this.bg1,
    required this.bg2,
    required this.bg3,
    required this.cardSurface,
    required this.cardBorder,
    required this.cardPurpleShadow,
    required this.cardDarkShadow,
    required this.navTrackColor,
    required this.navTrackBorder,
    required this.navTrackShadow,
    required this.navPillColor,
    required this.navPillBorder,
    required this.navPillShadow,
    required this.navActiveColor,
    required this.navInactiveColor,
    required this.subtlePillBg,
    required this.subtlePillBorder,
    required this.chipBg,
    required this.chipBorder,
    required this.chipText,
    required this.devCardBorder,
    required this.sheetBg,
    required this.sheetBorder,
    required this.sheetHandle,
    required this.sheetCloseBg,
    required this.sheetQrGlow,
    required this.sheetShadow,
    required this.sheetSecondaryBtnBg,
    required this.sheetSecondaryBtnFg,
    required this.primaryTextColor,
    required this.secondaryTextColor,
  });

  static PrintPulsePalette of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<PrintPulsePalette>() ??
        (theme.brightness == Brightness.dark ? dark : light);
  }

  static Color _lerpColor(Color a, Color b, double t) => Color.lerp(a, b, t) ?? a;

  static const PrintPulsePalette light = PrintPulsePalette(
    bg1: AppColors.lightBg1,
    bg2: AppColors.lightBg2,
    bg3: AppColors.lightBg3,
    cardSurface: Color(0xE0FFFFFF), // white @ 0.88 alpha
    cardBorder: Color(0x1F7C3AED), // #7C3AED @ 0.12 alpha
    cardPurpleShadow: Color(0x0A7C3AED),
    cardDarkShadow: Color(0x08000000),
    navTrackColor: Color(0xD1F3EFFB), // #F3EFFB @ 0.82 alpha
    navTrackBorder: Color(0x267C3AED), // #7C3AED @ 0.15 alpha
    navTrackShadow: Color(0x14000000), // black @ 0.08 alpha
    navPillColor: Color(0xF2FFFFFF), // white @ 0.95 alpha
    navPillBorder: Color(0x1F7C3AED), // #7C3AED @ 0.12 alpha
    navPillShadow: Color(0x147C3AED), // #7C3AED @ 0.08 alpha
    navActiveColor: Color(0xFF7C3AED),
    navInactiveColor: Color(0xFF4B5563),
    subtlePillBg: Color(0x0A000000),
    subtlePillBorder: Color(0x0F000000),
    chipBg: Color(0x1A7C3AED),
    chipBorder: Color(0x337C3AED),
    chipText: Color(0xFF7C3AED),
    devCardBorder: Color(0x1F7C3AED),
    sheetBg: Color(0xFFFFFFFF),
    sheetBorder: Color(0x1F7C3AED),
    sheetHandle: Color(0xFFD1D5DB),
    sheetCloseBg: Color(0xFFF3EFFB),
    sheetQrGlow: Color(0x247C3AED),
    sheetShadow: Color(0x1F000000),
    sheetSecondaryBtnBg: Color(0x147C3AED),
    sheetSecondaryBtnFg: Color(0xFF7C3AED),
    primaryTextColor: AppColors.lightTextPrimary,
    secondaryTextColor: AppColors.lightTextSecondary,
  );

  static const PrintPulsePalette dark = PrintPulsePalette(
    bg1: AppColors.darkBg1,
    bg2: AppColors.darkBg2,
    bg3: AppColors.darkBg3,
    cardSurface: Color(0xE01E1438), // #1E1438 @ 0.88 alpha
    cardBorder: Color(0x2EA78BFA), // #A78BFA @ 0.18 alpha
    cardPurpleShadow: Color(0x147C3AED),
    cardDarkShadow: Color(0x40000000),
    navTrackColor: Color(0xC714111F), // #14111F @ 0.78 alpha
    navTrackBorder: Color(0x24FFFFFF), // white @ 0.14 alpha
    navTrackShadow: Color(0x73000000), // black @ 0.45 alpha
    navPillColor: Color(0x1FFFFFFF), // white @ 0.12 alpha
    navPillBorder: Color(0x2EFFFFFF), // white @ 0.18 alpha
    navPillShadow: Color(0x007C3AED),
    navActiveColor: Color(0xFFA78BFA),
    navInactiveColor: Color(0xD9FFFFFF), // white @ 0.85 alpha
    subtlePillBg: Color(0x0DFFFFFF),
    subtlePillBorder: Color(0x14FFFFFF),
    chipBg: Color(0x2E7C3AED),
    chipBorder: Color(0x597C3AED),
    chipText: Color(0xFFA78BFA),
    devCardBorder: Color(0x3D7C3AED),
    sheetBg: Color(0xFF161226),
    sheetBorder: Color(0x24FFFFFF),
    sheetHandle: Color(0x3DFFFFFF),
    sheetCloseBg: Color(0x14FFFFFF),
    sheetQrGlow: Color(0x477C3AED),
    sheetShadow: Color(0x80000000),
    sheetSecondaryBtnBg: Color(0x14FFFFFF),
    sheetSecondaryBtnFg: Color(0xFFFFFFFF),
    primaryTextColor: AppColors.darkTextPrimary,
    secondaryTextColor: AppColors.darkTextSecondary,
  );

  @override
  PrintPulsePalette copyWith({
    Color? bg1,
    Color? bg2,
    Color? bg3,
    Color? cardSurface,
    Color? cardBorder,
    Color? cardPurpleShadow,
    Color? cardDarkShadow,
    Color? navTrackColor,
    Color? navTrackBorder,
    Color? navTrackShadow,
    Color? navPillColor,
    Color? navPillBorder,
    Color? navPillShadow,
    Color? navActiveColor,
    Color? navInactiveColor,
    Color? subtlePillBg,
    Color? subtlePillBorder,
    Color? chipBg,
    Color? chipBorder,
    Color? chipText,
    Color? devCardBorder,
    Color? sheetBg,
    Color? sheetBorder,
    Color? sheetHandle,
    Color? sheetCloseBg,
    Color? sheetQrGlow,
    Color? sheetShadow,
    Color? sheetSecondaryBtnBg,
    Color? sheetSecondaryBtnFg,
    Color? primaryTextColor,
    Color? secondaryTextColor,
  }) {
    return PrintPulsePalette(
      bg1: bg1 ?? this.bg1,
      bg2: bg2 ?? this.bg2,
      bg3: bg3 ?? this.bg3,
      cardSurface: cardSurface ?? this.cardSurface,
      cardBorder: cardBorder ?? this.cardBorder,
      cardPurpleShadow: cardPurpleShadow ?? this.cardPurpleShadow,
      cardDarkShadow: cardDarkShadow ?? this.cardDarkShadow,
      navTrackColor: navTrackColor ?? this.navTrackColor,
      navTrackBorder: navTrackBorder ?? this.navTrackBorder,
      navTrackShadow: navTrackShadow ?? this.navTrackShadow,
      navPillColor: navPillColor ?? this.navPillColor,
      navPillBorder: navPillBorder ?? this.navPillBorder,
      navPillShadow: navPillShadow ?? this.navPillShadow,
      navActiveColor: navActiveColor ?? this.navActiveColor,
      navInactiveColor: navInactiveColor ?? this.navInactiveColor,
      subtlePillBg: subtlePillBg ?? this.subtlePillBg,
      subtlePillBorder: subtlePillBorder ?? this.subtlePillBorder,
      chipBg: chipBg ?? this.chipBg,
      chipBorder: chipBorder ?? this.chipBorder,
      chipText: chipText ?? this.chipText,
      devCardBorder: devCardBorder ?? this.devCardBorder,
      sheetBg: sheetBg ?? this.sheetBg,
      sheetBorder: sheetBorder ?? this.sheetBorder,
      sheetHandle: sheetHandle ?? this.sheetHandle,
      sheetCloseBg: sheetCloseBg ?? this.sheetCloseBg,
      sheetQrGlow: sheetQrGlow ?? this.sheetQrGlow,
      sheetShadow: sheetShadow ?? this.sheetShadow,
      sheetSecondaryBtnBg: sheetSecondaryBtnBg ?? this.sheetSecondaryBtnBg,
      sheetSecondaryBtnFg: sheetSecondaryBtnFg ?? this.sheetSecondaryBtnFg,
      primaryTextColor: primaryTextColor ?? this.primaryTextColor,
      secondaryTextColor: secondaryTextColor ?? this.secondaryTextColor,
    );
  }

  @override
  PrintPulsePalette lerp(covariant ThemeExtension<PrintPulsePalette>? other, double t) {
    if (other is! PrintPulsePalette) return this;
    return PrintPulsePalette(
      bg1: _lerpColor(bg1, other.bg1, t),
      bg2: _lerpColor(bg2, other.bg2, t),
      bg3: _lerpColor(bg3, other.bg3, t),
      cardSurface: _lerpColor(cardSurface, other.cardSurface, t),
      cardBorder: _lerpColor(cardBorder, other.cardBorder, t),
      cardPurpleShadow: _lerpColor(cardPurpleShadow, other.cardPurpleShadow, t),
      cardDarkShadow: _lerpColor(cardDarkShadow, other.cardDarkShadow, t),
      navTrackColor: _lerpColor(navTrackColor, other.navTrackColor, t),
      navTrackBorder: _lerpColor(navTrackBorder, other.navTrackBorder, t),
      navTrackShadow: _lerpColor(navTrackShadow, other.navTrackShadow, t),
      navPillColor: _lerpColor(navPillColor, other.navPillColor, t),
      navPillBorder: _lerpColor(navPillBorder, other.navPillBorder, t),
      navPillShadow: _lerpColor(navPillShadow, other.navPillShadow, t),
      navActiveColor: _lerpColor(navActiveColor, other.navActiveColor, t),
      navInactiveColor: _lerpColor(navInactiveColor, other.navInactiveColor, t),
      subtlePillBg: _lerpColor(subtlePillBg, other.subtlePillBg, t),
      subtlePillBorder: _lerpColor(subtlePillBorder, other.subtlePillBorder, t),
      chipBg: _lerpColor(chipBg, other.chipBg, t),
      chipBorder: _lerpColor(chipBorder, other.chipBorder, t),
      chipText: _lerpColor(chipText, other.chipText, t),
      devCardBorder: _lerpColor(devCardBorder, other.devCardBorder, t),
      sheetBg: _lerpColor(sheetBg, other.sheetBg, t),
      sheetBorder: _lerpColor(sheetBorder, other.sheetBorder, t),
      sheetHandle: _lerpColor(sheetHandle, other.sheetHandle, t),
      sheetCloseBg: _lerpColor(sheetCloseBg, other.sheetCloseBg, t),
      sheetQrGlow: _lerpColor(sheetQrGlow, other.sheetQrGlow, t),
      sheetShadow: _lerpColor(sheetShadow, other.sheetShadow, t),
      sheetSecondaryBtnBg: _lerpColor(sheetSecondaryBtnBg, other.sheetSecondaryBtnBg, t),
      sheetSecondaryBtnFg: _lerpColor(sheetSecondaryBtnFg, other.sheetSecondaryBtnFg, t),
      primaryTextColor: _lerpColor(primaryTextColor, other.primaryTextColor, t),
      secondaryTextColor: _lerpColor(secondaryTextColor, other.secondaryTextColor, t),
    );
  }
}

class AppTheme {
  static const Duration themeTransitionDuration = Duration(milliseconds: 450);
  static const Curve themeTransitionCurve = Curves.easeInOutCubic;

  static ThemeData lightTheme = ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    scaffoldBackgroundColor: AppColors.lightBg1,
    primaryColor: AppColors.primaryPurple,
    extensions: const [PrintPulsePalette.light],
    colorScheme: const ColorScheme.light(
      primary: AppColors.primaryPurple,
      onPrimary: Colors.white,
      secondary: AppColors.secondaryPurple,
      surface: AppColors.lightGlassSurface,
      onSurface: AppColors.lightTextPrimary,
      outline: AppColors.lightGlassBorder,
    ),
    textTheme: const TextTheme(
      headlineLarge: TextStyle(
        color: AppColors.lightTextPrimary,
        fontWeight: FontWeight.bold,
        letterSpacing: -0.5,
      ),
      headlineMedium: TextStyle(
        color: AppColors.lightTextPrimary,
        fontWeight: FontWeight.bold,
      ),
      titleLarge: TextStyle(
        color: AppColors.lightTextPrimary,
        fontWeight: FontWeight.w600,
      ),
      titleMedium: TextStyle(
        color: AppColors.lightTextPrimary,
        fontWeight: FontWeight.w600,
      ),
      bodyLarge: TextStyle(color: AppColors.lightTextPrimary),
      bodyMedium: TextStyle(color: AppColors.lightTextSecondary),
      bodySmall: TextStyle(color: AppColors.lightTextSecondary),
    ),
    cardColor: AppColors.lightGlassSurface,
    dividerColor: const Color(0xFF7C3AED).withValues(alpha: 0.1),
    dividerTheme: DividerThemeData(
      color: const Color(0xFF7C3AED).withValues(alpha: 0.1),
      thickness: 1,
      space: 1,
    ),
  );

  static ThemeData darkTheme = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: AppColors.darkBg1,
    primaryColor: AppColors.primaryPurple,
    extensions: const [PrintPulsePalette.dark],
    colorScheme: const ColorScheme.dark(
      primary: AppColors.primaryPurple,
      onPrimary: Colors.white,
      secondary: AppColors.secondaryPurple,
      surface: AppColors.darkGlassSurface,
      onSurface: AppColors.darkTextPrimary,
      outline: AppColors.darkGlassBorder,
    ),
    textTheme: const TextTheme(
      headlineLarge: TextStyle(
        color: AppColors.darkTextPrimary,
        fontWeight: FontWeight.bold,
        letterSpacing: -0.5,
      ),
      headlineMedium: TextStyle(
        color: AppColors.darkTextPrimary,
        fontWeight: FontWeight.bold,
      ),
      titleLarge: TextStyle(
        color: AppColors.darkTextPrimary,
        fontWeight: FontWeight.w600,
      ),
      titleMedium: TextStyle(
        color: AppColors.darkTextPrimary,
        fontWeight: FontWeight.w600,
      ),
      bodyLarge: TextStyle(color: AppColors.darkTextPrimary),
      bodyMedium: TextStyle(color: AppColors.darkTextSecondary),
      bodySmall: TextStyle(color: AppColors.darkTextSecondary),
    ),
    cardColor: AppColors.darkGlassSurface,
    dividerColor: const Color(0xFF7C3AED).withValues(alpha: 0.1),
    dividerTheme: DividerThemeData(
      color: const Color(0xFF7C3AED).withValues(alpha: 0.1),
      thickness: 1,
      space: 1,
    ),
  );
}
