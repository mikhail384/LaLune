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
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.net.IpPrefix
import android.net.LocalServerSocket
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.system.StructPollfd
import android.util.Log
import androidx.core.content.ContextCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File
import java.io.FileDescriptor
import java.io.RandomAccessFile
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
        const val ACTION_SETTINGS_CHANGED = "com.lalune.lalune.SETTINGS_CHANGED"
        const val SETTING_AUTO_SLEEP = "androidAutoSleepTunnel"
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

        @Volatile var snapshotConnected: Boolean = false
        @Volatile var snapshotTunnelSleeping: Boolean = false
        @Volatile var snapshotActiveSessions: Int = 0
        @Volatile var snapshotSessionId: String = ""
        @Volatile var snapshotConfigId: Long = 0
        @Volatile var snapshotState: String = "disconnected"
        @Volatile var snapshotMessage: String = ""
        @Volatile private var activeService: LaLuneVpnService? = null

        fun probeTunnelLatency(configId: Long): Long? = activeService?.measureLatency(configId)

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

    private var vpnInterface: ParcelFileDescriptor? = null
    private var udpSocket: DatagramSocket? = null
    private var totsTransport: ParcelFileDescriptor? = null
    private var totsReader: Job? = null
    private var coreReady = false
    private var totsRuntime: JSONObject? = null
    @Volatile private var isRunning = false
    @Volatile private var tunEstablished = false
    @Volatile private var tunnelGeneration = 0L

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val tunnelMutex = Mutex()
    private val tunnelUpdates = Channel<Unit>(Channel.CONFLATED)
    private val sleepReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            tunnelUpdates.trySend(Unit)
        }
    }
    private var stopping = false
    private lateinit var coreManager: CoreManager
    private val latencyProbe = TunnelLatencyProbe()
    private var tunAddress: String? = null
    private var notificationTickerJob: Job? = null
    private var flowJob: Job? = null
    private val bridgeJobs = mutableListOf<Job>()

    override fun onCreate() {
        super.onCreate()
        coreManager = CoreManager(this)
        activeService = this
        startForegroundCompat()
        ContextCompat.registerReceiver(this, sleepReceiver, IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(ACTION_SETTINGS_CHANGED)
        }, ContextCompat.RECEIVER_NOT_EXPORTED)
        scope.launch {
            for (update in tunnelUpdates) {
                while (isActive && !reconcileTunnel()) delay(TUN_RETRY_DELAY_MS)
            }
        }
        notifyLog(this, "[VPN] service created")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            "START" -> if (!isRunning && !stopping) {
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
                val started = tunnelMutex.withLock {
                    if (!isRunning) return@withLock false
                    startTotsCoreLocked(totsRuntime!!).also { coreReady = it }
                }
                if (started) {
                    tunnelUpdates.trySend(Unit)
                } else if (isRunning) {
                    publishState("error", false, "Не удалось запустить ToTS")
                    withContext(Dispatchers.Main) { stopFlow() }
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

                                if (consecutiveActiveTicks < REQUIRED_ACTIVE_TICKS && isRunning) {
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

            if (consecutiveActiveTicks >= REQUIRED_ACTIVE_TICKS) {
                tunnelMutex.withLock {
                    if (isRunning && !coreReady) {
                        coreReady = true
                        tunnelUpdates.trySend(Unit)
                    }
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

    private suspend fun reconcileTunnel(): Boolean = tunnelMutex.withLock {
        if (!isRunning || !coreReady) return@withLock true
        val routing = readRoutingSettings()
        val interactive = getSystemService(PowerManager::class.java)?.isInteractive ?: true
        if (!interactive && routing.optBoolean(SETTING_AUTO_SLEEP, true)) {
            if (!snapshotTunnelSleeping) {
                snapshotTunnelSleeping = true
                teardownTunnelOnlyLocked("screen off")
                if (isRunning) publishState("connected", true, "Туннель спит")
            }
            return@withLock true
        }
        if (tunEstablished) return@withLock true
        if (!establishTunLocked(routing)) {
            if (isRunning && totsRuntime != null && !snapshotConnected) {
                publishState("error", false, "Не удалось создать TUN для ToTS")
                scope.launch(Dispatchers.Main) { stopFlow() }
                return@withLock true
            }
            return@withLock false
        }
        snapshotTunnelSleeping = false
        if (isRunning) publishState("connected", true, "Подключено")
        true
    }

    private fun establishTunLocked(routing: JSONObject): Boolean {
        Log.d(TAG, "establishTun")

        teardownTunnelOnlyLocked("before establish")
        return try {
            val runtime = totsRuntime
            val isTots = runtime != null
            val tunIP = if (isTots) runtime!!.optString("virtualIp", DEFAULT_TUN_IP) else detectedTunIP ?: DEFAULT_TUN_IP
            val transport = if (isTots) checkNotNull(totsTransport) else null
            val tunMtu = if (isTots) runtime!!.optInt("mtu", MTU).coerceIn(576, 1400) else MTU
            val dnsList = (detectedDNS ?: "$DEFAULT_DNS_1,$DEFAULT_DNS_2")
                .split(",").map { it.trim() }.filter { it.isNotEmpty() }

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
                    return false
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
                    return false
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

            builder.setBlocking(false)

            val iface = builder.establish() ?: run {
                Log.e(TAG, "establish() null — no VPN permission")
                return false
            }

            if (transport != null) {
                tunnelGeneration++
                vpnInterface = iface
                tunAddress = tunIP
                tunEstablished = true
                val generation = tunnelGeneration
                bridgeJobs += scope.launch {
                    readTun(iface, generation) { buf, size -> writePacket(transport, buf, size) }
                }
                notifyLog(this, "[VPN] ToTS TUN connected; IP=$tunIP MTU=$tunMtu")
                return true
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
                return false
            }

            tunnelGeneration++
            val generation = tunnelGeneration
            vpnInterface = iface
            udpSocket = socket
            tunAddress = tunIP
            tunEstablished = true
            Log.i(TAG, "TUN up: IP=$tunIP, UDP bridge to 127.0.0.1:$CORE_PORT")

            bridgeJobs += scope.launch {
                readTun(iface, generation) { buf, size ->
                    socket.send(DatagramPacket(buf, size))
                    true
                }
            }
            bridgeJobs += scope.launch { udpToTun(iface, socket, generation) }
            updateNotification()
            true
        } catch (e: Exception) {
            Log.e(TAG, "establishTun: ${e.message}", e)
            teardownTunnelOnlyLocked("establish failed")
            false
        }
    }

    /** Keep a packet-oriented endpoint alive across VpnService TUN generations.
     * The ToTS runner uses read/write and epoll on the supplied descriptor;
     * passing the real TUN would let its process keep the interface open. */
    private suspend fun startTotsCoreLocked(runtime: JSONObject): Boolean {
        val localFd = FileDescriptor()
        val coreFd = FileDescriptor()
        var ok = false
        try {
            Os.socketpair(OsConstants.AF_UNIX, OsConstants.SOCK_DGRAM or OsConstants.SOCK_CLOEXEC, 0, localFd, coreFd)
            Os.fcntlInt(localFd, OsConstants.F_SETFL, OsConstants.O_NONBLOCK)
            val transport = ParcelFileDescriptor.dup(localFd)
            totsTransport = transport
            val fdSocketName = "lalune-tots-${UUID.randomUUID().toString().replace("-", "")}"
            val coreTunReady = CompletableDeferred<Boolean>()
            LocalServerSocket(fdSocketName).use { server ->
                val jsonArgs = runtime.optJSONArray("args") ?: JSONArray()
                val args = MutableList(jsonArgs.length()) { jsonArgs.optString(it) }
                args += listOf("--tun-fd-socket", fdSocketName)
                if (!coreManager.startCore(CoreManager.PROTO_TOTS, args = args, onLog = { line ->
                        Log.i(TAG, line)
                        notifyLog(this, line, core = true)
                        when {
                            line.contains("ToTS Android TUN connected") -> coreTunReady.complete(true)
                            line.contains("[CORE] process exited") || line.contains("Error:") ->
                                coreTunReady.complete(false)
                        }
                    })) return false
                val handoff = scope.async {
                    server.accept().use { socket ->
                        if (socket.peerCredentials.uid != android.os.Process.myUid()) {
                            throw IOException("unexpected ToTS socket peer")
                        }
                        socket.setFileDescriptorsForSend(arrayOf(coreFd))
                        socket.outputStream.write(1)
                    }
                }
                try {
                    if (withTimeoutOrNull(15_000) { handoff.await() } == null) {
                        throw IOException("ToTS did not request the packet descriptor")
                    }
                } finally {
                    handoff.cancel()
                }
            }
            if (withTimeoutOrNull(15_000) { coreTunReady.await() } != true) {
                throw IOException("ToTS did not confirm packet transport readiness")
            }
            totsReader = scope.launch { readFromTots(transport) }
            ok = true
            return true
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.e(TAG, "ToTS packet transport startup failed", e)
            notifyLog(this, "[VPN] ToTS packet transport startup failed: ${e.message.orEmpty()}")
            return false
        } finally {
            if (localFd.valid()) runCatching { Os.close(localFd) }
            if (coreFd.valid()) runCatching { Os.close(coreFd) }
            if (!ok) {
                coreManager.stopCore()
                closeTotsTransportLocked()
            }
        }
    }

    private fun tunnelActive(generation: Long): Boolean =
        isRunning && tunEstablished && generation == tunnelGeneration

    private fun measureLatency(configId: Long): Long? = runBlocking {
        val (source, generation) = tunnelMutex.withLock {
            if (!tunnelActive(tunnelGeneration) || snapshotConfigId != configId) return@runBlocking null
            (tunAddress ?: return@runBlocking null) to tunnelGeneration
        }
        val elapsed = latencyProbe.measure(source) { packet ->
            runBlocking {
                tunnelMutex.withLock {
                    if (!tunnelActive(generation) || snapshotConfigId != configId) {
                        throw IOException("tunnel detached")
                    }
                    val transport = totsTransport
                    if (transport != null) {
                        if (!writePacket(transport, packet, packet.size)) throw IOException("transport busy")
                    } else {
                        val socket = udpSocket ?: throw IOException("transport missing")
                        socket.send(DatagramPacket(packet, packet.size))
                    }
                }
            }
        }
        elapsed.takeIf { tunnelActive(generation) && snapshotConfigId == configId }
    }

    // Nonblocking descriptors let a detach invalidate an old bridge without
    // leaving threads behind in a blocking read or write on that TUN.
    private fun waitForPacket(poll: Array<StructPollfd>): Boolean {
        if (Os.poll(poll, 250) == 0) return false
        if ((poll[0].revents.toInt() and OsConstants.POLLIN) == 0) {
            throw IOException("packet descriptor no longer readable")
        }
        return true
    }

    private fun readPacket(fd: FileDescriptor, buf: ByteArray): Int = try {
        Os.read(fd, buf, 0, buf.size)
    } catch (e: ErrnoException) {
        if (e.errno == OsConstants.EAGAIN || e.errno == OsConstants.EINTR) 0 else throw e
    }

    private fun writePacket(fd: ParcelFileDescriptor, buf: ByteArray, size: Int): Boolean = try {
        Os.write(fd.fileDescriptor, buf, 0, size) == size
    } catch (e: ErrnoException) {
        if (e.errno == OsConstants.EAGAIN || e.errno == OsConstants.EINTR || e.errno == OsConstants.ENOBUFS) {
            false // Best effort, like the UDP bridge.
        } else throw e
    }

    private fun pollRead(fd: FileDescriptor): Array<StructPollfd> = arrayOf(StructPollfd().apply {
        this.fd = fd
        events = OsConstants.POLLIN.toShort()
    })

    private suspend fun readTun(
        iface: ParcelFileDescriptor,
        generation: Long,
        send: (ByteArray, Int) -> Boolean,
    ) {
        val fd = iface.fileDescriptor
        val poll = pollRead(fd)
        val buf = ByteArray(65535)
        try {
            while (tunnelActive(generation)) {
                if (!waitForPacket(poll)) continue
                if (!tunnelActive(generation)) break
                val n = readPacket(fd, buf)
                if (n > 0 && tunnelActive(generation) && send(buf, n)) tunTxBytes.addAndGet(n.toLong())
            }
        } catch (e: Exception) {
            if (tunnelActive(generation)) Log.w(TAG, "TUN -> core: ${e.message}")
        }
    }

    private suspend fun readFromTots(transport: ParcelFileDescriptor) {
        val fd = transport.fileDescriptor
        val poll = pollRead(fd)
        val buf = ByteArray(65535)
        try {
            while (isRunning) {
                if (!waitForPacket(poll)) continue
                tunnelMutex.withLock {
                    if (!isRunning) return
                    val n = readPacket(fd, buf)
                    // Keep draining the core even with no TUN so it never stalls.
                    if (n > 0 && tunEstablished) vpnInterface?.let { writeToTun(it, buf, n) }
                }
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            if (isRunning) Log.w(TAG, "ToTS -> TUN: ${e.message}")
        }
    }

    private fun writeToTun(iface: ParcelFileDescriptor, buf: ByteArray, n: Int) {
        if (!latencyProbe.consume(buf, n) && writePacket(iface, buf, n)) tunRxBytes.addAndGet(n.toLong())
    }

    private fun udpToTun(iface: ParcelFileDescriptor, socket: DatagramSocket, generation: Long) {
        val buf = ByteArray(65535)
        val packet = DatagramPacket(buf, buf.size)
        try {
            while (tunnelActive(generation)) {
                packet.length = buf.size
                socket.receive(packet)
                if (tunnelActive(generation)) writeToTun(iface, packet.data, packet.length)
            }
        } catch (e: Exception) {
            if (tunnelActive(generation)) Log.w(TAG, "UDP -> TUN: ${e.message}")
        }
    }

    private fun teardownTunnelOnlyLocked(reason: String) {
        if (tunEstablished || vpnInterface != null || udpSocket != null) {
            Log.i(TAG, "closing TUN only ($reason); core remains running")
        }
        tunnelGeneration++
        tunEstablished = false
        latencyProbe.cancel()
        tunAddress = null
        bridgeJobs.forEach { it.cancel() }
        bridgeJobs.clear()
        udpSocket?.close()
        udpSocket = null
        runCatching { vpnInterface?.close() }
        vpnInterface = null
    }

    private fun closeTotsTransportLocked() {
        totsReader?.cancel()
        totsReader = null
        runCatching { totsTransport?.close() }
        totsTransport = null
    }

    override fun onRevoke() {
        // An actual revoke (including replacement by another VPN) must never
        // get interpreted as a screen sleep and later re-establish the TUN.
        scope.launch(Dispatchers.Main) { stopFlow() }
    }

    private fun stopFlow() {
        if (stopping) return
        stopping = true
        isRunning = false
        flowJob?.cancel()
        notificationTickerJob?.cancel()
        scope.launch {
            tunnelMutex.withLock { releaseSessionLocked() }
            withContext(Dispatchers.Main) {
                publishState("disconnected", false, "")
                ServiceCompat.stopForeground(this@LaLuneVpnService, ServiceCompat.STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }
    }

    private fun releaseSessionLocked() {
        teardownTunnelOnlyLocked("service stop")
        if (totsRuntime != null) {
            coreManager.stopCore()
            runCatching { File(filesDir, "la-lune/tots_runtime.json").delete() }
        }
        closeTotsTransportLocked()
        totsRuntime = null
        coreReady = false
        snapshotTunnelSleeping = false
        snapshotActiveSessions = 0
    }

    override fun onDestroy() {
        isRunning = false
        unregisterReceiver(sleepReceiver)
        tunnelUpdates.close()
        scope.cancel()
        runBlocking { tunnelMutex.withLock { releaseSessionLocked() } }
        publishState("disconnected", false, "")
        activeService = null
        snapshotSessionId = ""
        snapshotConfigId = 0
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
            "connected" -> if (snapshotTunnelSleeping) "Туннель спит"
                           else "Активных: $activeSessions | Трафик: $trafficMB МБ"
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
