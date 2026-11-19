// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

double _dialogBlurSigma() {
  if (kIsWeb) return 10;
  return defaultTargetPlatform == TargetPlatform.android ? 6.0 : 14.0;
}

BoxDecoration _dialogGlassDecoration(BorderRadius borderRadius, Color? requested) {
  final baseTop = requested != null
      ? requested.withOpacity(0.84)
      : const Color(0xFF0B2118).withOpacity(0.86);
  final baseBottom = requested != null
      ? requested.withOpacity(0.76)
      : const Color(0xFF07160F).withOpacity(0.82);

  return BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [baseTop, baseBottom],
    ),
    borderRadius: borderRadius,
    border: Border.all(color: Colors.white.withOpacity(0.16), width: 1),
    boxShadow: [
      BoxShadow(
        color: Colors.black.withOpacity(0.45),
        blurRadius: 28,
        offset: const Offset(0, 12),
      ),
    ],
  );
}

Widget _glassLayer(
  BuildContext context, {
  required Widget child,
  required BorderRadius borderRadius,
  Color? backgroundColor,
}) {
  final blur = _dialogBlurSigma();
  final filter = ImageFilter.blur(
    sigmaX: blur,
    sigmaY: blur,
    tileMode: TileMode.clamp,
  );
  final surface = DecoratedBox(
    decoration: _dialogGlassDecoration(borderRadius, backgroundColor),
    child: child,
  );
  return RepaintBoundary(
    child: ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: filter,
        child: surface,
      ),
    ),
  );
}

/// AlertDialog with a dark frosted-glass surface and mobile-safe blur.
class GlassAlertDialog extends StatelessWidget {
  final Widget? title;
  final Widget? content;
  final List<Widget>? actions;
  final EdgeInsetsGeometry? titlePadding;
  final EdgeInsetsGeometry? contentPadding;
  final EdgeInsetsGeometry? actionsPadding;
  final MainAxisAlignment? actionsAlignment;
  final OverflowBarAlignment? actionsOverflowAlignment;
  final VerticalDirection? actionsOverflowDirection;
  final double? actionsOverflowButtonSpacing;
  final EdgeInsets? insetPadding;
  final ShapeBorder? shape;
  final Color? backgroundColor;
  final bool scrollable;

  const GlassAlertDialog({
    super.key,
    this.title,
    this.content,
    this.actions,
    this.titlePadding,
    this.contentPadding,
    this.actionsPadding,
    this.actionsAlignment,
    this.actionsOverflowAlignment,
    this.actionsOverflowDirection,
    this.actionsOverflowButtonSpacing,
    this.insetPadding,
    this.shape,
    this.backgroundColor,
    this.scrollable = false,
  });

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(18);
    final theme = Theme.of(context);

    Widget? titleWidget;
    if (title != null) {
      titleWidget = Padding(
        padding: titlePadding ?? const EdgeInsets.fromLTRB(22, 20, 22, 10),
        child: DefaultTextStyle(
          style: (theme.textTheme.titleLarge ?? const TextStyle()).copyWith(
            color: const Color(0xFFF7FBF8),
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
          child: title!,
        ),
      );
    }

    Widget? contentWidget;
    if (content != null) {
      final padded = Padding(
        padding: contentPadding ?? const EdgeInsets.fromLTRB(22, 8, 22, 18),
        child: DefaultTextStyle(
          style: (theme.textTheme.bodyMedium ?? const TextStyle()).copyWith(
            color: const Color(0xFFF7FBF8),
          ),
          child: content!,
        ),
      );
      contentWidget = Flexible(
        child: scrollable ? SingleChildScrollView(child: padded) : padded,
      );
    }

    Widget? actionsWidget;
    if (actions != null && actions!.isNotEmpty) {
      actionsWidget = Padding(
        padding: actionsPadding ?? const EdgeInsets.fromLTRB(16, 4, 16, 16),
        child: OverflowBar(
          alignment: actionsAlignment ?? MainAxisAlignment.end,
          overflowAlignment:
              actionsOverflowAlignment ?? OverflowBarAlignment.end,
          overflowDirection: actionsOverflowDirection ?? VerticalDirection.down,
          spacing: 8,
          overflowSpacing: actionsOverflowButtonSpacing ?? 8,
          children: actions!,
        ),
      );
    }

    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      insetPadding: insetPadding ??
          const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 280, maxWidth: 460),
        child: _glassLayer(
          context,
          borderRadius: radius,
          backgroundColor: backgroundColor,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (titleWidget != null) titleWidget,
              if (contentWidget != null) contentWidget,
              if (actionsWidget != null) actionsWidget,
            ],
          ),
        ),
      ),
    );
  }
}

/// Generic dark frosted-glass Dialog wrapper for custom modal bodies.
class GlassDialog extends StatelessWidget {
  final Widget child;
  final EdgeInsets? insetPadding;
  final Color? backgroundColor;
  final ShapeBorder? shape;

  const GlassDialog({
    super.key,
    required this.child,
    this.insetPadding,
    this.backgroundColor,
    this.shape,
  });

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(18);
    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      insetPadding: insetPadding ??
          const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: _glassLayer(
        context,
        borderRadius: radius,
        backgroundColor: backgroundColor,
        child: child,
      ),
    );
  }
}
