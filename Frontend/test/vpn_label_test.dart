// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import 'package:flutter_test/flutter_test.dart';
import 'package:lalune/utils/vpn_label.dart';

void main() {
  test('empty and default messages show "Подключено"', () {
    expect(vpnConnectedLabel(''), kVpnMessageConnected);
    expect(vpnConnectedLabel('   '), kVpnMessageConnected);
    expect(vpnConnectedLabel('Подключено'), kVpnMessageConnected);
  });

  test('auto-sleep messages win over the default label', () {
    // Regression: the Android service kept reporting "Туннель спит" even with
    // the screen on. The label must follow the backend verbatim.
    expect(vpnConnectedLabel('Туннель спит'), kVpnMessageSleeping);
    expect(vpnConnectedLabel('Возвращаю туннель'), kVpnMessageReattaching);
    expect(vpnConnectedLabel('  Туннель спит  '), kVpnMessageSleeping);
  });

  test('any other backend message is shown as is', () {
    expect(vpnConnectedLabel('Переподключение'), 'Переподключение');
  });
}
