// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// LaLune — точка входа Flutter-приложения.
//
// Архитектура:
//   Flutter UI ⟷ HTTP API (127.0.0.1:1062 или IP роутера) ⟷ платформенный бэкенд.
//
// Бэкенд запускается платформенным runner'ом:
//   * Linux   — main.cc запускает ~/.la-lune/LaLuneManager (через GUI sudo),
//               при закрытии окна шлёт POST /shutdown.
//   * Windows — main.cpp запускает %APPDATA%\.la-lune\LaLuneManager.exe
//               (манифест runas → UAC), WM_CLOSE → POST /shutdown.
//   * Android — MainActivity.onCreate → Backend(ctx).attachActivity(this).run(),
//               watchdog каждые 3 сек перезапускает Backend при смерти.
//   * iOS     — AppDelegate → Backend.shared.attach(window:).run(),
//               watchdog каждые 3 сек перезапускает Backend.
//
// OpenWRT:
//   Пользователь может подключиться к роутеру через
//   Настройки → Экспериментальное → Роутеры → «Подключить OpenWRT».
//   Тогда все API-запросы идут на IP роутера. Сверху показывается
//   зелёный баннер. При отключении — возврат на 127.0.0.1.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api/api_client.dart';
import 'backend_watchdog.dart';
import 'pages/connection_page.dart';
import 'pages/info_page.dart';
import 'pages/logs_page.dart';
import 'pages/settings_page.dart';
import 'state/configs_notifier.dart';
import 'theme/app_theme.dart';
import 'widgets/navbar.dart';
import 'widgets/router_banner.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ApiClient.initializeLocalPort();
  runApp(const ProviderScope(child: LaLuneApp()));
}

class LaLuneApp extends StatelessWidget {
  const LaLuneApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LaLune',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: const RootShell(),
    );
  }
}

class RootShell extends ConsumerStatefulWidget {
  const RootShell({super.key});

  @override
  ConsumerState<RootShell> createState() => _RootShellState();
}

class _RootShellState extends ConsumerState<RootShell> {
  static const _pageTransitionDuration = Duration(milliseconds: 280);

  int _currentPage = 0;
  late final PageController _pageController;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(backendWatchdogProvider);
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  // ConfigsNotifier already refreshes the list after add/delete. Avoid
  // remounting the whole page, which caused visible flashes on Android.
  void _reloadConnection() {}

  void _onNavSelect(int i) {
    if (i == _currentPage || i < 0 || i >= 4) return;
    setState(() => _currentPage = i);
    _pageController.animateToPage(
      i,
      duration: _pageTransitionDuration,
      curve: Curves.easeInOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final backendStatus = ref.watch(backendWatchdogProvider);
    // Backend снова отвечает — догружаем список конфигов, если прошлая
    // загрузка не удалась (no-op, когда список уже загружен).
    ref.listen<BackendStatus>(backendWatchdogProvider, (prev, next) {
      if (next == BackendStatus.alive) {
        ref.read(configsProvider.notifier).reloadIfNeeded();
      }
    });

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          image: DecorationImage(
            image: AssetImage('assets/background.png'),
            fit: BoxFit.cover,
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              // Глобальный зелёный баннер, если подключены к OpenWRT-роутеру.
              const RouterBanner(),
              if (backendStatus == BackendStatus.dead) _BackendOfflineBanner(),
              Expanded(
                child: RepaintBoundary(
                  child: PageView(
                    controller: _pageController,
                    physics: const PageScrollPhysics(
                      parent: ClampingScrollPhysics(),
                    ),
                    onPageChanged: (i) {
                      if (_currentPage != i) {
                        setState(() => _currentPage = i);
                      }
                    },
                    children: [
                      _RetainedPage(
                        key: const ValueKey('connection'),
                        child: ConnectionPage(onReload: _reloadConnection),
                      ),
                      const _RetainedPage(
                        key: ValueKey('settings'),
                        child: SettingsPage(),
                      ),
                      const _RetainedPage(
                        key: ValueKey('info'),
                        child: InfoPage(),
                      ),
                      const _RetainedPage(
                        key: ValueKey('logs'),
                        child: LogsPage(),
                      ),
                    ],
                  ),
                ),
              ),
              NavBar(
                currentIndex: _currentPage,
                onSelect: _onNavSelect,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Keeps a visited page mounted so navigation preserves its scroll and form state.
class _RetainedPage extends StatefulWidget {
  const _RetainedPage({super.key, required this.child});

  final Widget child;

  @override
  State<_RetainedPage> createState() => _RetainedPageState();
}

class _RetainedPageState extends State<_RetainedPage>
    with AutomaticKeepAliveClientMixin<_RetainedPage> {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

class _BackendOfflineBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: const Color(0xFFB22A2A),
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
      child: const Text(
        'Backend offline — перезапускаю...',
        textAlign: TextAlign.center,
        style: TextStyle(color: Colors.white, fontSize: 12),
      ),
    );
  }
}
