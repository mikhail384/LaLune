// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/cached_glass.dart';

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
    this.blur = 16,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(radius);
    final topAlpha = (0.38 + opacity * 0.45).clamp(0.0, 0.65);
    final bottomAlpha = (0.28 + opacity * 0.35).clamp(0.0, 0.58);

    final decoration = BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          const Color(0xFF0B2118).withOpacity(topAlpha),
          const Color(0xFF07160F).withOpacity(bottomAlpha),
        ],
      ),
      borderRadius: borderRadius,
      border: Border.all(color: Colors.white.withOpacity(0.15), width: 1),
    );

    Widget content = Padding(
      padding: padding,
      child: child,
    );

    if (onTap != null) {
      content = Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: borderRadius,
          hoverColor: Colors.white.withOpacity(0.06),
          splashColor: Colors.white.withOpacity(0.08),
          highlightColor: Colors.white.withOpacity(0.04),
          onTap: onTap,
          child: content,
        ),
      );
    }

    final surface = DecoratedBox(
      decoration: decoration,
      child: content,
    );

    final effectiveBlur =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.android && blur > 14
            ? 14.0
            : blur;

    var backdrop = CachedGlassBackdrop.sample(context, effectiveBlur);
    if (effectiveBlur > 0 && backdrop == null) {
      final filter = ImageFilter.blur(
        sigmaX: effectiveBlur,
        sigmaY: effectiveBlur,
        tileMode: TileMode.clamp,
      );
      const fill = SizedBox.expand();
      backdrop = BackdropGroup.of(context) == null
          ? BackdropFilter(filter: filter, child: fill)
          : BackdropFilter.grouped(filter: filter, child: fill);
    }

    // The keyboard resizes the viewport, so the cached wallpaper temporarily
    // falls back to a live blur. Only replace the backdrop, not the controls.
    return ClipRRect(
      borderRadius: borderRadius,
      child: Stack(
        children: [
          Positioned.fill(child: backdrop ?? const SizedBox.shrink()),
          RepaintBoundary(child: surface),
        ],
      ),
    );
  }
}
