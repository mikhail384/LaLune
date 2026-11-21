// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/assets.dart';

class NavBar extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onSelect;

  const NavBar({
    super.key,
    required this.currentIndex,
    required this.onSelect,
  });

  static const _items = [
    _NavItem(icon: Assets.connect, label: 'Подключение'),
    _NavItem(icon: Assets.settings, label: 'Настройки'),
    _NavItem(icon: Assets.info, label: 'Информация'),
    _NavItem(icon: Assets.logs, label: 'Логи'),
  ];

  @override
  Widget build(BuildContext context) {
    final isAndroid = !kIsWeb && defaultTargetPlatform == TargetPlatform.android; final borderRadius = BorderRadius.circular(20);
    final bar = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            const Color(0xFF0B2118).withOpacity(isAndroid ? 0.88 : 0.52),
            const Color(0xFF07160F).withOpacity(isAndroid ? 0.82 : 0.42),
          ],
        ),
        borderRadius: borderRadius,
        border: Border.all(color: Colors.white.withOpacity(isAndroid ? 0.16 : 0.15), width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: List.generate(_items.length, (i) {
            return Expanded(
              child: _NavButton(
                item: _items[i],
                selected: i == currentIndex,
                onTap: () => onSelect(i),
              ),
            );
          }),
        ),
      ),
    );

    final sigma =
      14.0;  
    final filter = ImageFilter.blur(
      sigmaX: sigma,
      sigmaY: sigma,
      tileMode: TileMode.clamp,
    );
    final content = isAndroid ? ClipRRect(borderRadius: borderRadius, child: bar) : DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.28),
            blurRadius: isAndroid ? 10 : 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: BackdropGroup.of(context) == null
            ? BackdropFilter(filter: filter, child: bar)
            : BackdropFilter.grouped(filter: filter, child: bar),
      ),
    );

    return SafeArea(
      top: false,
      child: RepaintBoundary(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
          child: content,
        ),
      ),
    );
  }
}

class _NavItem {
  final String icon;
  final String label;
  const _NavItem({required this.icon, required this.label});
}

class _NavButton extends StatefulWidget {
  final _NavItem item;
  final bool selected;
  final VoidCallback onTap;

  const _NavButton({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_NavButton> createState() => _NavButtonState();
}

class _NavButtonState extends State<_NavButton> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.selected;
    final isAndroid = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    final scale = _pressed ? 0.90 : (_hover ? 0.96 : 1.0);
    const activeColor = kAccentGreen;

    final chipColor = active
        ? activeColor.withOpacity(0.16)
        : (_hover ? Colors.white.withOpacity(0.09) : Colors.transparent);

    final chipBorder = active
        ? activeColor.withOpacity(0.32)
        : (_hover ? Colors.white.withOpacity(0.20) : Colors.transparent);

    final labelColor =
        active ? activeColor : Colors.white.withOpacity(_hover ? 0.94 : 0.60);

    final iconOpacity = active ? 1.0 : (_hover ? 0.98 : 0.80);
    final iconSize = widget.item.icon == Assets.info ? 28.0 : 25.0;

    return Semantics(
      button: true,
      selected: active,
      label: widget.item.label,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() {
          _hover = false;
          _pressed = false;
        }),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 3),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedScale(
                  scale: scale,
                  duration: const Duration(milliseconds: 140),
                  curve: Curves.easeOutCubic,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 140),
                    curve: Curves.easeOut,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                    decoration: BoxDecoration(
                      color: chipColor,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: chipBorder, width: 1),
                    ),
                    child: SizedBox(
                      width: 28,
                      height: 28,
                      child: Center(
                        child: Image.asset(
                            widget.item.icon,
                            width: iconSize,
                            height: iconSize,
                            cacheWidth: isAndroid ? 64 : 96,
                            color: Colors.white.withOpacity(iconOpacity),
                            colorBlendMode: BlendMode.modulate,
                            fit: BoxFit.contain,
                            filterQuality: isAndroid ? FilterQuality.low : FilterQuality.medium,
                            errorBuilder: (_, __, ___) => Icon(
                              Icons.circle_outlined,
                              size: 24,
                              color: active
                                  ? activeColor
                                  : Colors.white.withOpacity(0.7),
                            ),
                          ),
                      ),                    
                  ),
                ),
                ),
                const SizedBox(height: 3),
                AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 140),
                  style: TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 10.5,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w600,
                    color: labelColor,
                  ),
                  child: Text(
                    widget.item.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 2),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  curve: Curves.easeOut,
                  width: active ? 16 : 0,
                  height: 2.5,
                  decoration: BoxDecoration(
                    color: activeColor,
                    borderRadius: BorderRadius.circular(2),
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
