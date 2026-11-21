// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// VpnService с TUN + UDP-мост к ядру CSQTT.
//
// package = com.lalune.lalune — тот же, что у MainActivity и Backend.
//
// Порядок подключения:
//   1. Ядро запускается Backend'ом до startForegroundService.
//   2. Ждём 3 подряд строки статистики с «Активных: N>0».
//   3. Сразу поднимаем TUN + UDP-мост и считаем соединение установленным.
//      Отдельной HTTP-проверки работоспособности туннеля больше нет.
//
// Уведомление: отдельный тикер каждые 2 сек обновляет notification,
// чтобы статистика (Активных / Трафик) не "застывала".

package com.lalune.lalune

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.IpPrefix
import android.net.LocalServerSocket
import android.net.VpnService
import android.os.Build
import android.os.SystemClock
import android.os.ParcelFileDescriptor
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File
import java.io.RandomAccessFile
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject

class LaLuneVpnService : VpnService() {

    companion object {
        private const val TAG = "LaLune-VPN"
        private const val CHANNEL_ID = "lalune_vpn"
        private const val NOTIFICATION_ID = 1
        private const val ACTION_STOP = "com.lalune.lalune.STOP_FROM_NOTIFICATION"
        private const val CORE_PORT = 52230
        private const val DEFAULT_TUN_IP = "10.66.67.12"
        private const val DEFAULT_DNS_1 = "8.8.8.8"
        private const val DEFAULT_DNS_2 = "8.8.4.4"
        private const val MTU = 1300
        private const val REQUIRED_ACTIVE_TICKS = 3
        private const val LOG_POLL_MS = 500L
        private const val TUN_RETRY_DELAY_MS = 1_000L
        /** Периодичность обновления уведомления (2 сек). */
        private const val NOTIFICATION_TICK_MS = 2_000L

        const val ACTION_STATUS = "com.lalune.lalune.VPN_STATUS"
        const val ACTION_LOG = "com.lalune.lalune.VPN_LOG"
        const val EXTRA_CONNECTED = "connected"
        const val EXTRA_STATE = "state"
        const val EXTRA_MESSAGE = "message"
        const val EXTRA_LOG_LINE = "line"
        const val EXTRA_LOG_CORE = "core"

        /**
         * Process-wide snapshot of the last published VPN state. A freshly
         * created Backend (after a restart) reads it so it does not report
         * "disconnected" while the tunnel is actually up.
         */
        /**
         * Real tunnel traffic for the current connection (bytes that passed the TUN
         * device in each direction). Reset by every new connection; read by
         * `/vpn/stats` so the UI can account traffic per subscription.
         */
        val tunTxBytes = java.util.concurrent.atomic.AtomicLong(0)
        val tunRxBytes = java.util.concurrent.atomic.AtomicLong(0)
        @Volatile private var usesNativeTun = false
        @Volatile private var nativeTraffic: NativeTunTraffic? = null
        private data class WorkerSample(val session: String, val at: Long, val value: TotsWorkers)
        @Volatile private var workerSample: WorkerSample? = null
        @Volatile internal var totsWorkersTarget = 0
            private set

        internal fun currentTotsWorkers(): TotsWorkers? = workerSample?.takeIf {
            it.session == snapshotSessionId && SystemClock.elapsedRealtime() - it.at <= 15_000
        }?.value

        internal fun trafficBytes(): TunnelBytes? =
            if (usesNativeTun) nativeTraffic?.read()
            else TunnelBytes(tunRxBytes.get(), tunTxBytes.get())

        @Volatile var snapshotConnected: Boolean = false
        @Volatile var snapshotActiveSessions: Int = 0
        @Volatile var snapshotSessionId: String = ""
        @Volatile var snapshotConfigId: Long = 0
        @Volatile var snapshotState: String = "disconnected"
        @Volatile var snapshotMessage: String = ""

        fun notifyStatus(
            ctx: Context,
            connected: Boolean,
            state: String = if (connected) "connected" else "disconnected",
            message: String = if (connected) "Подключено" else "",
        ) {
            val i = Intent(ACTION_STATUS).apply {
                setPackage(ctx.packageName)
                putExtra(EXTRA_CONNECTED, connected)
                putExtra(EXTRA_STATE, state)
                putExtra(EXTRA_MESSAGE, message)
            }
            ctx.sendBroadcast(i)
        }

        fun notifyLog(ctx: Context, line: String, core: Boolean = false) {
            val i = Intent(ACTION_LOG).apply {
                setPackage(ctx.packageName)
                putExtra(EXTRA_LOG_LINE, line)
                putExtra(EXTRA_LOG_CORE, core)
            }
            ctx.sendBroadcast(i)
        }
    }

    @Volatile private var detectedTunIP: String? = null
    @Volatile private var detectedDNS: String? = null
    @Volatile private var activeSessions: Int = 0
    @Volatile private var consecutiveActiveTicks: Int = 0
    @Volatile private var trafficMB: String = "0.00"
    @Volatile private var connectionState: String = "disconnected"
    @Volatile private var connectionMessage: String = ""
    @Volatile private var rescanLogsRequested: Boolean = false

    private var vpnInterface: ParcelFileDescriptor? = null
    private var udpSocket: DatagramSocket? = null
    private var totsTunFd: ParcelFileDescriptor? = null
    private var totsRuntime: JSONObject? = null
    @Volatile private var isRunning = false
    @Volatile private var tunEstablished = false
    @Volatile private var establishing = false
    @Volatile private var tunnelGeneration = 0L

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val tunnelMutex = Mutex()
    private lateinit var coreManager: CoreManager
    private var notificationTickerJob: Job? = null
    private var flowJob: Job? = null
    private val bridgeJobs = mutableListOf<Job>()

    override fun onCreate() {
        super.onCreate()
        coreManager = CoreManager(this)
        startForegroundCompat()
        notifyLog(this, "[VPN] service created")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            "START" -> if (!isRunning) {
                notifyLog(this, "[VPN] START received; configId=$snapshotConfigId")
                isRunning = true
                publishState("connecting", false, "Подключение")
                startFlow()
            }
            "STOP", ACTION_STOP -> stopFlow()
        }
        return START_STICKY
    }

    private fun startFlow() {
        Log.d(TAG, "startFlow")
        // Empty during counter reset, so a concurrent reader cannot associate
        // a previous session ID with the next session's counters.
        snapshotSessionId = ""
        usesNativeTun = false
        nativeTraffic = null
        workerSample = null
        totsWorkersTarget = 0
        tunTxBytes.set(0)
        tunRxBytes.set(0)
        snapshotSessionId = java.util.UUID.randomUUID().toString()
        flowJob?.cancel()
        flowJob = scope.launch {
            val runtimeFile = File(filesDir, "la-lune/tots_runtime.json")
            totsRuntime = try {
                if (runtimeFile.exists()) JSONObject(runtimeFile.readText()) else null
            } catch (e: Exception) {
                Log.e(TAG, "invalid ToTS runtime: ${e.message}")
                notifyLog(this@LaLuneVpnService, "[VPN] invalid ToTS runtime: ${e.message.orEmpty()}")
                null
            }
            if (totsRuntime != null) {
                usesNativeTun = true
                totsWorkersTarget = totsRuntime?.optInt("workersTarget", 0) ?: 0
                notifyLog(this@LaLuneVpnService, "[VPN] ToTS runtime loaded; creating TUN")
                establishing = true
                val established = establishTun()
                establishing = false
                if (established && isRunning) {
                    publishState("connected", true, "Подключено")
                    Log.i(TAG, "ToTS TUN established and core received its descriptor over SCM_RIGHTS")
                } else if (isRunning) {
                    publishState("error", false, "Не удалось запустить ToTS")
                    stopFlow()
                }
            } else {
                val logsFile = File(filesDir, "la-lune/logs.log")
                watchLogsAndManageTunnel(logsFile)
            }
        }
        startNotificationTicker()
    }

    /**
     * Периодически обновляет уведомление — чтобы статистика
     * (Активных / Трафик) не застывала в одном значении.
     */
    private fun startNotificationTicker() {
        notificationTickerJob?.cancel()
        notificationTickerJob = scope.launch {
            while (isActive && isRunning) {
                delay(NOTIFICATION_TICK_MS)
                updateNotification()
            }
        }
    }

    private suspend fun watchLogsAndManageTunnel(logsFile: File) = withContext(Dispatchers.IO) {
        var lastOffset = 0L
        Log.d(TAG, "watching ${logsFile.absolutePath}")

        while (isRunning) {
            if (rescanLogsRequested) {
                lastOffset = 0L
                consecutiveActiveTicks = 0
                detectedTunIP = null
                detectedDNS = null
                rescanLogsRequested = false
                Log.i(TAG, "re-reading logs for fresh TUN parameters")
            }

            if (logsFile.exists()) {
                try {
                    RandomAccessFile(logsFile, "r").use { file ->
                        if (file.length() < lastOffset) lastOffset = 0L
                        file.seek(lastOffset)
                        while (file.filePointer < file.length()) {
                            val lineStart = file.filePointer
                            val latin1 = file.readLine() ?: break
                            val lineEnd = file.filePointer
                            // Leave a partially written final line for the next poll.
                            if (lineEnd == file.length() && lineEnd > lineStart) {
                                file.seek(lineEnd - 1)
                                val complete = file.read() == '\n'.code
                                file.seek(lineEnd)
                                if (!complete) {
                                    file.seek(lineStart)
                                    break
                                }
                            }
                            lastOffset = lineEnd
                            val line = String(latin1.toByteArray(Charsets.ISO_8859_1), Charsets.UTF_8)
                            if (line.isBlank()) continue

                            coreManager.parseTunconf(line)?.let { (ip, dns) ->
                                detectedTunIP = ip
                                detectedDNS = dns
                            }

                            coreManager.parseStats(line)?.let { (active, traffic) ->
                                activeSessions = active
                                snapshotActiveSessions = active
                                trafficMB = String.format("%.2f", traffic)
                                updateNotification()

                                if (!tunEstablished && !establishing) {
                                    if (active > 0) {
                                        consecutiveActiveTicks++
                                        if (consecutiveActiveTicks == 1) {
                                            publishState("checking", false, "Проверка")
                                        }
                                    } else {
                                        consecutiveActiveTicks = 0
                                        publishState("connecting", false, "Подключение")
                                    }
                                }
                            }
                        }
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "read log: ${e.message}")
                }
            }

            val readyForTun = !tunEstablished && !establishing &&
                consecutiveActiveTicks >= REQUIRED_ACTIVE_TICKS

            if (readyForTun) {
                establishing = true
                val established = establishTun()
                establishing = false

                if (established && isRunning) {
                    publishState("connected", true, "Подключено")
                    Log.i(TAG, "TUN created after $REQUIRED_ACTIVE_TICKS active ticks")
                } else if (isRunning) {
                    consecutiveActiveTicks = 0
                    rescanLogsRequested = true
                    delay(TUN_RETRY_DELAY_MS)
                }
            }

            delay(LOG_POLL_MS)
        }
    }

    private fun publishState(state: String, connected: Boolean, message: String) {
        val changed = state != connectionState || message != connectionMessage
        connectionState = state
        connectionMessage = message
        snapshotConnected = connected
        snapshotState = state
        snapshotMessage = message
        if (changed || connected) {
            notifyStatus(this, connected, state, message)
            updateNotification()
        }
    }

    private fun readRoutingSettings(): JSONObject {
        return try {
            val file = File(filesDir, "la-lune/settings.json")
            if (file.exists()) JSONObject(file.readText()) else JSONObject()
        } catch (e: Exception) {
            Log.w(TAG, "Unable to read routing settings: ${e.message}")
            JSONObject()
        }
    }

    private fun parseIpPrefix(entry: String): Pair<InetAddress, Int> {
        val value = normalizeIpPrefix(entry)
        val separator = value.lastIndexOf('/')
        require(separator > 0 && separator < value.lastIndex) { "invalid IP/CIDR: $entry" }
        val address = InetAddress.getByName(value.substring(0, separator))
        val prefixLength = value.substring(separator + 1).toInt()
        val maxPrefixLength = if (address.address.size == 4) 32 else 128
        require(prefixLength in 0..maxPrefixLength) { "invalid prefix length: $entry" }
        return address to prefixLength
    }

    private fun normalizeIpPrefix(entry: String): String {
        val value = entry.trim()
        require(value.isNotEmpty()) { "empty IP" }
        if (value.contains('/')) return value
        return value + if (value.contains(':')) "/128" else "/32"
    }

    private suspend fun establishTun(): Boolean = tunnelMutex.withLock {
        if (tunEstablished || !isRunning) return@withLock false
        Log.d(TAG, "establishTun")

        teardownTunnelOnlyLocked("before establish")
        try {
            val runtime = totsRuntime
            val isTots = runtime != null
            val tunIP = if (isTots) runtime!!.optString("virtualIp", DEFAULT_TUN_IP) else detectedTunIP ?: DEFAULT_TUN_IP
            val tunMtu = if (isTots) runtime!!.optInt("mtu", MTU).coerceIn(576, 1400) else MTU
            val dnsList = (detectedDNS ?: "$DEFAULT_DNS_1,$DEFAULT_DNS_2")
                .split(",").map { it.trim() }.filter { it.isNotEmpty() }

            val routing = readRoutingSettings()
            val builder = Builder()
                .setSession(if (isTots) "LaLune · ToTS" else "LaLune")
                .setMtu(tunMtu)
                .addAddress(tunIP, 32)

            val configuredIps = routing.optString("ipRoutingIps", "")
                .lines()
                .map { it.trim() }
                .filter { it.isNotEmpty() && !it.startsWith("#") }
                .distinct()
            val ipMode = routing.optString("ipRoutingMode", "blacklist")
            if (ipMode == "whitelist") {
                // White list: only explicitly listed destination networks enter the VPN.
                configuredIps.forEach { entry ->
                    try {
                        val (address, prefixLength) = parseIpPrefix(entry)
                        builder.addRoute(address, prefixLength)
                    } catch (e: Exception) {
                        Log.w(TAG, "Invalid whitelist IP/CIDR '$entry': ${e.message}")
                    }
                }
                if (configuredIps.isEmpty()) {
                    Log.w(TAG, "IP whitelist is empty: no destination IP routes will be added")
                }
            } else {
                builder.addRoute(InetAddress.getByName("0.0.0.0"), 0)
                configuredIps.forEach { entry ->
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            builder.excludeRoute(parseIpPrefix(entry).let { (address, prefixLength) -> IpPrefix(address, prefixLength) })
                        } else {
                            Log.w(TAG, "IP blacklist exclusions require Android 13+; cannot bypass '$entry' on this Android version")
                        }
                    } catch (e: Exception) {
                        Log.w(TAG, "Invalid blacklist IP/CIDR '$entry': ${e.message}")
                    }
                }
            }

            val appMode = routing.optString("androidAppRoutingMode", "blacklist")
            val appArray = routing.optJSONArray("androidVpnApps") ?: JSONArray()
            val selectedPackages = (0 until appArray.length())
                .mapNotNull { appArray.optString(it).takeIf { name -> name.isNotBlank() } }
                .filter { !isTots || it != packageName }
                .distinct()
            if (appMode == "whitelist") {
                // With an allow-list Android cannot simultaneously add the VPN
                // host to the disallow-list. Therefore at least one *other* app
                // must be allowed for ToTS; otherwise an empty allow-list means
                // "all apps" and the native ToTS transport would recurse into
                // its own TUN.
                if (isTots && selectedPackages.isEmpty()) {
                    Log.e(TAG, "ToTS app whitelist is empty after excluding the LaLune package")
                    notifyLog(this@LaLuneVpnService, "[VPN] ToTS: выберите хотя бы одно приложение для whitelist")
                    return@withLock false
                }
                var allowedCount = 0
                selectedPackages.forEach { packageName ->
                    try {
                        builder.addAllowedApplication(packageName)
                        allowedCount++
                    } catch (e: Exception) {
                        Log.w(TAG, "Cannot allow app '$packageName': ${e.message}")
                    }
                }
                if (isTots && allowedCount == 0) {
                    Log.e(TAG, "ToTS app whitelist has no valid applications")
                    notifyLog(this@LaLuneVpnService, "[VPN] ToTS: whitelist не содержит доступных приложений")
                    return@withLock false
                }
            } else {
                selectedPackages.forEach { packageName ->
                    try {
                        builder.addDisallowedApplication(packageName)
                    } catch (e: Exception) {
                        Log.w(TAG, "Cannot bypass app '$packageName': ${e.message}")
                    }
                }
            }

            if (dnsList.isEmpty()) {
                builder.addDnsServer(DEFAULT_DNS_1)
                builder.addDnsServer(DEFAULT_DNS_2)
            } else {
                dnsList.forEach { builder.addDnsServer(it) }
            }

            if (routing.optString("androidAppRoutingMode", "blacklist") != "whitelist") {
                try {
                    builder.addDisallowedApplication(packageName)
                } catch (e: Exception) {
                    Log.w(TAG, "addDisallowedApplication failed: ${e.message}")
                }
            }

            builder.setBlocking(true)

            val iface = withContext(Dispatchers.Main) { builder.establish() } ?: run {
                Log.e(TAG, "establish() null — no VPN permission")
                return@withLock false
            }

            if (isTots) {
                val inherited = try {
                    ParcelFileDescriptor.dup(iface.fileDescriptor)
                } catch (e: Exception) {
                    try { iface.close() } catch (_: Exception) {}
                    Log.e(TAG, "cannot duplicate ToTS TUN fd: ${e.message}", e)
                    return@withLock false
                }
                // Do not pass the numeric fd through ProcessBuilder. Android's
                // child-process launcher may close non-standard descriptors even
                // after FD_CLOEXEC has been cleared. Transfer it explicitly with
                // SCM_RIGHTS over an abstract AF_UNIX socket instead.
                val fdSocketName = "lalune-tots-${UUID.randomUUID().toString().replace("-", "")}"
                val fdServer = try {
                    LocalServerSocket(fdSocketName)
                } catch (e: Exception) {
                    try { inherited.close() } catch (_: Exception) {}
                    try { iface.close() } catch (_: Exception) {}
                    Log.e(TAG, "cannot create ToTS fd handoff socket: ${e.message}", e)
                    notifyLog(this@LaLuneVpnService, "[VPN] cannot create ToTS fd handoff socket: ${e.message.orEmpty()}")
                    return@withLock false
                }
                val jsonArgs = runtime!!.optJSONArray("args") ?: JSONArray()
                val args = mutableListOf<String>()
                for (i in 0 until jsonArgs.length()) args += jsonArgs.optString(i)
                args += "--tun-fd-socket"
                args += fdSocketName

                val generation = ++tunnelGeneration
                val session = snapshotSessionId
                vpnInterface = iface
                totsTunFd = inherited
                nativeTraffic = NativeTunTraffic.forAddress(tunIP)
                tunEstablished = true
                notifyLog(this@LaLuneVpnService, "[VPN] TUN fd=${inherited.fd} ready; starting ToTS")
                val coreTunReady = CompletableDeferred<Boolean>()
                val started = coreManager.startCore(
                    protocol = CoreManager.PROTO_TOTS,
                    args = args,
                    onLog = { line ->
                        Log.i(TAG, line)
                        notifyLog(this@LaLuneVpnService, line, core = true)
                        if (generation == tunnelGeneration && session == snapshotSessionId) {
                            TotsWorkers.parse(line)?.let {
                                workerSample = WorkerSample(session, SystemClock.elapsedRealtime(), it)
                                updateNotification()
                            }
                            if (line.contains("[CORE] process exited")) workerSample = null
                        }
                        when {
                            line.contains("ToTS Android TUN connected") -> coreTunReady.complete(true)
                            line.contains("[CORE] process exited") || line.contains("Error:") -> coreTunReady.complete(false)
                        }
                    },
                )
                if (!started) {
                    nativeTraffic?.finish()
                    try { fdServer.close() } catch (_: Exception) {}
                    notifyLog(this@LaLuneVpnService, "[VPN] ToTS process failed to start")
                    tunEstablished = false
                    try { inherited.close() } catch (_: Exception) {}
                    totsTunFd = null
                    try { iface.close() } catch (_: Exception) {}
                    vpnInterface = null
                    return@withLock false
                }
                val handedOff = try {
                    val acceptJob = scope.async(Dispatchers.IO) { fdServer.accept() }
                    val client = withTimeoutOrNull(15_000) { acceptJob.await() }
                    if (client == null) {
                        try { fdServer.close() } catch (_: Exception) {}
                        acceptJob.cancel()
                        throw IOException("ToTS did not request the TUN descriptor within 15 seconds")
                    }
                    client.use { socket ->
                        socket.setFileDescriptorsForSend(arrayOf(inherited.fileDescriptor))
                        // Android attaches SCM_RIGHTS descriptors to the next write.
                        socket.outputStream.write(1)
                        socket.outputStream.flush()
                    }
                    true
                } catch (e: Exception) {
                    Log.e(TAG, "ToTS TUN fd handoff failed: ${e.message}", e)
                    notifyLog(this@LaLuneVpnService, "[VPN] ToTS TUN fd handoff failed: ${e.message.orEmpty()}")
                    false
                } finally {
                    try { fdServer.close() } catch (_: Exception) {}
                }
                if (!handedOff) {
                    nativeTraffic?.finish()
                    coreManager.stopCore()
                    tunEstablished = false
                    try { inherited.close() } catch (_: Exception) {}
                    totsTunFd = null
                    try { iface.close() } catch (_: Exception) {}
                    vpnInterface = null
                    return@withLock false
                }
                notifyLog(this@LaLuneVpnService, "[VPN] TUN descriptor transferred; waiting for ToTS to confirm epoll readiness")
                val ready = withTimeoutOrNull(15_000) { coreTunReady.await() } == true
                if (!ready) {
                    nativeTraffic?.finish()
                    notifyLog(this@LaLuneVpnService, "[VPN] ToTS did not confirm TUN readiness")
                    coreManager.stopCore()
                    tunEstablished = false
                    try { inherited.close() } catch (_: Exception) {}
                    totsTunFd = null
                    try { iface.close() } catch (_: Exception) {}
                    vpnInterface = null
                    return@withLock false
                }
                Log.i(TAG, "ToTS TUN up and epoll-ready: IP=$tunIP MTU=$tunMtu fd=${inherited.fd}")
                notifyLog(this@LaLuneVpnService, "[VPN] ToTS TUN connected; IP=$tunIP MTU=$tunMtu")
                updateNotification()
                return@withLock true
            }

            val socket = try {
                DatagramSocket().also { bridge ->
                    // UDP-мост к ядру обязан идти вне VPN, иначе получим рекурсию.
                    if (!protect(bridge)) Log.w(TAG, "protect(UDP bridge) returned false")
                    bridge.connect(InetAddress.getByName("127.0.0.1"), CORE_PORT)
                }
            } catch (e: Exception) {
                try { iface.close() } catch (_: Exception) {}
                Log.e(TAG, "setupSocket: ${e.message}", e)
                return@withLock false
            }

            tunnelGeneration++
            val generation = tunnelGeneration
            vpnInterface = iface
            udpSocket = socket
            tunEstablished = true
            Log.i(TAG, "TUN up: IP=$tunIP, UDP bridge to 127.0.0.1:$CORE_PORT")

            bridgeJobs.forEach { it.cancel() }
            bridgeJobs.clear()
            bridgeJobs += scope.launch { tunToUdp(iface, socket, generation) }
            bridgeJobs += scope.launch { udpToTun(iface, socket, generation) }
            updateNotification()
            true
        } catch (e: Exception) {
            Log.e(TAG, "establishTun: ${e.message}", e)
            teardownTunnelOnlyLocked("establish failed")
            false
        }
    }

    private suspend fun tunToUdp(
        iface: ParcelFileDescriptor,
        socket: DatagramSocket,
        generation: Long,
    ) {
        val input = FileInputStream(iface.fileDescriptor)
        val buf = ByteArray(65535)
        while (isRunning && tunEstablished && generation == tunnelGeneration) {
            try {
                val n = input.read(buf)
                if (n > 0) {
                    socket.send(DatagramPacket(buf.copyOf(n), n))
                    tunTxBytes.addAndGet(n.toLong())
                }
            } catch (e: Exception) {
                if (isRunning && generation == tunnelGeneration) Log.w(TAG, "tunToUdp: ${e.message}")
                break
            }
        }
    }

    private suspend fun udpToTun(
        iface: ParcelFileDescriptor,
        socket: DatagramSocket,
        generation: Long,
    ) {
        val output = FileOutputStream(iface.fileDescriptor)
        val buf = ByteArray(65535)
        while (isRunning && tunEstablished && generation == tunnelGeneration) {
            try {
                val packet = DatagramPacket(buf, buf.size)
                socket.receive(packet)
                output.write(packet.data, 0, packet.length)
                tunRxBytes.addAndGet(packet.length.toLong())
            } catch (e: Exception) {
                if (isRunning && generation == tunnelGeneration) Log.w(TAG, "udpToTun: ${e.message}")
                break
            }
        }
    }

    private suspend fun teardownTunnelOnly(reason: String) = tunnelMutex.withLock {
        teardownTunnelOnlyLocked(reason)
    }

    private fun teardownTunnelOnlyLocked(reason: String) {
        if (tunEstablished || vpnInterface != null || udpSocket != null) {
            Log.i(TAG, "closing TUN only ($reason); core remains running")
        }
        tunnelGeneration++
        tunEstablished = false
        nativeTraffic?.finish()
        workerSample = null
        bridgeJobs.forEach { it.cancel() }
        bridgeJobs.clear()
        try { udpSocket?.close() } catch (_: Exception) {}
        udpSocket = null
        try { totsTunFd?.close() } catch (_: Exception) {}
        totsTunFd = null
        try { vpnInterface?.close() } catch (_: Exception) {}
        vpnInterface = null
    }

    private fun stopFlow() {
        Log.d(TAG, "stopFlow")
        isRunning = false
        establishing = false
        flowJob?.cancel()
        flowJob = null
        notificationTickerJob?.cancel()
        notificationTickerJob = null

        tunnelGeneration++
        tunEstablished = false
        nativeTraffic?.finish()
        workerSample = null
        totsWorkersTarget = 0
        bridgeJobs.forEach { it.cancel() }
        bridgeJobs.clear()
        try { udpSocket?.close() } catch (_: Exception) {}
        udpSocket = null
        try { totsTunFd?.close() } catch (_: Exception) {}
        totsTunFd = null
        try { vpnInterface?.close() } catch (_: Exception) {}
        vpnInterface = null

        if (totsRuntime != null) {
            coreManager.stopCore()
            try { File(filesDir, "la-lune/tots_runtime.json").delete() } catch (_: Exception) {}
        }
        totsRuntime = null

        activeSessions = 0
        snapshotActiveSessions = 0
        consecutiveActiveTicks = 0
        trafficMB = "0.00"
        detectedTunIP = null
        detectedDNS = null
        connectionState = "disconnected"
        connectionMessage = ""
        notifyStatus(this, false, "disconnected", "")
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        stopFlow()
        scope.cancel()
        snapshotConnected = false
        snapshotSessionId = ""
        snapshotConfigId = 0
        snapshotState = "disconnected"
        snapshotMessage = ""
        super.onDestroy()
    }

    private fun buildNotification(): Notification {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val mgr = getSystemService(NotificationManager::class.java)
            if (mgr.getNotificationChannel(CHANNEL_ID) == null) {
                val ch = NotificationChannel(
                    CHANNEL_ID, "LaLune VPN", NotificationManager.IMPORTANCE_LOW
                )
                ch.setShowBadge(false)
                ch.lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                mgr.createNotificationChannel(ch)
            }
        }

        val openIntent = packageManager.getLaunchIntentForPackage(packageName)
        val openPending = PendingIntent.getActivity(
            this, 0, openIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val stopIntent = Intent(this, LaLuneVpnService::class.java).apply {
            action = ACTION_STOP
        }
        val stopPending = PendingIntent.getService(
            this, 1, stopIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val text = when (connectionState) {
            "checking" -> "Проверка"
            "connected" -> if (usesNativeTun) {
                val workers = currentTotsWorkers()
                val active = workers?.active?.toString() ?: "—"
                val target = workers?.target ?: totsWorkersTarget
                val traffic = trafficBytes()?.let {
                    String.format(java.util.Locale.getDefault(), "%.2f МБ", (it.rx + it.tx) / 1048576.0)
                } ?: "—"
                "Активных: $active/$target | Трафик: $traffic"
            } else "Активных: $activeSessions | Трафик: $trafficMB МБ"
            else -> "Подключение"
        }

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("LaLune")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentIntent(openPending)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .addAction(
                android.R.drawable.ic_menu_close_clear_cancel,
                "Отключить",
                stopPending
            )
            .build()
    }

    private fun updateNotification() {
        try {
            val mgr = getSystemService(NotificationManager::class.java)
            mgr.notify(NOTIFICATION_ID, buildNotification())
        } catch (e: Exception) {
            Log.w(TAG, "updateNotification: ${e.message}")
        }
    }

    private fun startForegroundCompat() {
        val n = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ServiceCompat.startForeground(
                this, NOTIFICATION_ID, n,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            )
        } else {
            startForeground(NOTIFICATION_ID, n)
        }
    }
}
