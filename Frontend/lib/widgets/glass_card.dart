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
    final borderRadius = BorderRadius.circular(radius);
    final topAlpha = (opacity + 0.035).clamp(0.0, 1.0);
    final bottomAlpha = (opacity * 0.68).clamp(0.0, 1.0);

    final decoration = BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Colors.white.withOpacity(topAlpha),
          Colors.white.withOpacity(bottomAlpha),
        ],
      ),
      borderRadius: borderRadius,
      border: Border.all(color: Colors.white.withOpacity(0.14), width: 1),
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

    // High-sigma backdrop blur is very expensive on Android GPUs. Keep the
    // desktop look, but cap mobile blur and share filters through BackdropGroup
    // when the root shell provides one.
    final effectiveBlur =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.android && blur > 7
            ? 7.0
            : blur;

    Widget body;
    if (effectiveBlur <= 0) {
      body = surface;
    } else {
      final filter = ImageFilter.blur(
        sigmaX: effectiveBlur,
        sigmaY: effectiveBlur,
        tileMode: TileMode.clamp,
      );
      body = BackdropGroup.of(context) == null
          ? BackdropFilter(filter: filter, child: surface)
          : BackdropFilter.grouped(filter: filter, child: surface);
    }

    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: borderRadius,
        child: body,
      ),
    );
  }
}
