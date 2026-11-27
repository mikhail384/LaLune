// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

class ConfigItem {
  final int id;
  final String protocol; // CSQTT / CSQTTR / ToTS
  final String peer;
  final String password;
  final String hashes;
  final String name;
  final String rawLink;

  ConfigItem({
    required this.id,
    required this.protocol,
    this.peer = '',
    this.password = '',
    this.hashes = '',
    this.name = '',
    this.rawLink = '',
  });

  bool get isTots => protocol.toLowerCase() == 'tots';

  /// WDTToR — обратно совместимый с WDTT клиент (WireGuard поверх TURN/DTLS).
  bool get isWdtt => protocol.toLowerCase() == 'wdtto' ||
      protocol.toLowerCase() == 'wdttor' ||
      protocol.toLowerCase() == 'wdtt' ||
      protocol.toLowerCase().startsWith('wdttor');

  /// Подпись протокола для UI: у WDTToR она отличается от id.
  String get protocolLabel => isWdtt ? 'WDTToR (WDTT)' : protocol;
  bool get isCsqtt219 => protocol.toUpperCase() == 'CSQTT 2.1.9';
  bool get isCsqtt251 =>
      protocol.toUpperCase() == 'CSQTT 2.5.1' ||
      protocol.toUpperCase() == 'CSQTT';

  factory ConfigItem.fromJson(Map<String, dynamic> j) => ConfigItem(
        id: (j['id'] as num?)?.toInt() ?? 0,
        protocol: (j['protocol'] ?? 'CSQTT').toString(),
        peer: (j['peer'] ?? '').toString(),
        password: (j['password'] ?? '').toString(),
        hashes: (j['hashes'] ?? '').toString(),
        name: (j['name'] ?? j['peer'] ?? '').toString(),
        rawLink: (j['rawLink'] ?? '').toString(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'protocol': protocol,
        'peer': peer,
        'password': password,
        'hashes': hashes,
        'name': name,
        'rawLink': rawLink,
      };

  String get displayName => name.isNotEmpty ? name : peer;
}
