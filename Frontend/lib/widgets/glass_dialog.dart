// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import 'dart:ui';
import 'package:flutter/material.dart';

/// AlertDialog with a translucent surface and real backdrop blur.
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
    final dialogShape = shape ??
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Colors.white.withOpacity(0.12)),
        );
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
        child: AlertDialog(
          backgroundColor: Colors.white.withOpacity(0.075),
          surfaceTintColor: Colors.transparent,
          shadowColor: Colors.black.withOpacity(0.22),
          shape: dialogShape,
          title: title,
          titlePadding: titlePadding,
          content: content,
          contentPadding: contentPadding ?? const EdgeInsets.fromLTRB(24, 20, 24, 24),
          actions: actions,
          actionsPadding: actionsPadding,
          actionsAlignment: actionsAlignment,
          actionsOverflowAlignment: actionsOverflowAlignment,
          actionsOverflowDirection: actionsOverflowDirection,
          actionsOverflowButtonSpacing: actionsOverflowButtonSpacing,
          insetPadding: insetPadding ?? const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
          scrollable: scrollable,
        ),
      ),
    );
  }
}

/// Generic transparent blurred Dialog wrapper for custom modal bodies.
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
    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      insetPadding: insetPadding,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.075),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withOpacity(0.12)),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}
