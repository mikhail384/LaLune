// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final double opacity;
  final double blur;
  final VoidCallback? onTap;

  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = 14,
    this.opacity = 0.07,
    this.blur = 12,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final decoration = BoxDecoration(
      color: Colors.white.withOpacity(opacity),
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: Colors.white.withOpacity(0.12), width: 1),
    );
    final surface = Container(
      padding: padding,
      decoration: decoration,
      child: child,
    );

    // Android uses the translucent surface without backdrop sampling. Settings
    // contains many cards; removing those offscreen blur passes saves both GPU
    // bandwidth and frame time while preserving the same layout/tint/border.
    final isAndroid = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    final Widget filtered;
    if (isAndroid || blur <= 0) {
      filtered = surface;
    } else {
      final filter = ImageFilter.blur(sigmaX: blur, sigmaY: blur);
      filtered = BackdropGroup.of(context) == null
          ? BackdropFilter(filter: filter, child: surface)
          : BackdropFilter.grouped(filter: filter, child: surface);
    }
    final card = RepaintBoundary(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: filtered,
      ),
    );

    if (onTap == null) return card;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(radius),
        onTap: onTap,
        child: card,
      ),
    );
  }
}
