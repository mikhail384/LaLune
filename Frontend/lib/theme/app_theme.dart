// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Новогодняя палитра: хвойный зелёный + снежный белый + красный акцент.
// Стеклянные поверхности намеренно полупрозрачные: фактический blur
// выполняется GlassDialog/GlassCard, а Theme не перекрывает его сплошным цветом.

import 'package:flutter/material.dart';

const Color kAccent = Color(0xFF2FBF71);
const Color kAccentRed = Color(0xFFE5484D);
const Color kAccentWhite = Color(0xFFF7FBF8);
const Color kAccentYellow = Color(0xFFE5484D);
const Color kAccentGreen = Color(0xFF73E6A6);
const Color kBackground = Color(0xFF07160F);
const Color kSurface = Color(0xFF0B2118);

ThemeData buildAppTheme() {
  final base = ThemeData.dark(useMaterial3: true);

  return base.copyWith(
    scaffoldBackgroundColor: Colors.transparent,
    colorScheme: base.colorScheme.copyWith(
      primary: kAccent,
      onPrimary: Colors.white,
      secondary: kAccentRed,
      onSecondary: Colors.white,
      surface: kSurface.withOpacity(0.34),
      error: kAccentRed,
    ),
    textTheme: base.textTheme.apply(
      fontFamily: 'Nunito',
      bodyColor: kAccentWhite,
      displayColor: kAccentWhite,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white.withOpacity(0.055),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: Colors.white.withOpacity(0.14)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: Colors.white.withOpacity(0.14)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: kAccent, width: 1.5),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: kAccent,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        elevation: 0,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: Colors.white70),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? kAccentWhite : null,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? kAccent.withOpacity(0.72)
            : null,
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
