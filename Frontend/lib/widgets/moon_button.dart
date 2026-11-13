// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import 'package:flutter/material.dart';

import '../theme/assets.dart';

/// Кнопка-луна. Свечение — два статичных слоя (жёлтый и зелёный), которые
/// плавно переключаются изменением прозрачности. Так дорогой блюр тени
/// растеризуется один раз и не пересчитывается на каждом кадре анимации
/// (раньше анимировался сам BoxShadow с blurRadius 34).
class MoonButton extends StatefulWidget {
  final bool connected;
  final VoidCallback onTap;

  const MoonButton({super.key, required this.connected, required this.onTap});

  @override
  State<MoonButton> createState() => _MoonButtonState();
}

class _MoonButtonState extends State<MoonButton> {
  bool _hover = false;

  static const _yellow = Color(0xFFF7E84E);
  static const _green = Color(0xFF7CFF9A);

  @override
  Widget build(BuildContext context) {
    // Те же итоговые яркости, что были у анимированной тени:
    // жёлтый 0.20 (0.45 при наведении), зелёный 0.55.
    final yellowOpacity = widget.connected ? 0.0 : (_hover ? 1.0 : 0.20 / 0.45);
    final greenOpacity = widget.connected ? 1.0 : 0.0;

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _hover ? 0.94 : 1.0,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          child: RepaintBoundary(
            child: Stack(
              alignment: Alignment.center,
              clipBehavior: Clip.none,
              children: [
                _Glow(color: _yellow.withOpacity(0.45), opacity: yellowOpacity),
                _Glow(color: _green.withOpacity(0.55), opacity: greenOpacity),
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: Image.asset(
                    Assets.lune,
                    width: 130,
                    height: 130,
                    // Ресурс 512 px: декодируем не больше нужного.
                    cacheWidth: 390,
                    errorBuilder: (_, __, ___) => Container(
                      width: 130,
                      height: 130,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: Color(0xFF1A1A3E),
                      ),
                      child: const Icon(Icons.dark_mode,
                          size: 72, color: Color(0xFFF7E84E)),
                    ),
                  ),
                ),
              ],
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
      child: RepaintBoundary(
        child: Container(
          width: 150,
          height: 150,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(color: color, blurRadius: 34, spreadRadius: 4),
            ],
          ),
        ),
      ),
    );
  }
}
