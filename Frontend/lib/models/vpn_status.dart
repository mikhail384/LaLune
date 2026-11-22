// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

class VpnStatus {
  final String
  state; // connected | disconnected | connecting | checking | disconnecting | error
  final bool connected;
  final int uptimeSec;
  final int configId;
  final String message;
  final bool trafficAvailable;
  final bool trafficRatesAvailable;
  final bool tots;
  final int rxBytes;
  final int txBytes;
  final int rxRate;
  final int txRate;
  final bool workersAvailable;
  final bool workerProvidersAvailable;
  final int workers;
  final int workersTarget;
  final int workersRequested;
  final Map<String, int> workerTargets;
  final int tunnelRttMs;
  final int workersVk;
  final int workersJazz;
  final int workersYaDocs;
  final int workersMailDocs;
  final int workersCups;
  final int workersMax;
  final int activeSessions;

  const VpnStatus({
    this.state = 'disconnected',
    this.connected = false,
    this.uptimeSec = 0,
    this.configId = 0,
    this.message = '',
    this.trafficAvailable = true,
    this.trafficRatesAvailable = true,
    this.tots = false,
    this.rxBytes = 0,
    this.txBytes = 0,
    this.rxRate = 0,
    this.txRate = 0,
    this.workersAvailable = false,
    this.workerProvidersAvailable = false,
    this.workers = 0,
    this.workersTarget = 0,
    this.workersRequested = 0,
    this.workerTargets = const {},
    this.tunnelRttMs = 0,
    this.workersVk = 0,
    this.workersJazz = 0,
    this.workersYaDocs = 0,
    this.workersMailDocs = 0,
    this.workersCups = 0,
    this.workersMax = 0,
    this.activeSessions = 0,
  });

  factory VpnStatus.fromJson(Map<String, dynamic> j) => VpnStatus(
    state: (j['state'] ?? 'disconnected') as String,
    connected: (j['connected'] ?? false) as bool,
    uptimeSec: ((j['uptimeSec'] ?? 0) as num).toInt(),
    configId: ((j['configId'] ?? 0) as num).toInt(),
    message: (j['message'] ?? '') as String,
    trafficAvailable: j['trafficAvailable'] != false,
    trafficRatesAvailable: j['trafficRatesAvailable'] != false,
    tots: j['tots'] == true,
    rxBytes: ((j['rxBytes'] ?? 0) as num).toInt(),
    txBytes: ((j['txBytes'] ?? 0) as num).toInt(),
    rxRate: ((j['rxRate'] ?? 0) as num).toInt(),
    txRate: ((j['txRate'] ?? 0) as num).toInt(),
    workersAvailable:
        (j['workersAvailable'] ?? j.containsKey('workers')) == true,
    workerProvidersAvailable:
        (j['workerProvidersAvailable'] ?? j.containsKey('workersVk')) == true,
    workers: ((j['workers'] ?? 0) as num).toInt(),
    workersTarget: ((j['workersTarget'] ?? 0) as num).toInt(),
    workersRequested: ((j['workersRequested'] ?? 0) as num).toInt(),
    workerTargets: switch (j['workerTargets']) {
      final Map<String, dynamic> values => Map.unmodifiable({
        for (final entry in values.entries)
          if (entry.value is int) entry.key: entry.value as int,
      }),
      _ => const {},
    },
    tunnelRttMs: ((j['tunnelRttMs'] ?? 0) as num).toInt(),
    workersVk: ((j['workersVk'] ?? 0) as num).toInt(),
    workersJazz: ((j['workersJazz'] ?? 0) as num).toInt(),
    workersYaDocs: ((j['workersYaDocs'] ?? 0) as num).toInt(),
    workersMailDocs: ((j['workersMailDocs'] ?? 0) as num).toInt(),
    workersCups: ((j['workersCups'] ?? 0) as num).toInt(),
    workersMax: ((j['workersMax'] ?? 0) as num).toInt(),
    activeSessions: ((j['activeSessions'] ?? 0) as num).toInt(),
  );

  VpnStatus copyWith({
    String? state,
    bool? connected,
    int? uptimeSec,
    int? configId,
    String? message,
    bool? trafficAvailable,
    bool? trafficRatesAvailable,
    bool? tots,
    int? rxBytes,
    int? txBytes,
    int? rxRate,
    int? txRate,
    bool? workersAvailable,
    bool? workerProvidersAvailable,
    int? workers,
    int? workersTarget,
    int? workersRequested,
    Map<String, int>? workerTargets,
    int? tunnelRttMs,
    int? workersVk,
    int? workersJazz,
    int? workersYaDocs,
    int? workersMailDocs,
    int? workersCups,
    int? workersMax,
    int? activeSessions,
  }) => VpnStatus(
    state: state ?? this.state,
    connected: connected ?? this.connected,
    uptimeSec: uptimeSec ?? this.uptimeSec,
    configId: configId ?? this.configId,
    message: message ?? this.message,
    trafficAvailable: trafficAvailable ?? this.trafficAvailable,
    trafficRatesAvailable: trafficRatesAvailable ?? this.trafficRatesAvailable,
    tots: tots ?? this.tots,
    rxBytes: rxBytes ?? this.rxBytes,
    txBytes: txBytes ?? this.txBytes,
    rxRate: rxRate ?? this.rxRate,
    txRate: txRate ?? this.txRate,
    workersAvailable: workersAvailable ?? this.workersAvailable,
    workerProvidersAvailable:
        workerProvidersAvailable ?? this.workerProvidersAvailable,
    workers: workers ?? this.workers,
    workersTarget: workersTarget ?? this.workersTarget,
    workersRequested: workersRequested ?? this.workersRequested,
    workerTargets: workerTargets ?? this.workerTargets,
    tunnelRttMs: tunnelRttMs ?? this.tunnelRttMs,
    workersVk: workersVk ?? this.workersVk,
    workersJazz: workersJazz ?? this.workersJazz,
    workersYaDocs: workersYaDocs ?? this.workersYaDocs,
    workersMailDocs: workersMailDocs ?? this.workersMailDocs,
    workersCups: workersCups ?? this.workersCups,
    workersMax: workersMax ?? this.workersMax,
    activeSessions: activeSessions ?? this.activeSessions,
  );

  static const empty = VpnStatus();
}
