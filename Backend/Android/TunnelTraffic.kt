// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

package com.lalune.lalune

import android.net.TrafficStats
import android.os.Build
import java.io.File
import java.net.InetAddress
import java.net.NetworkInterface

internal data class TunnelBytes(val rx: Long, val tx: Long)

/** ToTS owns the TUN descriptor, so it does not traverse the Kotlin UDP bridge. */
internal class NativeTunTraffic private constructor(private val name: String) {
    private var last: TunnelBytes? = null
    private var closed = false

    @Synchronized
    fun read(): TunnelBytes? {
        if (!closed) {
            val current = readInterface()
            if (current != null) last = current
        }
        return last
    }

    @Synchronized
    fun finish() {
        read()
        closed = true
    }

    private fun readInterface(): TunnelBytes? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try {
                val rx = TrafficStats.getRxBytes(name)
                val tx = TrafficStats.getTxBytes(name)
                if (rx >= 0 && tx >= 0) return TunnelBytes(rx, tx)
            } catch (_: SecurityException) {
                // Some builds restrict interface statistics for apps.
            }
        }
        try {
            val stats = File("/sys/class/net/$name/statistics")
            return TunnelBytes(
                File(stats, "rx_bytes").readText().trim().toLong(),
                File(stats, "tx_bytes").readText().trim().toLong(),
            )
        } catch (_: Exception) {
            return null
        }
    }

    companion object {
        fun forAddress(address: String): NativeTunTraffic? = try {
            val name = NetworkInterface.getByInetAddress(InetAddress.getByName(address))?.name
            // Only the interface we just established; never fall back to device-wide traffic.
            if (name != null && name.matches(Regex("tun[0-9]+"))) NativeTunTraffic(name)
            else null
        } catch (_: Exception) {
            null
        }
    }
}

/** Share a sampling window between independently polled API endpoints. */
internal class TrafficRates {
    private var session = ""
    private var sampledAt = 0L
    private var sampled = TunnelBytes(0, 0)
    private var rates = TunnelBytes(0, 0)

    fun sample(sessionId: String, nowMs: Long, bytes: TunnelBytes): TunnelBytes {
        if (sessionId.isEmpty() || sessionId != session ||
            bytes.rx < sampled.rx || bytes.tx < sampled.tx) {
            session = sessionId
            sampledAt = nowMs
            sampled = bytes
            rates = TunnelBytes(0, 0)
        } else {
            val elapsed = nowMs - sampledAt
            if (elapsed >= 1000) {
                rates = TunnelBytes(
                    (bytes.rx - sampled.rx) * 1000 / elapsed,
                    (bytes.tx - sampled.tx) * 1000 / elapsed,
                )
                sampledAt = nowMs
                sampled = bytes
            }
        }
        return rates
    }
}
