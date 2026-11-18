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

    // High-sigma backdrop blur is very expensive on Android GPUs. Keep the
    // desktop look, but cap mobile blur and share filters through BackdropGroup
    // when the root shell provides one.
    final effectiveBlur =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.android && blur > 7
            ? 7.0
            : blur;
    final filter =
        ImageFilter.blur(sigmaX: effectiveBlur, sigmaY: effectiveBlur);
    final filtered = BackdropGroup.of(context) == null
        ? BackdropFilter(filter: filter, child: surface)
        : BackdropFilter.grouped(filter: filter, child: surface);
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
