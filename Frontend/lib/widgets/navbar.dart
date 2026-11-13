// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import 'dart:ui';
import 'package:flutter/material.dart';

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
    final borderRadius = BorderRadius.circular(18);
    final bar = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.06),
        borderRadius: borderRadius,
        border: Border.all(color: Colors.white.withOpacity(0.12), width: 1),
      ),
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
    );
    // Keep the translucent surface but skip its costly blur pass on Android.
    final content = Theme.of(context).platform == TargetPlatform.android
        ? bar
        : ClipRRect(
            borderRadius: borderRadius,
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: bar,
            ),
          );

    return RepaintBoundary(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
        child: content,
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

  @override
  Widget build(BuildContext context) {
    final active = widget.selected;
    final scale = _hover ? 0.92 : 1.0;
    const activeColor = Color(0xFF8FA9FF);

    final chipColor = active
        ? activeColor.withOpacity(0.12)
        : (_hover ? Colors.white.withOpacity(0.10) : Colors.transparent);

    final chipBorder = active
        ? Colors.transparent
        : (_hover ? Colors.white.withOpacity(0.22) : Colors.transparent);

    final labelColor = active
        ? activeColor
        : Colors.white.withOpacity(_hover ? 0.95 : 0.55);

    final iconOpacity = active ? 1.0 : (_hover ? 1.0 : 0.85);

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedScale(
                scale: scale,
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOut,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: chipColor,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: chipBorder, width: 1),
                  ),
                  child: AnimatedOpacity(
                    opacity: iconOpacity,
                    duration: const Duration(milliseconds: 180),
                    child: Image.asset(
                      widget.item.icon,
                      width: 26,
                      height: 26,
                      fit: BoxFit.contain,
                      filterQuality: FilterQuality.medium,
                      errorBuilder: (_, __, ___) => Icon(
                        Icons.circle_outlined,
                        size: 26,
                        color: active
                            ? activeColor
                            : Colors.white.withOpacity(0.7),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 3),
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 200),
                style: TextStyle(
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
            ],
          ),
        ),
      ),
    );
  }
}
