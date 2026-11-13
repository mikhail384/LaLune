import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lalune/state/openwrt_installer.dart';

/// Выбирает из скрипта функцию `lalune_abi` и приводит её к виду, не зависящему
/// от отступов и комментариев.
String _abiFunction(String script) {
  final lines = script.replaceAll('\r\n', '\n').split('\n');
  final start = lines.indexWhere((l) => l.startsWith('lalune_abi()'));
  expect(start, greaterThanOrEqualTo(0), reason: 'lalune_abi() not found');
  final body = <String>[];
  for (var i = start; i < lines.length; i++) {
    body.add(lines[i]);
    if (lines[i] == '}') break;
  }
  return body
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty && !l.startsWith('#'))
      .join('\n');
}

void main() {
  final shell = File('../Installer/openwrt.sh');

  test('in-app installer script has no unresolved placeholders', () {
    final script = OpenWrtInstaller.installScript();
    expect(script, isNot(contains('__BACKEND_BASE__')));
    expect(script, contains(OpenWrtInstaller.backendBaseUrl));
    expect(script, contains('lalune-openwrt-backend-\$abi'));
  });

  test('in-app lalune_abi matches Installer/openwrt.sh', () {
    expect(shell.existsSync(), isTrue, reason: 'run tests from Frontend/');
    expect(
      _abiFunction(OpenWrtInstaller.installScript()),
      _abiFunction(shell.readAsStringSync()),
    );
  });

  test('every supported OpenWrt architecture family is mapped', () {
    final fn = _abiFunction(OpenWrtInstaller.installScript());
    for (final family in [
      'aarch64_*',
      'x86_64',
      'i386_*',
      'mipsel_*',
      'mips_*',
      'arm_cortex-a7*',
      'arm_*',
    ]) {
      expect(fn, contains(family), reason: family);
    }
  });
}
