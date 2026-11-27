// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Device ID применяется только для CSQTT 2.1.9.

const int kDefaultWorkers = 9;
const int kMinWorkers = 1;
const int kMaxWorkers = 127;
const int kDefaultAutoApiWorkers = 9;
const int kMinAutoApiWorkers = 9;
const int kMaxAutoApiWorkers = 27;

class Settings {
  // CSQTT
  final String peer;
  final String vkHashes;
  final String vkJsToken;
  final String deviceId;
  final int workers;
  final bool autoWorkers;
  final int autoApiWorkers;
  final String password;
  final String obfs;
  final String fingerprint;
  final String clientIds;
  final String authMode;
  final String externalHashesUrl;
  final String turnTransport;
  final String turnHost;
  final String turnPort;
  final String captchaMode;
  final String vkAuthMode;
  final bool allowHashRedistribution;
  final bool validateVkHashes;

  // ToTS
  final int totsWorkers;
  final int totsMtu;
  final bool totsRelayOnly;
  final bool totsVkEnabled;
  final bool totsJazzEnabled;
  final bool totsYaDocsEnabled;
  final bool totsMailDocsEnabled;
  final bool totsCupsEnabled;
  final int totsVkPercent;
  final int totsJazzPercent;
  final int totsYaDocsPercent;
  final int totsMailDocsPercent;
  final int totsCupsPercent;
  final String totsVkAuthMode;
  final String totsVkCallLinks;
  final String totsJazzRoomName;
  final bool totsJazzRandomName;
  final String totsJazzData;
  final String totsYaDocsData;
  final String totsMailDocsData;
  final String totsCupsData;


  // WDTToR (WDTT)
  final int wdttWorkers;
  final String wdttObfs;
  final String wdttVkAuthMode;
  final int wdttLocalPort;
  final String wdttDeviceId;

  // Экспериментальное
  final bool enableSmartTunnel;
  final bool showCoreLogs;
  final bool shareVpn;
  final bool desktopSocks5Mode;

  // Global split tunneling (shared by all protocols).
  final String ipRoutingMode; // blacklist: listed IPs bypass VPN; whitelist: only listed IPs use VPN.
  final String ipRoutingIps; // one IPv4/IPv6 address or CIDR per line.
  final String androidAppRoutingMode; // blacklist: selected apps bypass VPN; whitelist: only selected apps use VPN.
  final List<String> androidVpnApps;
  final bool androidAutoSleepTunnel;

  Settings({
    this.peer = '',
    this.vkHashes = '',
    this.vkJsToken = '',
    this.deviceId = 'unknown',
    this.workers = kDefaultWorkers,
    this.autoWorkers = false,
    this.autoApiWorkers = kDefaultAutoApiWorkers,
    this.password = '',
    this.obfs = 'video',
    this.fingerprint = 'firefox',
    this.clientIds = '8202606,6287487',
    this.authMode = 'manual',
    this.externalHashesUrl = '',
    this.turnTransport = 'udp',
    this.turnHost = '',
    this.turnPort = '',
    this.captchaMode = 'auto',
    this.vkAuthMode = 'vkcalls',
    this.allowHashRedistribution = false,
    this.validateVkHashes = false,
    this.totsWorkers = 1,
    this.totsMtu = 1200,
    this.totsRelayOnly = false,
    this.totsVkEnabled = true,
    this.totsJazzEnabled = true,
    this.totsYaDocsEnabled = true,
    this.totsMailDocsEnabled = true,
    this.totsCupsEnabled = true,
    this.totsVkPercent = 100,
    this.totsJazzPercent = 0,
    this.totsYaDocsPercent = 0,
    this.totsMailDocsPercent = 0,
    this.totsCupsPercent = 0,
    this.totsVkAuthMode = 'manual',
    this.totsVkCallLinks = '',
    this.totsJazzRoomName = '',
    this.totsJazzRandomName = true,
    this.totsJazzData = '',
    this.totsYaDocsData = '',
    this.totsMailDocsData = '',
    this.totsCupsData = '',
    this.wdttWorkers = 9,
    this.wdttObfs = 'audio',
    this.wdttVkAuthMode = 'manual',
    this.wdttLocalPort = 9000,
    this.wdttDeviceId = '',
    this.enableSmartTunnel = false,
    this.showCoreLogs = false,
    this.shareVpn = false,
    this.desktopSocks5Mode = false,
    this.ipRoutingMode = 'blacklist',
    this.ipRoutingIps = '',
    this.androidAppRoutingMode = 'blacklist',
    this.androidVpnApps = const [],
    this.androidAutoSleepTunnel = true,
  });

  factory Settings.fromJson(Map<String, dynamic> j) {
    var w = ((j['workers'] ?? kDefaultWorkers) as num).toInt();
    if (w < kMinWorkers) w = kMinWorkers;
    if (w > kMaxWorkers) w = kMaxWorkers;

    var aw = ((j['autoApiWorkers'] ?? kDefaultAutoApiWorkers) as num).toInt();
    if (aw < kMinAutoApiWorkers) aw = kMinAutoApiWorkers;
    if (aw > kMaxAutoApiWorkers) aw = kMaxAutoApiWorkers;

    return Settings(
      peer: (j['peer'] ?? '') as String,
      vkHashes: (j['vkHashes'] ?? '') as String,
      vkJsToken: (j['vkJsToken'] ?? '') as String,
      deviceId: (j['deviceId'] ?? 'unknown') as String,
      workers: w,
      autoWorkers: (j['autoWorkers'] ?? false) as bool,
      autoApiWorkers: aw,
      password: (j['password'] ?? '') as String,
      obfs: (j['obfs'] ?? 'video') as String,
      fingerprint: (j['fingerprint'] ?? 'firefox') as String,
      clientIds: (j['clientIds'] ?? '8202606,6287487') as String,
      authMode: (j['authMode'] ?? 'manual') as String,
      externalHashesUrl: (j['externalHashesUrl'] ?? '') as String,
      turnTransport: (j['turnTransport'] ?? 'udp') as String,
      turnHost: (j['turnHost'] ?? '') as String,
      turnPort: (j['turnPort'] ?? '') as String,
      captchaMode: (j['captchaMode'] ?? 'auto') as String,
      vkAuthMode: (j['vkAuthMode'] ?? 'vkcalls') as String,
      allowHashRedistribution: (j['allowHashRedistribution'] ?? false) as bool,
      validateVkHashes: (j['validateVkHashes'] ?? false) as bool,
      totsWorkers: ((j['totsWorkers'] ?? 1) as num).toInt().clamp(1, 256).toInt(),
      totsMtu: ((j['totsMtu'] ?? 1200) as num).toInt().clamp(576, 1400).toInt(),
      totsRelayOnly: (j['totsRelayOnly'] ?? false) as bool,
      totsVkEnabled: (j['totsVkEnabled'] ?? true) as bool,
      totsJazzEnabled: (j['totsJazzEnabled'] ?? true) as bool,
      totsYaDocsEnabled: (j['totsYaDocsEnabled'] ?? true) as bool,
      totsMailDocsEnabled: (j['totsMailDocsEnabled'] ?? true) as bool,
      totsCupsEnabled: (j['totsCupsEnabled'] ?? true) as bool,
      totsVkPercent: ((j['totsVkPercent'] ?? 100) as num).toInt().clamp(0, 100).toInt(),
      totsJazzPercent: ((j['totsJazzPercent'] ?? 0) as num).toInt().clamp(0, 100).toInt(),
      totsYaDocsPercent: ((j['totsYaDocsPercent'] ?? 0) as num).toInt().clamp(0, 100).toInt(),
      totsMailDocsPercent: ((j['totsMailDocsPercent'] ?? 0) as num).toInt().clamp(0, 100).toInt(),
      totsCupsPercent: ((j['totsCupsPercent'] ?? 0) as num).toInt().clamp(0, 100).toInt(),
      totsVkAuthMode: (j['totsVkAuthMode'] ?? 'manual') as String,
      totsVkCallLinks: (j['totsVkCallLinks'] ?? '') as String,
      totsJazzRoomName: (j['totsJazzRoomName'] ?? '') as String,
      totsJazzRandomName: (j['totsJazzRandomName'] ?? true) as bool,
      totsJazzData: (j['totsJazzData'] ?? '') as String,
      totsYaDocsData: (j['totsYaDocsData'] ?? '') as String,
      totsMailDocsData: (j['totsMailDocsData'] ?? '') as String,
      totsCupsData: (j['totsCupsData'] ?? '') as String,
      wdttWorkers: ((j['wdttWorkers'] ?? 9) as num).toInt().clamp(9, 108).toInt(),
      wdttObfs: (j['wdttObfs'] ?? 'audio') as String,
      wdttVkAuthMode: (j['wdttVkAuthMode'] ?? 'manual') as String,
      wdttLocalPort: ((j['wdttLocalPort'] ?? 9000) as num).toInt().clamp(1, 65535).toInt(),
      wdttDeviceId: (j['wdttDeviceId'] ?? '') as String,
      enableSmartTunnel: (j['enableSmartTunnel'] ?? false) as bool,
      showCoreLogs: (j['showCoreLogs'] ?? false) as bool,
      shareVpn: (j['shareVpn'] ?? false) as bool,
      desktopSocks5Mode: (j['desktopSocks5Mode'] ?? false) as bool,
      ipRoutingMode: (j['ipRoutingMode'] ?? 'blacklist') as String,
      ipRoutingIps: (j['ipRoutingIps'] ?? '') as String,
      androidAppRoutingMode: (j['androidAppRoutingMode'] ?? 'blacklist') as String,
      androidVpnApps: ((j['androidVpnApps'] ?? const []) as List).map((v) => v.toString()).toList(),
      androidAutoSleepTunnel: (j['androidAutoSleepTunnel'] ?? true) as bool,
    );
  }

  Map<String, dynamic> toJson() => {
        'peer': peer,
        'vkHashes': vkHashes,
        'vkJsToken': vkJsToken,
        'deviceId': deviceId,
        'workers': workers,
        'autoWorkers': autoWorkers,
        'autoApiWorkers': autoApiWorkers,
        'password': password,
        'obfs': obfs,
        'fingerprint': fingerprint,
        'clientIds': clientIds,
        'authMode': authMode,
        'externalHashesUrl': externalHashesUrl,
        'turnTransport': turnTransport,
        'turnHost': turnHost,
        'turnPort': turnPort,
        'captchaMode': captchaMode,
        'vkAuthMode': vkAuthMode,
        'allowHashRedistribution': allowHashRedistribution,
        'validateVkHashes': validateVkHashes,
        'totsWorkers': totsWorkers,
        'totsMtu': totsMtu,
        'totsRelayOnly': totsRelayOnly,
        'totsVkEnabled': totsVkEnabled,
        'totsJazzEnabled': totsJazzEnabled,
        'totsYaDocsEnabled': totsYaDocsEnabled,
        'totsMailDocsEnabled': totsMailDocsEnabled,
        'totsCupsEnabled': totsCupsEnabled,
        'totsVkPercent': totsVkPercent,
        'totsJazzPercent': totsJazzPercent,
        'totsYaDocsPercent': totsYaDocsPercent,
        'totsMailDocsPercent': totsMailDocsPercent,
        'totsCupsPercent': totsCupsPercent,
        'totsVkAuthMode': totsVkAuthMode,
        'totsVkCallLinks': totsVkCallLinks,
        'totsJazzRoomName': totsJazzRoomName,
        'totsJazzRandomName': totsJazzRandomName,
        'totsJazzData': totsJazzData,
        'totsYaDocsData': totsYaDocsData,
        'totsMailDocsData': totsMailDocsData,
        'totsCupsData': totsCupsData,
      'wdttWorkers': wdttWorkers,
      'wdttObfs': wdttObfs,
      'wdttVkAuthMode': wdttVkAuthMode,
      'wdttLocalPort': wdttLocalPort,
      'wdttDeviceId': wdttDeviceId,
        'enableSmartTunnel': enableSmartTunnel,
        'showCoreLogs': showCoreLogs,
        'shareVpn': shareVpn,
        'desktopSocks5Mode': desktopSocks5Mode,
        'ipRoutingMode': ipRoutingMode,
        'ipRoutingIps': ipRoutingIps,
        'androidAppRoutingMode': androidAppRoutingMode,
        'androidVpnApps': androidVpnApps,
        'androidAutoSleepTunnel': androidAutoSleepTunnel,
      };

  Settings copyWith({
    String? peer,
    String? vkHashes,
    String? vkJsToken,
    String? deviceId,
    int? workers,
    bool? autoWorkers,
    int? autoApiWorkers,
    String? password,
    String? obfs,
    String? fingerprint,
    String? clientIds,
    String? authMode,
    String? externalHashesUrl,
    String? turnTransport,
    String? turnHost,
    String? turnPort,
    String? captchaMode,
    String? vkAuthMode,
    bool? allowHashRedistribution,
    bool? validateVkHashes,
    int? totsWorkers,
    int? totsMtu,
    bool? totsRelayOnly,
    bool? totsVkEnabled,
    bool? totsJazzEnabled,
    bool? totsYaDocsEnabled,
    bool? totsMailDocsEnabled,
    bool? totsCupsEnabled,
    int? totsVkPercent,
    int? totsJazzPercent,
    int? totsYaDocsPercent,
    int? totsMailDocsPercent,
    int? totsCupsPercent,
    String? totsVkAuthMode,
    String? totsVkCallLinks,
    String? totsJazzRoomName,
    bool? totsJazzRandomName,
    String? totsJazzData,
    String? totsYaDocsData,
    String? totsMailDocsData,
    String? totsCupsData,
    int? wdttWorkers,
    String? wdttObfs,
    String? wdttVkAuthMode,
    int? wdttLocalPort,
    String? wdttDeviceId,
    bool? enableSmartTunnel,
    bool? showCoreLogs,
    bool? shareVpn,
    bool? desktopSocks5Mode,
    String? ipRoutingMode,
    String? ipRoutingIps,
    String? androidAppRoutingMode,
    List<String>? androidVpnApps,
    bool? androidAutoSleepTunnel,
  }) =>
      Settings(
        peer: peer ?? this.peer,
        vkHashes: vkHashes ?? this.vkHashes,
        vkJsToken: vkJsToken ?? this.vkJsToken,
        deviceId: deviceId ?? this.deviceId,
        workers: workers ?? this.workers,
        autoWorkers: autoWorkers ?? this.autoWorkers,
        autoApiWorkers: autoApiWorkers ?? this.autoApiWorkers,
        password: password ?? this.password,
        obfs: obfs ?? this.obfs,
        fingerprint: fingerprint ?? this.fingerprint,
        clientIds: clientIds ?? this.clientIds,
        authMode: authMode ?? this.authMode,
        externalHashesUrl: externalHashesUrl ?? this.externalHashesUrl,
        turnTransport: turnTransport ?? this.turnTransport,
        turnHost: turnHost ?? this.turnHost,
        turnPort: turnPort ?? this.turnPort,
        captchaMode: captchaMode ?? this.captchaMode,
        vkAuthMode: vkAuthMode ?? this.vkAuthMode,
        allowHashRedistribution:
            allowHashRedistribution ?? this.allowHashRedistribution,
        validateVkHashes: validateVkHashes ?? this.validateVkHashes,
        totsWorkers: totsWorkers ?? this.totsWorkers,
        totsMtu: totsMtu ?? this.totsMtu,
        totsRelayOnly: totsRelayOnly ?? this.totsRelayOnly,
        totsVkEnabled: totsVkEnabled ?? this.totsVkEnabled,
        totsJazzEnabled: totsJazzEnabled ?? this.totsJazzEnabled,
        totsYaDocsEnabled: totsYaDocsEnabled ?? this.totsYaDocsEnabled,
        totsMailDocsEnabled: totsMailDocsEnabled ?? this.totsMailDocsEnabled,
        totsCupsEnabled: totsCupsEnabled ?? this.totsCupsEnabled,
        totsVkPercent: totsVkPercent ?? this.totsVkPercent,
        totsJazzPercent: totsJazzPercent ?? this.totsJazzPercent,
        totsYaDocsPercent: totsYaDocsPercent ?? this.totsYaDocsPercent,
        totsMailDocsPercent: totsMailDocsPercent ?? this.totsMailDocsPercent,
        totsCupsPercent: totsCupsPercent ?? this.totsCupsPercent,
        totsVkAuthMode: totsVkAuthMode ?? this.totsVkAuthMode,
        totsVkCallLinks: totsVkCallLinks ?? this.totsVkCallLinks,
        totsJazzRoomName: totsJazzRoomName ?? this.totsJazzRoomName,
        totsJazzRandomName: totsJazzRandomName ?? this.totsJazzRandomName,
        totsJazzData: totsJazzData ?? this.totsJazzData,
        totsYaDocsData: totsYaDocsData ?? this.totsYaDocsData,
        totsMailDocsData: totsMailDocsData ?? this.totsMailDocsData,
        totsCupsData: totsCupsData ?? this.totsCupsData,
        wdttWorkers: wdttWorkers ?? this.wdttWorkers,
        wdttObfs: wdttObfs ?? this.wdttObfs,
        wdttVkAuthMode: wdttVkAuthMode ?? this.wdttVkAuthMode,
        wdttLocalPort: wdttLocalPort ?? this.wdttLocalPort,
        wdttDeviceId: wdttDeviceId ?? this.wdttDeviceId,
        enableSmartTunnel: enableSmartTunnel ?? this.enableSmartTunnel,
        showCoreLogs: showCoreLogs ?? this.showCoreLogs,
        shareVpn: shareVpn ?? this.shareVpn,
        desktopSocks5Mode: desktopSocks5Mode ?? this.desktopSocks5Mode,
        ipRoutingMode: ipRoutingMode ?? this.ipRoutingMode,
        ipRoutingIps: ipRoutingIps ?? this.ipRoutingIps,
        androidAppRoutingMode: androidAppRoutingMode ?? this.androidAppRoutingMode,
        androidVpnApps: androidVpnApps ?? this.androidVpnApps,
        androidAutoSleepTunnel:
            androidAutoSleepTunnel ?? this.androidAutoSleepTunnel,
      );
}
