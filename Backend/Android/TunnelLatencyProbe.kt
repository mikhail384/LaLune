// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
package com.lalune.lalune

import java.security.SecureRandom
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/** ICMP echo carried by the existing tunnel bridge, independent of app UID routing. */
internal class TunnelLatencyProbe {
    private val target = byteArrayOf(1, 1, 1, 1)
    private val random = SecureRandom()
    @Volatile private var pending: Probe? = null

    private class Probe(val source: ByteArray, val token: ByteArray, val sentAt: Long) {
        private val completion = AtomicReference<Long?>(null)
        val done = CountDownLatch(1)

        fun finish(receivedAt: Long) {
            if (completion.compareAndSet(null, receivedAt)) done.countDown()
        }

        fun latencyMs(): Long? = completion.get()?.takeUnless { it == CANCELLED }
            ?.let { ((it - sentAt) / 1_000_000).coerceAtLeast(1) }
    }

    private companion object {
        const val CANCELLED = Long.MIN_VALUE
    }

    /** Detaching the bridge invalidates an in-flight probe without waiting for timeout. */
    fun cancel() {
        pending?.finish(CANCELLED)
    }

    @Synchronized
    fun measure(source: String, send: (ByteArray) -> Unit): Long? {
        val parts = source.substringBefore('/').split('.')
        if (parts.size != 4) return null
        val address = ByteArray(4)
        for ((index, part) in parts.withIndex()) {
            val number = part.toIntOrNull()?.takeIf { it in 0..255 } ?: return null
            address[index] = number.toByte()
        }
        val token = ByteArray(12).also { random.nextBytes(it) }
        val request = ByteArray(36)
        request[0] = 0x45 // IPv4, 20-byte header
        request[3] = request.size.toByte()
        request[6] = 0x40 // don't fragment
        request[8] = 64
        request[9] = 1 // ICMP
        address.copyInto(request, 12)
        target.copyInto(request, 16)
        request[20] = 8 // echo request; code and checksum initially zero
        token.copyInto(request, 24) // identifier, sequence number, payload
        writeChecksum(request, 10, checksum(request, 0, 20))
        writeChecksum(request, 22, checksum(request, 20, request.size))
        val probe = Probe(address, token, System.nanoTime())
        pending = probe
        return try {
            send(request)
            if (probe.done.await(5, TimeUnit.SECONDS)) probe.latencyMs() else null
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
            null
        } catch (_: Exception) {
            null
        } finally {
            pending = null
        }
    }

    /** Consume only a validated reply to the current synthetic request. */
    fun consume(packet: ByteArray, length: Int): Boolean {
        val probe = pending ?: return false
        if (length < 36 || length > packet.size || unsigned(packet[0]) ushr 4 != 4 || packet[9] != 1.toByte()) return false
        val headerLength = (unsigned(packet[0]) and 15) * 4
        val totalLength = (unsigned(packet[2]) shl 8) or unsigned(packet[3])
        if (headerLength < 20 || totalLength != headerLength + 16 || totalLength > length) return false
        if (unsigned(packet[6]) and 0x3f != 0 || packet[7] != 0.toByte()) return false
        if (packet[headerLength] != 0.toByte() || packet[headerLength + 1] != 0.toByte()) return false
        if (!matches(packet, 12, target) || !matches(packet, 16, probe.source) ||
            !matches(packet, headerLength + 4, probe.token) || checksum(packet, headerLength, totalLength) != 0) return false
        probe.finish(System.nanoTime())
        return true
    }

    private fun matches(packet: ByteArray, offset: Int, expected: ByteArray): Boolean =
        expected.indices.all { packet[offset + it] == expected[it] }

    private fun unsigned(byte: Byte): Int = byte.toInt() and 255

    private fun checksum(packet: ByteArray, start: Int, end: Int): Int {
        var sum = 0
        for (index in start until end step 2) {
            sum += unsigned(packet[index]) shl 8
            if (index + 1 < end) sum += unsigned(packet[index + 1])
        }
        while (sum ushr 16 != 0) sum = (sum and 65535) + (sum ushr 16)
        return sum.inv() and 65535
    }

    private fun writeChecksum(packet: ByteArray, offset: Int, checksum: Int) {
        packet[offset] = (checksum ushr 8).toByte()
        packet[offset + 1] = checksum.toByte()
    }
}
