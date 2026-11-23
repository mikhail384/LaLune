// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../theme/app_theme.dart';
import 'glass_dialog.dart';

Future<String?> showQrScannerDialog(BuildContext context) {
  return showDialog<String>(
    context: context,
    barrierDismissible: true,
    barrierColor: Colors.transparent,
    useRootNavigator: true,
    builder: (_) => const _QrScannerDialog(),
  );
}

class _QrScannerDialog extends StatefulWidget {
  const _QrScannerDialog();

  @override
  State<_QrScannerDialog> createState() => _QrScannerDialogState();
}

class _QrScannerDialogState extends State<_QrScannerDialog> {
  late final MobileScannerController _controller;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    _controller = MobileScannerController(
      formats: const [BarcodeFormat.qrCode],
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_finished) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue?.trim();
      if (value == null || value.isEmpty) continue;
      _finished = true;
      Navigator.of(context, rootNavigator: true).pop(value);
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final previewHeight = (size.height * 0.58).clamp(280.0, 520.0).toDouble();

    return GlassDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 28),
      child: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 10),
              child: Row(
                children: [
                  const Icon(Icons.qr_code_scanner_rounded,
                      color: kAccent, size: 22),
                  const SizedBox(width: 9),
                  const Expanded(
                    child: Text(
                      'Сканировать QR',
                      style:
                          TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Закрыть',
                    onPressed: () =>
                        Navigator.of(context, rootNavigator: true).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: SizedBox(
                height: previewHeight,
                width: double.infinity,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    MobileScanner(
                      controller: _controller,
                      fit: BoxFit.cover,
                      onDetect: _onDetect,
                      errorBuilder: (context, error) {
                        final denied =
                            error.errorCode == MobileScannerErrorCode.permissionDenied;
                        return Container(
                          color: Colors.black.withOpacity(0.72),
                          alignment: Alignment.center,
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                denied
                                    ? Icons.no_photography_outlined
                                    : Icons.camera_alt_outlined,
                                size: 42,
                                color: kAccentRed,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                denied
                                    ? 'Доступ к камере отклонён. Разрешите камеру для LaLune в настройках Android и откройте сканер снова.'
                                    : 'Не удалось запустить камеру: ${error.errorCode.name}',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                    color: Colors.white, height: 1.35),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                    IgnorePointer(
                      child: Center(
                        child: Container(
                          width: 220,
                          height: 220,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(22),
                            border: Border.all(color: kAccentWhite, width: 2),
                            boxShadow: [
                              BoxShadow(
                                color: kAccent.withOpacity(0.32),
                                blurRadius: 20,
                                spreadRadius: 3,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 11, 16, 15),
              child: Text(
                'Поддерживаются CSQTT, CSQTTR, ToTS и ссылки подписок HTTP/HTTPS.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.62),
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
