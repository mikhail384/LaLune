// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/assets.dart';

/// Кнопка-луна. Свечение — два статичных слоя (красный и зелёный), которые
/// плавно переключаются изменением прозрачности. Так дорогой blur тени
/// растеризуется один раз и не пересчитывается на каждом кадре анимации.
class MoonButton extends StatefulWidget {
  final bool connected;
  final VoidCallback onTap;

  const MoonButton({super.key, required this.connected, required this.onTap});

  @override
  State<MoonButton> createState() => _MoonButtonState();
}

class _MoonButtonState extends State<MoonButton> {
  bool _hover = false;
  bool _pressed = false;

  static const _red = Color(0xFFE5484D);
  static const _green = Color(0xFF7CFF9A);

  @override
  Widget build(BuildContext context) {
    // Те же итоговые яркости, что были у анимированной тени:
    // красный 0.20 (0.45 при наведении), зелёный 0.55.
    final redOpacity = widget.connected ? 0.0 : (_hover ? 1.0 : 0.20 / 0.45);
    final greenOpacity = widget.connected ? 1.0 : 0.0;
    final scale = _pressed ? 0.92 : (_hover ? 1.03 : 1.0);
    final ringColor = widget.connected
        ? _green.withOpacity(_hover ? 0.55 : 0.36)
        : (_hover
            ? _red.withOpacity(0.45)
            : Colors.white.withOpacity(0.14));

    return Semantics(
      button: true,
      toggled: widget.connected,
      label: widget.connected ? 'Отключить VPN' : 'Подключить VPN',
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() {
          _hover = false;
          _pressed = false;
        }),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          onTap: widget.onTap,
          child: AnimatedScale(
            scale: scale,
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
            child: RepaintBoundary(
              child: Stack(
                alignment: Alignment.center,
                clipBehavior: Clip.none,
                children: [
                  _Glow(color: _red.withOpacity(0.45), opacity: redOpacity),
                  _Glow(color: _green.withOpacity(0.55), opacity: greenOpacity),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 240),
                    curve: Curves.easeOut,
                    width: 152,
                    height: 152,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withOpacity(_hover ? 0.05 : 0.025),
                      border: Border.all(color: ringColor, width: 1.25),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(10),
                    child: Image.asset(
                      Assets.lune,
                      width: 130,
                      height: 130,
                      // Ресурс 512 px: декодируем не больше нужного.
                      cacheWidth: 260,
                      filterQuality: (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) ? FilterQuality.low : FilterQuality.medium,
                      errorBuilder: (_, __, ___) => Container(
                        width: 130,
                        height: 130,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: Color(0xFF0B2118),
                        ),
                        child: Icon(
                          Icons.dark_mode,
                          size: 72,
                          color: widget.connected ? _green : _red,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Glow extends StatelessWidget {
  final Color color;
  final double opacity;

  const _Glow({required this.color, required this.opacity});

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: opacity,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
      child: RepaintBoundary(
        child: SizedBox(
          width: 210,
          height: 210,
          child: DecoratedBox(
            decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(colors: [color, color.withOpacity(0.26), Colors.transparent], stops: const [0.42, 0.70, 1.0]),
          ),),
          
        ),
      ),
    );
  }
}
