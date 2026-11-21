// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

class VpnStatus {
  final String state; // connected | disconnected | connecting | checking | disconnecting | error
  final bool connected;
  final int uptimeSec;
  final int configId;
  final String message;
  final bool trafficAvailable;
  final int rxBytes;
  final int txBytes;
  final int rxRate;
  final int txRate;
  final int workers;
  final int workersTarget;
  final int workersVk;
  final int workersJazz;
  final int workersYaDocs;
  final int workersMailDocs;
  final int workersCups;
  final int activeSessions;

  const VpnStatus({
    this.state = 'disconnected',
    this.connected = false,
    this.uptimeSec = 0,
    this.configId = 0,
    this.message = '',
    this.trafficAvailable = true,
    this.rxBytes = 0,
    this.txBytes = 0,
    this.rxRate = 0,
    this.txRate = 0,
    this.workers = 0,
    this.workersTarget = 0,
    this.workersVk = 0,
    this.workersJazz = 0,
    this.workersYaDocs = 0,
    this.workersMailDocs = 0,
    this.workersCups = 0,
    this.activeSessions = 0,
  });

  factory VpnStatus.fromJson(Map<String, dynamic> j) => VpnStatus(
        state: (j['state'] ?? 'disconnected') as String,
        connected: (j['connected'] ?? false) as bool,
        uptimeSec: ((j['uptimeSec'] ?? 0) as num).toInt(),
        configId: ((j['configId'] ?? 0) as num).toInt(),
        message: (j['message'] ?? '') as String,
        trafficAvailable: j['trafficAvailable'] != false,
        rxBytes: ((j['rxBytes'] ?? 0) as num).toInt(),
        txBytes: ((j['txBytes'] ?? 0) as num).toInt(),
        rxRate: ((j['rxRate'] ?? 0) as num).toInt(),
        txRate: ((j['txRate'] ?? 0) as num).toInt(),
        workers: ((j['workers'] ?? 0) as num).toInt(),
        workersTarget: ((j['workersTarget'] ?? 0) as num).toInt(),
        workersVk: ((j['workersVk'] ?? 0) as num).toInt(),
        workersJazz: ((j['workersJazz'] ?? 0) as num).toInt(),
        workersYaDocs: ((j['workersYaDocs'] ?? 0) as num).toInt(),
        workersMailDocs: ((j['workersMailDocs'] ?? 0) as num).toInt(),
        workersCups: ((j['workersCups'] ?? 0) as num).toInt(),
        activeSessions: ((j['activeSessions'] ?? 0) as num).toInt(),
      );

  VpnStatus copyWith({
    String? state,
    bool? connected,
    int? uptimeSec,
    int? configId,
    String? message,
    bool? trafficAvailable,
    int? rxBytes,
    int? txBytes,
    int? rxRate,
    int? txRate,
    int? workers,
    int? workersTarget,
    int? workersVk,
    int? workersJazz,
    int? workersYaDocs,
    int? workersMailDocs,
    int? workersCups,
    int? activeSessions,
  }) =>
      VpnStatus(
        state: state ?? this.state,
        connected: connected ?? this.connected,
        uptimeSec: uptimeSec ?? this.uptimeSec,
        configId: configId ?? this.configId,
        message: message ?? this.message,
        trafficAvailable: trafficAvailable ?? this.trafficAvailable,
        rxBytes: rxBytes ?? this.rxBytes,
        txBytes: txBytes ?? this.txBytes,
        rxRate: rxRate ?? this.rxRate,
        txRate: txRate ?? this.txRate,
        workers: workers ?? this.workers,
        workersTarget: workersTarget ?? this.workersTarget,
        workersVk: workersVk ?? this.workersVk,
        workersJazz: workersJazz ?? this.workersJazz,
        workersYaDocs: workersYaDocs ?? this.workersYaDocs,
        workersMailDocs: workersMailDocs ?? this.workersMailDocs,
        workersCups: workersCups ?? this.workersCups,
        activeSessions: activeSessions ?? this.activeSessions,
      );

  static const empty = VpnStatus();
}
