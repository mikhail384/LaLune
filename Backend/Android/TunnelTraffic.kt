// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

package com.lalune.lalune

internal data class TunnelBytes(val rx: Long, val tx: Long)
internal data class TunnelTrafficSample(val bytes: TunnelBytes, val atMs: Long)

/** Share one rate per pair of counter samples across independently polled API endpoints. */
internal class TrafficRates {
    private var session = ""
    private var previous: TunnelTrafficSample? = null
    private var rates: TunnelBytes? = null

    fun sample(sessionId: String, current: TunnelTrafficSample?): TunnelBytes? {
        if (current == null || sessionId.isEmpty()) {
            session = ""
            previous = null
            rates = null
            return null
        }
        val last = previous
        if (sessionId != session || last == null ||
            current.bytes.rx < last.bytes.rx || current.bytes.tx < last.bytes.tx) {
            session = sessionId
            previous = current
            rates = null
        } else {
            val elapsed = current.atMs - last.atMs
            if (elapsed >= 1_000) {
                rates = TunnelBytes(
                    ((current.bytes.rx - last.bytes.rx) * 1_000.0 / elapsed).toLong(),
                    ((current.bytes.tx - last.bytes.tx) * 1_000.0 / elapsed).toLong(),
                )
                previous = current
            }
        }
        return rates
    }
}
