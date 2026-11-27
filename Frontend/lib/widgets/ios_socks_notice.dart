// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// iOS-пояснение к схеме работы VPN: собственного системного туннеля у нас нет
// (нет Apple Developer → нет NetworkExtension), поэтому LaLune поднимает
// локальный SOCKS5 и регистрирует его в приложении incy. Там же объясняется
// «режим звонка» и зачем приложению микрофон.
//
// Кнопка «!» показывается только на iOS рядом со значком QR.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'glass_dialog.dart';

bool get isIosPlatform =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

/// Кнопка «!» в том же стиле, что и соседние круглые кнопки QR/«+».
class IosSocksNoticeButton extends StatefulWidget {
  const IosSocksNoticeButton({super.key, this.size = 42, this.iconSize = 22});

  final double size;
  final double iconSize;

  @override
  State<IosSocksNoticeButton> createState() => _IosSocksNoticeButtonState();
}

class _IosSocksNoticeButtonState extends State<IosSocksNoticeButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: Semantics(
        label: 'Как работает VPN на iOS',
        button: true,
        child: GestureDetector(
          onTap: () => showIosSocksNotice(context),
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withOpacity(_hover ? 0.14 : 0.07),
              border: Border.all(
                color: const Color(0xFFE5484D)
                    .withOpacity(_hover ? 0.72 : 0.42),
              ),
            ),
            child: Icon(
              Icons.priority_high_rounded,
              size: widget.iconSize,
              color: const Color(0xFFF7FBF8),
            ),
          ),
        ),
      ),
    );
  }
}

/// Компактный вариант для строки с текстом (страница «Инфо»).
class IosSocksNoticeIcon extends StatelessWidget {
  const IosSocksNoticeIcon({super.key});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Как работает VPN на iOS',
      onPressed: () => showIosSocksNotice(context),
      iconSize: 18,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      icon: const Icon(Icons.priority_high_rounded,
          color: Color(0xFFE5484D)),
    );
  }
}

Future<void> showIosSocksNotice(BuildContext context) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.transparent,
    builder: (ctx) => GlassAlertDialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Colors.white.withOpacity(0.1)),
      ),
      title: const Row(
        children: [
          Icon(Icons.priority_high_rounded, color: Color(0xFFE5484D), size: 20),
          SizedBox(width: 8),
          Expanded(child: Text('Как работает VPN на iOS')),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _paragraph(
              'Приложение работает через SOCKS5 → incy. Собственного системного '
              'туннеля у нас нет: для него нужен Apple Developer, а у нас его нет, '
              'поэтому NetworkExtension недоступен.',
            ),
            _paragraph(
              'Поэтому системный VPN поднимает incy. LaLune запускает ядро CSQTT '
              'внутри себя, поднимает локальный SOCKS5 и автоматически добавляет '
              'и активирует в incy готовый конфиг. В нём уже прописана '
              'маршрутизация: локальные адреса и сервисы VK, MAX и другие '
              'адреса, которые нужны самому VPN, идут напрямую, а не через туннель.',
            ),
            _paragraph(
              'Что нужно от вас: установленное приложение incy и хотя бы один '
              'запуск incy вручную — без этого оно не примет конфиг и не поднимет '
              'VPN. Если после подключения VPN не появился, откройте incy и '
              'выберите конфиг LaLune.',
            ),
            _paragraph(
              'Чтобы iOS не усыпляла приложение в фоне (без этого соединение '
              'рвётся примерно через 30 секунд), LaLune включает «режим звонка»: '
              'открывает микрофон и проигрывает локально сгенерированный тихий '
              'звук — как будто идёт звонок. Слышно ничего не будет, запись не '
              'сохраняется и никуда не отправляется.',
            ),
            _paragraph(
              'Если у вас есть аккаунт Apple Developer и вы хотите помочь проекту — '
              'напишите в сообщения нашего канала.',
            ),
          ],
        ),
      ),
      actions: [
        ElevatedButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Закрыть'),
        ),
      ],
    ),
  );
}

Widget _paragraph(String text) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(
      text,
      style: const TextStyle(
        color: Colors.white70,
        height: 1.45,
        fontSize: 12.5,
      ),
    ),
  );
}
