// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Caches the stationary wallpaper blur for glass surfaces on older Android
/// devices. The cached image is sampled in wallpaper coordinates as pages move.
class CachedGlassBackdrop extends StatefulWidget {
  const CachedGlassBackdrop({
    super.key,
    required this.wallpaper,
    required this.tint,
    required this.child,
  });

  final ImageProvider wallpaper;
  final Gradient tint;
  final Widget child;

  static Future<bool> isPreferred() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      return await const MethodChannel(
            'com.lalune/native',
          ).invokeMethod<bool>('preferCachedGlass') ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Returns a wallpaper sample when the cache is ready and the requested
  /// radius is available. Callers can fall back to a live blur.
  static Widget? sample(
    BuildContext context,
    double sigma, {
    bool fixed = false,
  }) {
    final cache = context.dependOnInheritedWidgetOfExactType<_GlassCache>();
    final image = cache?.images[sigma];
    if (cache == null || image == null) return null;
    if (fixed) {
      return IgnorePointer(
        child: _FixedWallpaperSample(
          target: cache.target,
          image: image,
          wallpaperSize: cache.size,
        ),
      );
    }
    return IgnorePointer(
      child: CompositedTransformFollower(
        link: cache.link,
        showWhenUnlinked: false,
        child: CustomPaint(painter: _WallpaperSample(image, cache.size)),
      ),
    );
  }

  @override
  State<CachedGlassBackdrop> createState() => _CachedGlassBackdropState();
}

class _CachedGlassBackdropState extends State<CachedGlassBackdrop> {
  final _link = LayerLink();
  final _target = GlobalKey();
  Map<double, ui.Image> _images = const {};
  ImageStream? _stream;
  ImageInfo? _wallpaper;
  Size? _requestedSize;
  Size? _cachedSize;
  int _generation = 0;
  late final ImageStreamListener _listener = ImageStreamListener(
    _wallpaperReady,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolveWallpaper();
  }

  @override
  void didUpdateWidget(CachedGlassBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.wallpaper != oldWidget.wallpaper ||
        widget.tint != oldWidget.tint) {
      _requestedSize = null;
      _generation++;
      _resolveWallpaper();
    }
  }

  void _resolveWallpaper() {
    final stream = widget.wallpaper.resolve(
      createLocalImageConfiguration(context),
    );
    if (stream.key == _stream?.key) return;
    _stream?.removeListener(_listener);
    _stream = stream..addListener(_listener);
  }

  void _wallpaperReady(ImageInfo image, bool synchronousCall) {
    _wallpaper?.dispose();
    _wallpaper = image;
    _requestedSize = null;
    _generation++;
    if (!synchronousCall) setState(() {});
  }

  Future<void> _prepareImages(Size size, int generation) async {
    if (!mounted || generation != _generation) return;
    final source = _wallpaper?.image.clone();
    if (source == null) return;
    final images = <double, ui.Image>{};
    try {
      for (final sigma in [14.0, 16.0, 0.0]) {
        images[sigma] = await _renderWallpaper(source, size, sigma);
        if (!mounted || generation != _generation) return;
      }
      setState(() {
        for (final image in _images.values) {
          image.dispose();
        }
        _images = Map.of(images);
        _cachedSize = size;
        images.clear();
      });
    } catch (error) {
      debugPrint('Could not cache glass wallpaper: $error');
    } finally {
      source.dispose();
      for (final image in images.values) {
        image.dispose();
      }
    }
  }

  Future<ui.Image> _renderWallpaper(
    ui.Image source,
    Size size,
    double sigma,
  ) async {
    // The wallpaper is already soft and is blurred much further here. At half
    // logical resolution the two textures are small even on high-DPI phones.
    final scale = sigma == 0 ? 1.0 : 0.5;
    final width = (size.width * scale).ceil();
    final height = (size.height * scale).ceil();
    final rect = Offset.zero & size;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)
      ..scale(width / size.width, height / size.height);
    if (sigma > 0) {
      canvas.saveLayer(
        rect,
        Paint()
          ..imageFilter = ui.ImageFilter.blur(
            sigmaX: sigma,
            sigmaY: sigma,
            tileMode: TileMode.clamp,
          ),
      );
    }
    paintImage(canvas: canvas, rect: rect, image: source, fit: BoxFit.cover);
    if (sigma > 0) canvas.restore();
    canvas.drawRect(rect, Paint()..shader = widget.tint.createShader(rect));
    final picture = recorder.endRecording();
    try {
      return await picture.toImage(width, height);
    } finally {
      picture.dispose();
    }
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener);
    _wallpaper?.dispose();
    for (final image in _images.values) {
      image.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        if (_wallpaper != null &&
            size.isFinite &&
            !size.isEmpty &&
            size != _requestedSize) {
          _requestedSize = size;
          final generation = ++_generation;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _prepareImages(size, generation);
          });
        }
        final images =
            size == _cachedSize ? _images : const <double, ui.Image>{};
        final wallpaper = images[0];
        return _GlassCache(
          link: _link,
          target: _target,
          size: size,
          images: images,
          child: Stack(
            fit: StackFit.expand,
            children: [
              CompositedTransformTarget(
                key: _target,
                link: _link,
                child: RepaintBoundary(
                  child:
                      wallpaper != null
                          ? RawImage(image: wallpaper, fit: BoxFit.fill)
                          : DecoratedBox(
                            decoration: BoxDecoration(
                              image: DecorationImage(
                                image: widget.wallpaper,
                                fit: BoxFit.cover,
                              ),
                            ),
                            child: DecoratedBox(
                              decoration: BoxDecoration(gradient: widget.tint),
                            ),
                          ),
                ),
              ),
              widget.child,
            ],
          ),
        );
      },
    );
  }
}

class _GlassCache extends InheritedWidget {
  const _GlassCache({
    required this.link,
    required this.target,
    required this.size,
    required this.images,
    required super.child,
  });

  final LayerLink link;
  final GlobalKey target;
  final Size size;
  final Map<double, ui.Image> images;

  @override
  bool updateShouldNotify(_GlassCache oldWidget) =>
      size != oldWidget.size || images != oldWidget.images;
}

class _WallpaperSample extends CustomPainter {
  const _WallpaperSample(this.image, this.wallpaperSize);

  final ui.Image image;
  final Size wallpaperSize;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Offset.zero & wallpaperSize,
      Paint()..filterQuality = FilterQuality.low,
    );
  }

  @override
  bool shouldRepaint(_WallpaperSample oldDelegate) =>
      oldDelegate.image != image || oldDelegate.wallpaperSize != wallpaperSize;
}

/// Fixed surfaces can retain their paint when the scrolling page moves.
class _FixedWallpaperSample extends LeafRenderObjectWidget {
  const _FixedWallpaperSample({
    required this.target,
    required this.image,
    required this.wallpaperSize,
  });

  final GlobalKey target;
  final ui.Image image;
  final Size wallpaperSize;

  @override
  _RenderFixedWallpaperSample createRenderObject(BuildContext context) =>
      _RenderFixedWallpaperSample(target, image, wallpaperSize);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderFixedWallpaperSample renderObject,
  ) {
    renderObject.update(target, image, wallpaperSize);
  }
}

class _RenderFixedWallpaperSample extends RenderBox {
  _RenderFixedWallpaperSample(this._target, this._image, this._wallpaperSize);

  GlobalKey _target;
  ui.Image _image;
  Size _wallpaperSize;
  final _paint = Paint()..filterQuality = FilterQuality.low;

  void update(GlobalKey target, ui.Image image, Size wallpaperSize) {
    if (_target == target &&
        _image == image &&
        _wallpaperSize == wallpaperSize) {
      return;
    }
    _target = target;
    _image = image;
    _wallpaperSize = wallpaperSize;
    markNeedsPaint();
  }

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void paint(PaintingContext context, Offset offset) {
    final wallpaper = _target.currentContext?.findRenderObject();
    if (wallpaper is! RenderBox || !wallpaper.attached) return;
    final origin =
        localToGlobal(Offset.zero) - wallpaper.localToGlobal(Offset.zero);
    final scaleX = _image.width / _wallpaperSize.width;
    final scaleY = _image.height / _wallpaperSize.height;
    context.canvas.drawImageRect(
      _image,
      Rect.fromLTWH(
        origin.dx * scaleX,
        origin.dy * scaleY,
        size.width * scaleX,
        size.height * scaleY,
      ),
      offset & size,
      _paint,
    );
  }
}
