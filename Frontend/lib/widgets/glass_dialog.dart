// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Runtime shader used as a light glass grain/highlight layer.
///
/// On Android the real backdrop blur is intentionally small: large sigma
/// values over animated content were one of the biggest sources of jank.
class _GlassShaderOverlay extends StatelessWidget {
  const _GlassShaderOverlay();

  static Future<FragmentProgram>? _program;

  static Future<FragmentProgram> _loadProgram() =>
      _program ??= FragmentProgram.fromAsset('shaders/glass_modal.frag');

  @override
  Widget build(BuildContext context) {
    if (kIsWeb || defaultTargetPlatform == TargetPlatform.android) return const SizedBox.expand();
    return IgnorePointer(
      child: FutureBuilder<FragmentProgram>(
        future: _loadProgram(),
        builder: (context, snapshot) {
          final program = snapshot.data;
          if (program == null) return const SizedBox.expand();
          return CustomPaint(
            painter: _GlassShaderPainter(program),
            child: const SizedBox.expand(),
          );
        },
      ),
    );
  }
}

class _GlassShaderPainter extends CustomPainter {
  final FragmentProgram program;
  const _GlassShaderPainter(this.program);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final shader = program.fragmentShader()
      ..setFloat(0, size.width)
      ..setFloat(1, size.height);
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(covariant _GlassShaderPainter oldDelegate) =>
      oldDelegate.program != program;
}

double _dialogBlurSigma() {
  if (kIsWeb) return 10;
  return defaultTargetPlatform == TargetPlatform.android ? 5.0 : 14;
}

Color _translucentSurface(Color? requested) {
  if (requested == null) return Colors.white.withOpacity(0.06);
  // Never allow a caller to accidentally turn a glass dialog into a solid
  // Material surface. Existing callers that pass the old navy color still
  // receive the requested tint, but with glass-safe alpha.
  return requested.withOpacity(0.12);
}

Widget _glassLayer(
  BuildContext context, {
  required Widget child,
  required BorderRadius borderRadius,
}) {
  final isAndroid = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  final stack = Stack(
    fit: StackFit.passthrough,
    children: [
      if (!isAndroid) const Positioned.fill(child: _GlassShaderOverlay()),
      child,
    ],
  );

  // Android: avoid BackdropFilter entirely for modal surfaces. Even a small
  // sigma forces repeated offscreen backdrop captures while lists/keyboard are
  // moving and was causing visible jank on phones. The translucent dialog
  // surface itself is retained, so the modal stays glass-like without changing
  // the page behind it or paying the blur cost.
  if (isAndroid) {
    return RepaintBoundary(
      child: ClipRRect(borderRadius: borderRadius, child: stack),
    );
  }

  final blur = _dialogBlurSigma();
  final filter = ImageFilter.blur(sigmaX: blur, sigmaY: blur);
  return RepaintBoundary(
    child: ClipRRect(
      borderRadius: borderRadius,
      // Keep modal blur local to the dialog. Joining the app-level
      // BackdropGroup can wash out the whole route while a modal is open.
      child: BackdropFilter(filter: filter, child: stack),
    ),
  );
}

/// AlertDialog with a translucent surface and mobile-optimized glass effect.
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
    final radius = BorderRadius.circular(16);
    final dialogShape = shape ??
        RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(color: Colors.white.withOpacity(0.14)),
        );

    return _glassLayer(
      context,
      borderRadius: radius,
      child: AlertDialog(
        backgroundColor: _translucentSurface(backgroundColor),
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.black.withOpacity(0.14),
        shape: dialogShape,
        title: title,
        titlePadding: titlePadding,
        content: content,
        contentPadding:
            contentPadding ?? const EdgeInsets.fromLTRB(24, 20, 24, 24),
        actions: actions,
        actionsPadding: actionsPadding,
        actionsAlignment: actionsAlignment,
        actionsOverflowAlignment: actionsOverflowAlignment,
        actionsOverflowDirection: actionsOverflowDirection,
        actionsOverflowButtonSpacing: actionsOverflowButtonSpacing,
        insetPadding: insetPadding ??
            const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
        scrollable: scrollable,
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
    final radius = BorderRadius.circular(16);
    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      insetPadding: insetPadding,
      child: _glassLayer(
        context,
        borderRadius: radius,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: _translucentSurface(backgroundColor),
            borderRadius: radius,
            border: Border.all(color: Colors.white.withOpacity(0.14)),
          ),
          child: child,
        ),
      ),
    );
  }
}
