// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Плитка Quick Settings («шторка»): запускает последний выбранный конфиг и
// отключает активное подключение.
//
// Плитка живёт в том же процессе, что и приложение, но Activity может
// отсутствовать — система создаёт сервис по нажатию, даже если приложение
// было выгружено. Поэтому запуск идёт через тот же backend, что и у UI:
// MainActivity.ensureBackendFromService() поднимает его при необходимости, а
// дальше используется обычный HTTP API на 127.0.0.1. Так плитка и приложение
// никогда не расходятся в состоянии.
//
// Согласие на VPN (VpnService.prepare) выдаётся только через UI: если его ещё
// нет, плитка открывает приложение, а не пытается запустить туннель молча.

package com.lalune.lalune

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.drawable.Icon
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.util.Log
import android.widget.Toast
import java.net.HttpURLConnection
import java.net.URL
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import org.json.JSONObject

class LaLuneTileService : TileService() {

    companion object {
        private const val TAG = "LaLune-Tile"
        private const val API_TIMEOUT_MS = 5_000
        // Подключение включает скачивание ядра и прогрев воркеров, поэтому
        // ответа ждём заметно дольше обычного запроса.
        private const val CONNECT_TIMEOUT_MS = 120_000

        /**
         * Область на весь процесс.
         *
         * Панель Quick Settings закрывается сразу после нажатия, и система
         * может уничтожить этот сервис, пока подключение ещё выполняется.
         * Отменять запрос в этот момент нельзя: backend уже начал работу, а
         * оборванный HTTP-вызов оставил бы плитку в неверном состоянии.
         */
        private val work = CoroutineScope(Dispatchers.IO + SupervisorJob())
    }
    private val main = Handler(Looper.getMainLooper())
    private var statusReceiver: BroadcastReceiver? = null

    // ---------------------------------------------------------------- lifecycle

    override fun onStartListening() {
        super.onStartListening()
        registerStatusReceiver()
        updateTile()
    }

    override fun onStopListening() {
        unregisterStatusReceiver()
        super.onStopListening()
    }

    override fun onDestroy() {
        unregisterStatusReceiver()
        super.onDestroy()
    }

    // -------------------------------------------------------------------- click

    override fun onClick() {
        val connected = LaLuneVpnService.snapshotConnected
        val state = LaLuneVpnService.snapshotState
        Log.i(TAG, "click: connected=$connected state=$state")

        // Пока идёт подключение, повторное нажатие не должно запускать вторую
        // попытку: backend уже занят, а пользователь просто ждёт.
        if (!connected && (state == "connecting" || state == "checking")) {
            updateTile()
            return
        }

        // Показываем реакцию сразу: подключение может занять несколько секунд.
        setTileState(active = !connected, subtitle = if (connected) "Отключение…" else "Подключение…")

        work.launch {
            try {
                if (connected) disconnect() else connect()
            } catch (e: Exception) {
                Log.w(TAG, "click failed: ${e.message}", e)
                toast("LaLune: ${e.message ?: "ошибка"}")
            } finally {
                main.post { updateTile() }
            }
        }
    }

    /** Отключает активное подключение через тот же API, что использует UI. */
    private suspend fun disconnect() {
        val (code, body) = post("/vpn/disconnect", "{}", API_TIMEOUT_MS)
        if (code !in 200..299) {
            Log.w(TAG, "disconnect HTTP $code: $body")
            toast("LaLune: не удалось отключиться")
        }
    }

    /**
     * Подключает последний выбранный конфиг.
     *
     * Пустое тело `/vpn/connect` означает «взять выбранный профиль» — ровно то
     * поведение, которое нужно плитке.
     */
    private suspend fun connect() {
        if (!MainActivity.ensureBackendFromService(applicationContext)) {
            toast("LaLune: сервис не отвечает")
            return
        }

        // Согласие на VPN нельзя выдать из плитки — только через диалог.
        if (VpnService.prepare(this) != null) {
            Log.i(TAG, "VPN consent is missing, opening the app")
            toast("Разрешите VPN в LaLune")
            openApp()
            return
        }

        val (code, body) = post("/vpn/connect", "{}", CONNECT_TIMEOUT_MS)
        if (code in 200..299) {
            Log.i(TAG, "connect accepted: $body")
            return
        }
        // Любая причина отказа (нет профиля, не скачалось ядро, система
        // запретила foreground-сервис) разбирается только в UI: показываем
        // текст и открываем приложение.
        Log.w(TAG, "connect failed HTTP $code: $body")
        toast("LaLune: ${errorMessage(body)}")
        openApp()
    }

    // --------------------------------------------------------------------- tile

    private fun updateTile() {
        val state = LaLuneVpnService.snapshotState
        val connected = LaLuneVpnService.snapshotConnected
        val busy = state == "connecting" || state == "checking"
        setTileState(
            active = connected || busy,
            subtitle = when {
                connected && LaLuneVpnService.snapshotTunnelSleeping -> "Туннель спит"
                connected -> "Подключено"
                busy -> "Подключение…"
                state == "error" -> "Ошибка"
                else -> "Отключено"
            },
        )
    }

    private fun setTileState(active: Boolean, subtitle: String) {
        main.post {
            val tile = qsTile ?: return@post
            tile.state = if (active) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
            tile.label = "LaLune"
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                tile.subtitle = subtitle
            }
            tile.icon = Icon.createWithResource(this, R.drawable.ic_lalune_tile)
            tile.updateTile()
        }
    }

    // ---------------------------------------------------------------- broadcast

    /** Обновляет плитку, пока панель открыта: состояние меняет VpnService. */
    private fun registerStatusReceiver() {
        if (statusReceiver != null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                updateTile()
            }
        }
        statusReceiver = receiver
        val filter = IntentFilter(LaLuneVpnService.ACTION_STATUS)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                registerReceiver(receiver, filter)
            }
        } catch (e: Exception) {
            Log.w(TAG, "registerReceiver failed: ${e.message}")
            statusReceiver = null
        }
    }

    private fun unregisterStatusReceiver() {
        val receiver = statusReceiver ?: return
        statusReceiver = null
        try {
            unregisterReceiver(receiver)
        } catch (_: Exception) {
            // Сервис уже отвязан от контекста — ничего страшного.
        }
    }

    // ------------------------------------------------------------------- helpers

    /** Открывает приложение: нужно для согласия на VPN и выбора профиля. */
    private fun openApp() {
        main.post {
            val intent = Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            }
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    startActivityAndCollapse(
                        PendingIntent.getActivity(
                            this,
                            0,
                            intent,
                            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                        )
                    )
                } else {
                    @Suppress("DEPRECATION")
                    startActivityAndCollapse(intent)
                }
            } catch (e: Exception) {
                Log.w(TAG, "openApp failed: ${e.message}")
            }
        }
    }

    private fun toast(message: String) {
        main.post {
            try {
                Toast.makeText(applicationContext, message, Toast.LENGTH_SHORT).show()
            } catch (_: Exception) {
                // Фоновые ограничения могут запретить toast — не критично.
            }
        }
    }

    /** Достаёт текст ошибки из ответа backend (`{"error": "..."}`). */
    private fun errorMessage(body: String): String {
        return try {
            JSONObject(body).optString("error", "").ifBlank { "ошибка" }
        } catch (_: Exception) {
            "ошибка"
        }
    }

    /** POST к локальному API backend. Возвращает код и тело ответа. */
    private fun post(path: String, payload: String, timeoutMs: Int): Pair<Int, String> {
        val port = Backend.portFor(packageName)
        var conn: HttpURLConnection? = null
        return try {
            conn = URL("http://127.0.0.1:$port$path").openConnection() as HttpURLConnection
            conn.connectTimeout = API_TIMEOUT_MS
            conn.readTimeout = timeoutMs
            conn.requestMethod = "POST"
            conn.doOutput = true
            conn.setRequestProperty("Content-Type", "application/json")
            conn.outputStream.use { it.write(payload.toByteArray()) }
            val code = conn.responseCode
            val stream = if (code in 200..299) conn.inputStream else conn.errorStream
            val body = stream?.bufferedReader()?.use { it.readText() } ?: ""
            code to body
        } catch (e: Exception) {
            Log.w(TAG, "POST $path failed: ${e.message}")
            -1 to ""
        } finally {
            try { conn?.disconnect() } catch (_: Exception) {}
        }
    }
}
