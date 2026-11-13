// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Scrubs secrets (passwords, tokens, full configuration links) from any text
// before it reaches logcat, the in-app log list, /logs/export, SSE or Lua.

package com.lalune.lalune

import java.security.MessageDigest

object LogRedactor {
    private val linkRe = Regex(
        "(?i)\\b(csqttr?|paperflux|openflux|vless|vmess|trojan|ss|ssr|hysteria2?|tuic|wireguard)://[^\\s\"'<>]+"
    )
    private val kvRe = Regex(
        "(?i)\\b(access_token|refresh_token|id_token|token|password|passwd|pwd|secret|hashes|hash|profile[_-]?token|relay[_-]?token|" +
            "relay[_-]?session|maxToken|maxUid|device[_-]?id|api[_-]?key|authorization|cookie)\\b(\\s*[=:]\\s*)(\"?)[^\\s&\"',;]+"
    )
    private val flagRe = Regex(
        "(?i)(--?(?:password|vk|token|profile-token|relay-token|relay-session|maxToken|maxUid|profile-id|device-id|" +
            "url|urls|volga-url|relay-url|hashes))(\\s+|=)(?!-)[^\\s]+"
    )
    private val vkTokenRe = Regex("\\bvk1\\.[A-Za-z0-9._-]{8,}")
    private val bearerRe = Regex("(?i)\\bbearer\\s+[A-Za-z0-9._~+/=-]{8,}")
    private val blobRe = Regex("[A-Za-z0-9_-]{40,}")

    fun redact(text: String): String {
        if (text.isEmpty()) return text
        var s = text
        s = linkRe.replace(s) { m -> "${m.groupValues[1].lowercase()}://<redacted len=${m.value.length}>" }
        s = flagRe.replace(s) { m -> "${m.groupValues[1]}${m.groupValues[2]}<redacted>" }
        s = kvRe.replace(s) { m -> "${m.groupValues[1]}${m.groupValues[2]}${m.groupValues[3]}<redacted>" }
        s = vkTokenRe.replace(s, "vk1.<redacted>")
        s = bearerRe.replace(s, "Bearer <redacted>")
        s = blobRe.replace(s, "<redacted blob>")
        return s
    }

    /** Host:port style values are logged as-is; anything else is reduced to a fingerprint. */
    fun safePeer(peer: String): String {
        if (Regex("^[A-Za-z0-9._\\-\\[\\]:]{1,255}$").matches(peer)) return peer
        val scheme = peer.substringBefore("://", "text")
        return "<$scheme len=${peer.length} sha256=${sha256Hex(peer).take(8)}>"
    }

    /** URL for logging: scheme://host/path only, query and fragment reduced to sizes. */
    fun safeUrl(url: String?): String {
        if (url == null) return "<null>"
        val u = try { java.net.URI(url) } catch (_: Exception) { return "<unparsable len=${url.length}>" }
        val sb = StringBuilder()
        sb.append(u.scheme ?: "?").append("://").append(u.host ?: "").append(u.rawPath ?: "")
        u.rawQuery?.takeIf { it.isNotEmpty() }?.let { sb.append("?<query ").append(it.length).append("b>") }
        u.rawFragment?.takeIf { it.isNotEmpty() }?.let { sb.append("#<fragment ").append(it.length).append("b>") }
        return sb.toString()
    }

    private fun sha256Hex(s: String): String =
        MessageDigest.getInstance("SHA-256").digest(s.toByteArray()).joinToString("") { "%02x".format(it) }
}
