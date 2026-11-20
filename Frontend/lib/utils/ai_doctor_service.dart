// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AiDoctorSettings {
  static const _kUrlKey = 'lalune.ai_doctor.url';
  static const _kSecretKey = 'lalune.ai_doctor.secret';

  final String vpsUrl;
  final String secret;

  const AiDoctorSettings({this.vpsUrl = '', this.secret = ''});

  bool get isConfigured => vpsUrl.trim().isNotEmpty;

  static Future<AiDoctorSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return AiDoctorSettings(
      vpsUrl: prefs.getString(_kUrlKey) ?? '',
      secret: prefs.getString(_kSecretKey) ?? '',
    );
  }

  static Future<void> save(AiDoctorSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kUrlKey, settings.vpsUrl.trim());
    await prefs.setString(_kSecretKey, settings.secret.trim());
  }
}

class AiDoctorPlan {
  final String tier;
  final String diagnosis;
  final String actionId;
  final String? pkg;
  final String? command;
  final String riskLevel;
  final String consequences;
  final List<String> backupPaths;
  final String rollbackHint;

  const AiDoctorPlan({
    required this.tier,
    required this.diagnosis,
    required this.actionId,
    this.pkg,
    this.command,
    required this.riskLevel,
    required this.consequences,
    this.backupPaths = const [],
    this.rollbackHint = '',
  });

  bool get isSafe => tier == 'safe';
  bool get requiresApproval => tier == 'approval_required';

  factory AiDoctorPlan.fromJson(Map<String, dynamic> j) => AiDoctorPlan(
        tier: (j['tier'] ?? 'info_only').toString(),
        diagnosis: (j['diagnosis'] ?? '').toString(),
        actionId: (j['action_id'] ?? 'none').toString(),
        pkg: j['pkg']?.toString(),
        command: j['command']?.toString(),
        riskLevel: (j['risk_level'] ?? 'low').toString(),
        consequences: (j['consequences'] ?? '').toString(),
        backupPaths: (j['backup_paths'] as List? ?? const [])
            .map((e) => e.toString())
            .where((s) => s.startsWith('/'))
            .toList(),
        rollbackHint: (j['rollback_hint'] ?? '').toString(),
      );
}

class AiDoctorService {
  static const _safePackages = <String>{
    'ip-full',
    'kmod-tun',
    'iptables-nft',
    'iptables',
    'kmod-ipt-nat',
    'kmod-nft-nat',
    'kmod-nft-compat',
    'iptables-mod-nat-extra',
    'ca-bundle',
    'ca-certificates',
    'coreutils-nohup',
  };

  static final _blockedCommands = <RegExp>[
    RegExp(r'rm\s+-[^\n]*r[^\n]*f\s+/(?:\s|$)', caseSensitive: false),
    RegExp(r'\b(mtd|sysupgrade|firstboot|jffs2reset|mkfs\.\w+)\b',
        caseSensitive: false),
    RegExp(r'\bdd\b[^\n]*\bof=/dev/', caseSensitive: false),
    RegExp(r'\bpasswd\b', caseSensitive: false),
  ];

  static bool isCommandBlocked(String cmd) =>
      _blockedCommands.any((re) => re.hasMatch(cmd));

  static String redactSecrets(String raw) {
    var out = raw;
    out = out.replaceAllMapped(
      RegExp(
        r'''(password|pass|pwd|vk_token|secret|session_key|anonymToken)=([^\s&'"\\]+)''',
        caseSensitive: false,
      ),
      (m) => '${m.group(1)}=[REDACTED]',
    );
    out = out.replaceAllMapped(
      RegExp(r'(CSQTT_PASSWORD=)([^\s]+)', caseSensitive: false),
      (m) => '${m.group(1)}[REDACTED]',
    );
    out = out.replaceAllMapped(
      RegExp(r'(Bearer\s+)[A-Za-z0-9._\-]+', caseSensitive: false),
      (m) => '${m.group(1)}[REDACTED]',
    );
    return out;
  }

  static Future<({bool authenticated, String model, String loginUrl})>
      checkAuthStatus(AiDoctorSettings cfg) async {
    final base = cfg.vpsUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.getUrl(Uri.parse('$base/auth/status'));
      final resp = await req.close().timeout(const Duration(seconds: 15));
      final body = await utf8.decodeStream(resp);
      if (resp.statusCode != 200) {
        throw StateError('HTTP ${resp.statusCode}: $body');
      }
      final j = jsonDecode(body) as Map<String, dynamic>;
      return (
        authenticated: j['authenticated'] == true,
        model: (j['model'] ?? '').toString(),
        loginUrl: (j['login_url'] ?? '$base/auth/google/login').toString(),
      );
    } finally {
      client.close(force: true);
    }
  }

  static Future<AiDoctorPlan> diagnose({
    required AiDoctorSettings cfg,
    required String host,
    required String stage,
    required String errorMessage,
    required String log,
    List<String> history = const [],
  }) async {
    final base = cfg.vpsUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.postUrl(Uri.parse('$base/api/diagnose'));
      req.headers
          .set(HttpHeaders.contentTypeHeader, 'application/json; charset=utf-8');
      if (cfg.secret.trim().isNotEmpty) {
        req.headers
            .set(HttpHeaders.authorizationHeader, 'Bearer ${cfg.secret.trim()}');
      }
      req.add(utf8.encode(jsonEncode({
        'host': host,
        'stage': stage,
        'error_message': errorMessage,
        'log': redactSecrets(log),
        'history': history,
      })));
      final resp = await req.close().timeout(const Duration(seconds: 65));
      final body = await utf8.decodeStream(resp);
      if (resp.statusCode == 401) {
        throw StateError(
          'Требуется вход через Google OAuth на VPS ($base/auth/google/login)',
        );
      }
      if (resp.statusCode != 200) {
        throw StateError('Ошибка VPS (${resp.statusCode}): $body');
      }
      return AiDoctorPlan.fromJson(jsonDecode(body) as Map<String, dynamic>);
    } finally {
      client.close(force: true);
    }
  }

  static Future<String> executeSafeAction(
    SSHClient client,
    AiDoctorPlan plan,
  ) async {
    String cmd;
    switch (plan.actionId) {
      case 'cleanup_routing_10620':
        cmd = 'ip -4 rule del priority 10620 2>/dev/null || true; '
            'ip -4 rule del priority 10621 2>/dev/null || true; '
            'ip -4 rule del priority 10622 2>/dev/null || true; '
            'ip -4 route flush table 10620 2>/dev/null || true; '
            'for h in \$(nft -a list chain inet fw4 forward 2>/dev/null | '
            "awk '/lalune-vpn-/{print \$NF}'); do "
            'nft delete rule inet fw4 forward handle "\$h" 2>/dev/null || true; done; '
            'echo "cleanup_routing_10620 OK"';
        break;
      case 'restart_lalune':
        cmd = '/etc/init.d/lalune restart 2>&1 || /etc/init.d/lalune start 2>&1';
        break;
      case 'drop_caches':
        cmd = 'sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true; free';
        break;
      case 'install_pkg':
        final pkg = (plan.pkg ?? '').trim();
        if (!_safePackages.contains(pkg)) {
          throw StateError('Пакет "$pkg" не входит в безопасный белый список');
        }
        cmd = '(command -v apk >/dev/null 2>&1 && apk update && apk add "$pkg") || '
            '(opkg update && opkg install "$pkg")';
        break;
      case 'collect_more_diagnostics':
        cmd = 'uname -a; free; df -h; ip -4 rule show; ip -4 route show table 10620 2>&1; '
            'nft -a list chain inet fw4 forward 2>&1 | head -n 40';
        break;
      default:
        throw StateError('Неизвестное безопасное действие: ${plan.actionId}');
    }
    final res = await client.runWithResult(cmd);
    final out = utf8.decode(res.stdout, allowMalformed: true).trim();
    final err = utf8.decode(res.stderr, allowMalformed: true).trim();
    return 'exit=${res.exitCode}\n$out${err.isEmpty ? '' : '\nSTDERR: $err'}';
  }

  static Future<String> executeApprovedRootCommand(
    SSHClient client,
    AiDoctorPlan plan,
  ) async {
    final command = (plan.command ?? '').trim();
    if (command.isEmpty) {
      throw StateError('Команда пуста');
    }
    if (isCommandBlocked(command)) {
      throw StateError('Команда заблокирована локальным стоп-листом безопасности');
    }
    final backupBuf = StringBuffer();
    if (plan.backupPaths.isNotEmpty) {
      await client.run('mkdir -p /tmp/lalune-backup');
      for (final p in plan.backupPaths) {
        final safePath = p.replaceAll("'", "'\\''");
        await client.run(
          "if [ -f '$safePath' ]; then cp -a '$safePath' /tmp/lalune-backup/; fi",
        );
        backupBuf.writeln('Бэкап сохранён: $p -> /tmp/lalune-backup/');
      }
    }
    final res = await client.runWithResult(command);
    final out = utf8.decode(res.stdout, allowMalformed: true).trim();
    final err = utf8.decode(res.stderr, allowMalformed: true).trim();
    return '${backupBuf.toString()}exit=${res.exitCode}\n$out${err.isEmpty ? '' : '\nSTDERR: $err'}';
  }
}
