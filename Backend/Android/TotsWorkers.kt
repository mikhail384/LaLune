// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

package com.lalune.lalune

internal data class TotsWorkers(
    val active: Int,
    val target: Int,
    val providers: Map<String, Int>?,
    val providerTargets: Map<String, Int>?,
    val tunnelRttMs: Int?,
    val bytes: TunnelBytes?,
) {
    companion object {
        private val providerKeys = listOf("vk", "jazz", "ya_docs", "mail_docs", "cups", "max")
        private val ansi = Regex("\u001b\\[[0-?]*[ -/]*[@-~]")
        private val counter = Regex(
            """\b(rtt_p50_ms|tun_(?:rx|tx)_(?:bytes|mb)|workers(?:_target|_(?:vk|jazz|ya_docs|mail_docs|cups|max)(?:_target)?)?)=(\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)(?=\s|$)""",
        )

        fun parse(line: String): TotsWorkers? {
            if (!line.contains("ToTS status")) return null
            val fields = counter.findAll(line.replace(ansi, ""))
                .associate { it.groupValues[1] to it.groupValues[2] }
            val active = fields["workers"]?.toIntOrNull() ?: return null
            val target = fields["workers_target"]?.toIntOrNull() ?: return null
            if (target !in 1..256 || active !in 0..target) return null

            fun counts(suffix: String, total: Int): Map<String, Int>? {
                val values = providerKeys.mapNotNull { key ->
                    fields["workers_$key$suffix"]?.toIntOrNull()?.let { key to it }
                }.toMap()
                return values.takeIf {
                    it.keys.containsAll(providerKeys.dropLast(1)) &&
                        it.values.all { value -> value in 0..total } && it.values.sum() == total
                }
            }

            fun bytes(unit: String, parse: (String) -> Long?): TunnelBytes? {
                val rx = fields["tun_rx_$unit"]?.let(parse) ?: return null
                val tx = fields["tun_tx_$unit"]?.let(parse) ?: return null
                return TunnelBytes(rx, tx)
            }

            // Earlier ToTS cores emitted the same integer byte counts as MiB.
            val totalBytes = bytes("bytes", String::toLongOrNull) ?: bytes("mb") {
                val value = it.toDoubleOrNull()?.times(1_048_576.0)
                value?.takeIf { count -> count.isFinite() && count >= 0 && count < Long.MAX_VALUE.toDouble() }
                    ?.let { count -> kotlin.math.round(count).toLong() }
            }
            return TotsWorkers(
                active,
                target,
                counts("", active),
                counts("_target", target),
                fields["rtt_p50_ms"]?.toIntOrNull()?.takeIf { active > 0 && it in 1..60_000 },
                totalBytes,
            )
        }
    }
}
