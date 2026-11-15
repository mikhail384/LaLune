// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Runtime shader used only as a very cheap glass grain/highlight layer.
///
/// The old dialogs used a sigma=22 backdrop blur over the entire modal on
/// every frame. That is especially expensive on tile-based mobile GPUs. We
/// keep a much smaller Android blur for readability, isolate it in a
/// RepaintBoundary, and let the shader provide most of the visual texture.
class _GlassShaderOverlay extends StatelessWidget {
  const _GlassShaderOverlay();

  static Future<FragmentProgram>? _program;

  static Future<FragmentProgram> _loadProgram() =>
      _program ??= FragmentProgram.fromAsset('shaders/glass_modal.frag');

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) return const SizedBox.expand();
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
  if (kIsWeb) return 12;
  return defaultTargetPlatform == TargetPlatform.android ? 5.5 : 16;
}

Widget _glassLayer({required Widget child, required BorderRadius borderRadius}) {
  final blur = _dialogBlurSigma();
  return RepaintBoundary(
    child: ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            Positioned.fill(child: _GlassShaderOverlay()),
            child,
          ],
        ),
      ),
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
          side: BorderSide(color: Colors.white.withOpacity(0.12)),
        );
    return _glassLayer(
      borderRadius: radius,
      child: AlertDialog(
        backgroundColor: backgroundColor ?? Colors.white.withOpacity(0.068),
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.black.withOpacity(0.18),
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
        borderRadius: radius,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: backgroundColor ?? Colors.white.withOpacity(0.068),
            borderRadius: radius,
            border: Border.all(color: Colors.white.withOpacity(0.12)),
          ),
          child: child,
        ),
      ),
    );
  }
}
