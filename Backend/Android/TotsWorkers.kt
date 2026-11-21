// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

package com.lalune.lalune

internal data class TotsWorkers(
    val active: Int,
    val target: Int,
    val providers: Map<String, Int>?,
) {
    companion object {
        val providerKeys = listOf("vk", "jazz", "ya_docs", "mail_docs", "cups", "max")
        private val ansi = Regex("\u001b\\[[0-?]*[ -/]*[@-~]")
        private val counter = Regex(
            """\b(workers|workers_target|workers_(?:vk|jazz|ya_docs|mail_docs|cups|max))=(\d+)\b""",
        )

        fun parse(line: String): TotsWorkers? {
            // Startup messages also contain worker counts, but only this
            // periodic snapshot reports the current healthy data channels.
            if (!line.contains("ToTS status")) return null
            val fields = counter.findAll(line.replace(ansi, "")).mapNotNull {
                val value = it.groupValues[2].toIntOrNull() ?: return@mapNotNull null
                it.groupValues[1] to value
            }.toMap()
            val active = fields["workers"] ?: return null
            val target = fields["workers_target"] ?: return null
            if (target !in 1..256 || active !in 0..target) return null
            val providers = providerKeys.mapNotNull { key ->
                fields["workers_$key"]?.let { key to it }
            }.toMap()
            // A worker can change provider health while the core samples it.
            // Keep its authoritative total without inventing a breakdown.
            return TotsWorkers(active, target, providers.takeIf { counts ->
                counts.keys.containsAll(providerKeys.dropLast(1)) &&
                    counts.values.all { it <= active } && counts.values.sum() == active
            })
        }
    }
}
