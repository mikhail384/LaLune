// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Новогодняя палитра: хвойный зелёный + снежный белый + красный акцент.
// Стеклянные поверхности намеренно полупрозрачные: фактический blur
// выполняется GlassDialog/GlassCard, а Theme не перекрывает его сплошным цветом.

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

const Color kAccent = Color(0xFF2FBF71);
const Color kAccentRed = Color(0xFFE5484D);
const Color kAccentWhite = Color(0xFFF7FBF8);
const Color kAccentYellow = Color(0xFFE5484D);
const Color kAccentGreen = Color(0xFF73E6A6);
const Color kBackground = Color(0xFF07160F);
const Color kSurface = Color(0xFF0B2118);

// Дополнительные UI-токены для единой иерархии стекла и типографики.
const Color kGlassBorder = Color(0x24FFFFFF);
const Color kTextSecondary = Color(0xB8F7FBF8);
const Color kTextMuted = Color(0x7AF7FBF8);

ThemeData buildAppTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  final baseText = base.textTheme.apply(
    fontFamily: 'Nunito',
    bodyColor: kAccentWhite,
    displayColor: kAccentWhite,
  );

  return base.copyWith(
    scaffoldBackgroundColor: Colors.transparent,
    splashFactory: (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) ? InkRipple.splashFactory : InkSparkle.splashFactory,
    colorScheme: base.colorScheme.copyWith(
      primary: kAccent,
      onPrimary: Colors.white,
      secondary: kAccentRed,
      onSecondary: Colors.white,
      surface: kSurface.withOpacity(0.36),
      onSurface: kAccentWhite,
      outline: kGlassBorder,
      error: kAccentRed,
    ),
    textTheme: baseText.copyWith(
      titleLarge: baseText.titleLarge?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.2,
        height: 1.25,
      ),
      titleMedium: baseText.titleMedium?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.1,
        height: 1.3,
      ),
      bodyMedium: baseText.bodyMedium?.copyWith(
        height: 1.4,
      ),
      bodySmall: baseText.bodySmall?.copyWith(
        color: kTextSecondary,
        height: 1.35,
      ),
      labelLarge: baseText.labelLarge?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: 0.2,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white.withOpacity(0.06),
      hoverColor: Colors.white.withOpacity(0.09),
      hintStyle: const TextStyle(color: kTextMuted),
      labelStyle: const TextStyle(color: kTextSecondary),
      floatingLabelStyle: const TextStyle(
        color: kAccentGreen,
        fontWeight: FontWeight.w600,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: Colors.white.withOpacity(0.14)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: Colors.white.withOpacity(0.14)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: kAccent, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: kAccentRed.withOpacity(0.8)),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: kAccentRed, width: 1.5),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: kAccent,
        foregroundColor: Colors.white,
        disabledBackgroundColor: kAccent.withOpacity(0.32),
        disabledForegroundColor: Colors.white.withOpacity(0.55),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(
          fontFamily: 'Nunito',
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
        ),
        elevation: 0,
      ).copyWith(
        overlayColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.pressed)) {
            return Colors.white.withOpacity(0.16);
          }
          if (states.contains(WidgetState.hovered)) {
            return Colors.white.withOpacity(0.10);
          }
          return null;
        }),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: kAccentWhite,
        side: BorderSide(color: Colors.white.withOpacity(0.18)),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(
          fontFamily: 'Nunito',
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: kTextSecondary,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: kAccentWhite,
        hoverColor: Colors.white.withOpacity(0.08),
        highlightColor: Colors.white.withOpacity(0.12),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? kAccentWhite
            : Colors.white.withOpacity(0.78),
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? kAccent.withOpacity(0.78)
            : Colors.white.withOpacity(0.10),
      ),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Colors.transparent
            : Colors.white.withOpacity(0.18),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: Colors.white.withOpacity(0.09),
      thickness: 1,
      space: 1,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: kSurface.withOpacity(0.94),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withOpacity(0.14)),
      ),
      textStyle: const TextStyle(
        fontFamily: 'Nunito',
        fontSize: 12,
        color: kAccentWhite,
      ),
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(16)),
      ),
    ),
  );
}
