// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// MainActivity: поднимает Backend, подключает Flutter UI поверх,
// отвечает за VPN-permission и notification-permission.
//
// Backend запускает и перезапускает ТОЛЬКО этот класс (единственный владелец):
//  * ensureBackend() — single-flight (Mutex) и идемпотентный;
//  * startup grace — пока backend стартует, перезапуск не нужен;
//  * exponential backoff между перезапусками;
//  * Dart-watchdog только наблюдает за /ping и не перезапускает backend.
//
// ВАЖНО: Backend и LaLuneVpnService теперь в ТОМ ЖЕ package
// (com.lalune.lalune), а не в com.lalune.lalune.<sub>.

package com.lalune.lalune

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.net.HttpURLConnection
import java.net.URL
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONObject

class MainActivity : FlutterActivity() {

    companion object {
        private const val TAG = "LaLune-MainActivity"
        private const val CHANNEL = "com.lalune/native"
        private const val REQ_VPN = 101
        private const val REQ_NOTIFICATIONS = 102

        private const val WATCHDOG_INTERVAL_MS = 3000L
        // Сколько ждём готовности только что запущенного backend, прежде чем
        // считать его зависшим.
        private const val STARTUP_GRACE_MS = 20_000L
        private const val BACKOFF_BASE_MS = 3_000L
        private const val BACKOFF_MAX_MS = 60_000L

        // Backend живёт на уровне процесса: пересозданная Activity (поворот,
        // swipe из recents) подхватывает его, а не пытается занять порт заново.
        @Volatile private var sharedBackend: Backend? = null
        @Volatile private var backendStartedAt = 0L
        @Volatile private var restartCount = 0
        @Volatile private var lastRestartAt = 0L
        // Подряд идущие неудачные /ping у уже ГОТОВОГО backend. Один сбой
        // (GC, пауза CPU, разморозка процесса) не повод для перезапуска.
        @Volatile private var pingFailures = 0
        private const val PING_FAILURES_BEFORE_RESTART = 3
        private const val PING_TIMEOUT_MS = 3000
        private val backendMutex = Mutex()
    }

    private var methodChannel: MethodChannel? = null
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private var watchdogJob: Job? = null

    private val apiPort: Int get() = Backend.portFor(packageName)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Log.i(TAG, "onCreate pkg=$packageName apiPort=$apiPort")

        sharedBackend?.attachActivity(this)
        requestNotificationPermissionIfNeeded()
        startApiWatchdog()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "getApiPort" -> result.success(apiPort)
                "isBackendAlive" -> {
                    scope.launch {
                        val alive = isBackendAlive()
                        runOnUiThread { result.success(alive) }
                    }
                }
                // Запрос из Dart идёт в тот же single-flight путь, что и
                // собственный watchdog: повторные вызовы безопасны.
                "restartBackend", "ensureBackend" -> {
                    scope.launch { ensureBackend("dart") }
                    result.success(true)
                }
                "openUrl" -> {
                    // Только https-ссылки; открывает браузер/Telegram.
                    val url = call.argument<String>("url").orEmpty()
                    if (!url.startsWith("https://")) {
                        result.error("bad_url", "only https urls are allowed", null)
                    } else try {
                        startActivity(
                            Intent(Intent.ACTION_VIEW, android.net.Uri.parse(url))
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        )
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("open_failed", e.javaClass.simpleName, null)
                    }
                }
                "requestVpnPermission" -> {
                    requestVpnPermission()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val granted = ContextCompat.checkSelfPermission(
            this, Manifest.permission.POST_NOTIFICATIONS
        ) == PackageManager.PERMISSION_GRANTED
        if (!granted) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                REQ_NOTIFICATIONS
            )
        }
    }

    private fun requestVpnPermission() {
        val intent = VpnService.prepare(this)
        if (intent != null) {
            startActivityForResult(intent, REQ_VPN)
        } else {
            Log.i(TAG, "VPN permission already granted")
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQ_VPN) {
            if (resultCode == RESULT_OK) {
                sharedBackend?.onVpnPermissionGranted()
            } else {
                sharedBackend?.onVpnPermissionDenied()
            }
        }
    }

    private fun startApiWatchdog() {
        watchdogJob?.cancel()
        watchdogJob = scope.launch {
            // Первый запуск сразу, дальше — по таймеру.
            ensureBackend("startup")
            while (isActive) {
                delay(WATCHDOG_INTERVAL_MS)
                ensureBackend("watchdog")
            }
        }
    }

    /** /ping отвечает именно НАШ backend (проверяем package), а не чужой. */
    private fun isBackendAlive(): Boolean {
        var conn: HttpURLConnection? = null
        return try {
            conn = URL("http://127.0.0.1:$apiPort/ping").openConnection() as HttpURLConnection
            conn.connectTimeout = PING_TIMEOUT_MS
            conn.readTimeout = PING_TIMEOUT_MS
            conn.requestMethod = "GET"
            if (conn.responseCode !in 200..299) return false
            val body = conn.inputStream.bufferedReader().use { it.readText() }
            val pkg = JSONObject(body).optString("package", "")
            pkg.isEmpty() || pkg == packageName
        } catch (_: Exception) {
            false
        } finally {
            try { conn?.disconnect() } catch (_: Exception) {}
        }
    }

    /**
     * Единственная точка запуска/перезапуска backend.
     * Идемпотентна и single-flight: если другой вызов уже работает — выходим.
     */
    private suspend fun ensureBackend(reason: String) {
        if (!backendMutex.tryLock()) {
            Log.d(TAG, "ensureBackend($reason): busy, skip")
            return
        }
        try {
            val now = SystemClock.elapsedRealtime()
            var current = sharedBackend

            if (current != null) {
                if (current.httpReady && isBackendAlive()) {
                    if (restartCount != 0) Log.i(TAG, "backend recovered after $restartCount restart(s)")
                    if (pingFailures != 0) Log.i(TAG, "ping recovered after $pingFailures failure(s), no restart needed")
                    restartCount = 0
                    pingFailures = 0
                    current.attachActivity(this)
                    return
                }
                if (current.httpReady) {
                    // Готовый backend не ответил: перезапускаем только после
                    // нескольких неудач подряд, а не по одному таймауту.
                    pingFailures++
                    if (pingFailures < PING_FAILURES_BEFORE_RESTART) {
                        Log.w(TAG, "ping failed ($pingFailures/$PING_FAILURES_BEFORE_RESTART), waiting")
                        return
                    }
                    // Сервер жив (accept-цикл работает), просто не ответил: это
                    // типично для энергосбережения/выключенного экрана. Перезапуск
                    // оборвал бы работающий VPN, поэтому в этих случаях не трогаем.
                    val screenOn = (getSystemService(POWER_SERVICE) as? android.os.PowerManager)
                        ?.isInteractive ?: true
                    if (LaLuneVpnService.snapshotConnected || !screenOn) {
                        if (pingFailures == PING_FAILURES_BEFORE_RESTART) {
                            Log.w(
                                TAG,
                                "ping failing but server is up; no restart " +
                                    "(vpn=${LaLuneVpnService.snapshotConnected}, screenOn=$screenOn)"
                            )
                        }
                        return
                    }
                }
                val age = now - backendStartedAt
                if (current.httpError.isEmpty() && !current.httpReady && age < STARTUP_GRACE_MS) {
                    Log.d(TAG, "ensureBackend($reason): starting, ${age}ms < grace")
                    return
                }
                // Backoff: 3s, 6s, 12s ... 60s между попытками.
                val wait = minOf(BACKOFF_MAX_MS, BACKOFF_BASE_MS shl minOf(restartCount, 5))
                if (now - lastRestartAt < wait) {
                    Log.d(TAG, "ensureBackend($reason): backoff ${wait}ms")
                    return
                }
                Log.w(
                    TAG,
                    "backend not healthy (reason=$reason ready=${current.httpReady} " +
                        "err='${current.httpError}', restart #${restartCount + 1})"
                )
                try { current.stop() } catch (e: Exception) {
                    Log.w(TAG, "stop failed: ${e.message}")
                }
                restartCount++
                pingFailures = 0
                lastRestartAt = now
            }

            Log.i(TAG, "starting backend (reason=$reason, port=$apiPort)")
            val fresh = Backend(applicationContext)
            fresh.attachActivity(this)
            fresh.run()
            sharedBackend = fresh
            backendStartedAt = SystemClock.elapsedRealtime()
        } catch (e: Exception) {
            Log.e(TAG, "ensureBackend($reason) failed: ${e.message}", e)
        } finally {
            backendMutex.unlock()
        }
    }

    override fun onDestroy() {
        watchdogJob?.cancel()
        watchdogJob = null
        scope.cancel()
        methodChannel?.setMethodCallHandler(null)
        super.onDestroy()
    }
}
