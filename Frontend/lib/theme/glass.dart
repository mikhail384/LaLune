// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

/// Общий стиль "стеклянной" карточки – полупрозрачный градиент + рамка + мягкая тень.
BoxDecoration glassCard({double radius = 14, double opacity = 0.08}) {
  final topAlpha = (opacity + 0.04).clamp(0.0, 1.0);
  final bottomAlpha = (opacity * 0.65).clamp(0.0, 1.0);

  return BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        Colors.white.withOpacity(topAlpha),
        Colors.white.withOpacity(bottomAlpha),
      ],
    ),
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(color: Colors.white.withOpacity(0.14), width: 1),
    boxShadow: (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) ? null : [
      BoxShadow(
        color: Colors.black.withOpacity(0.24),
        blurRadius: 20,
        offset: const Offset(0, 8),
      ),
    ],
  );
}
