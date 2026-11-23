// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Универсальный диалог подтверждения. Возвращает true / false / null.

import 'package:flutter/material.dart';
import 'glass_dialog.dart';

Future<bool?> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Да',
  String cancelLabel = 'Отмена',
}) {
  return showDialog<bool>(
    context: context,
    barrierColor: Colors.transparent,
    builder: (ctx) => GlassAlertDialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Colors.white.withOpacity(0.1)),
      ),
      title: Text(title),
      content: Text(
        message,
        style: const TextStyle(color: Colors.white70, height: 1.45),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(cancelLabel),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
}
