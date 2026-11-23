// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'glass_dialog.dart';

typedef GlassSelectTrailingBuilder = Widget? Function(
  BuildContext context,
  String value,
);

/// Dropdown replacement whose option list is itself a dark frosted-glass modal.
class GlassSelectField extends StatelessWidget {
  final String value;
  final List<String> items;
  final ValueChanged<String> onChanged;
  final String? title;
  final GlassSelectTrailingBuilder? trailingBuilder;
  final bool enabled;

  const GlassSelectField({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.title,
    this.trailingBuilder,
    this.enabled = true,
  });

  Future<void> _open(BuildContext context) async {
    if (!enabled || items.isEmpty) return;
    final selected = await showDialog<String>(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black.withOpacity(0.42),
      builder: (dialogContext) => GlassAlertDialog(
        title: Text(title ?? 'Выберите значение'),
        contentPadding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440, maxHeight: 420),
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: items.length,
            separatorBuilder: (_, __) => Divider(
              height: 1,
              color: Colors.white.withOpacity(0.08),
            ),
            itemBuilder: (context, index) {
              final item = items[index];
              final active = item == value;
              return ListTile(
                dense: true,
                visualDensity: VisualDensity.compact,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                tileColor:
                    active ? kAccent.withOpacity(0.18) : Colors.transparent,
                leading: Icon(
                  active ? Icons.radio_button_checked : Icons.radio_button_off,
                  size: 18,
                  color: active ? kAccentGreen : Colors.white60,
                ),
                title: Text(
                  item,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: active ? kAccentWhite : Colors.white.withOpacity(0.92),
                    fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
                trailing: trailingBuilder?.call(context, item),
                onTap: () => Navigator.of(dialogContext).pop(item),
              );
            },
          ),
        ),
      ),
    );
    if (selected != null && selected != value) onChanged(selected);
  }

  @override
  Widget build(BuildContext context) {
    final trailing = trailingBuilder?.call(context, value);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? () => _open(context) : null,
        borderRadius: BorderRadius.circular(12),
        child: InputDecorator(
          isEmpty: value.isEmpty,
          decoration: const InputDecoration(
            isDense: true,
            border: OutlineInputBorder(),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    color: enabled ? kAccentWhite : Colors.white38,
                  ),
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 4),
                trailing,
              ],
              const SizedBox(width: 8),
              Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 20,
                color: enabled ? kAccentGreen : Colors.white30,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
