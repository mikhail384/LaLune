// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Мост к бинарнику `csqtt-link`, запускаемому через ProcessBuilder.
//
// Бинарник лежит в `nativeLibraryDir/libcsqtt-link.so`
// (имя `.so` обязательно, чтобы Gradle упаковал файл в APK —
// это ELF-бинарник, не shared library; APK-упаковщик требует
// расширение `.so` для файлов из jniLibs).
//
// Запуск: ProcessBuilder(nativePath, "--json", link)
//   — stdout: JSON или human-readable
//   — exit code: 0 = OK, 1 = ошибка парсинга, 2 = usage
//
// Не JNI, не System.loadLibrary — просто ELF subprocess.

package com.lalune.lalune

import android.content.Context
import android.util.Base64
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.net.URLDecoder
import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import java.util.concurrent.TimeUnit

object CsqttLink {
    private const val TAG = "LaLune-CsqttLink"

    @Volatile private var nativePath: String? = null
    @Volatile private var probed = false
    @Volatile private var unavailable = false

    /**
     * Находит путь к `libcsqtt-link.so` в nativeLibraryDir.
     * Возвращает null, если файла нет (старый APK без бинарника).
     */
    fun ensureAvailable(context: Context): String? {
        if (probed) {
            return if (unavailable) null else nativePath
        }
        probed = true

        val candidates = listOf(
            "libcsqtt-link.so",
            "libcsqtt_link.so",
            "csqtt-link",
            "libcsqtt-link",
        )
        val dir = File(context.applicationInfo.nativeLibraryDir)
        for (name in candidates) {
            val f = File(dir, name)
            if (f.exists() && f.canExecute()) {
                nativePath = f.absolutePath
                Log.i(TAG, "found native binary: ${f.absolutePath} (${f.length()} bytes)")
                return nativePath
            }
        }

        // На всякий случай — поискать в filesDir (на случай, если APK
        // распаковал не туда, или пользователь положил руками).
        val filesDir = File(context.filesDir, "la-lune")
        for (name in candidates) {
            val f = File(filesDir, name)
            if (f.exists() && f.canExecute()) {
                nativePath = f.absolutePath
                Log.i(TAG, "found native binary (filesDir): ${f.absolutePath}")
                return nativePath
            }
        }

        Log.w(TAG, "csqtt-link binary not found in ${dir.absolutePath}")
        unavailable = true
        return null
    }

    /**
     * Парсит ссылку штатным бинарником или встроенным AES-GCM-декодером.
     *
     * Запускает: `<nativePath> --json <link>`
     * Парсит stdout как JSON.
     */
    fun parse(context: Context, link: String): JSONObject? {
        val path = ensureAvailable(context)
        if (path != null) {
            try {
                val result = runNative(path, listOf("--json", link), timeoutMs = 10_000)
                if (result != null && result.exitCode == 0) {
                    val json = JSONObject(result.stdout)
                    if (json.optBoolean("ok", false)) return json
                }
            } catch (e: Exception) {
                Log.w(TAG, "native parse failed; using built-in decoder: ${e.javaClass.simpleName}")
            }
        }
        return parseBuiltin(link)
    }

    /** AES-GCM fallback works on every supported Android ABI without an NDK binary. */
    private fun parseBuiltin(rawLink: String): JSONObject? {
        return try {
            val trimmed = rawLink.trim()
            val link = when {
                trimmed.startsWith("csqttr://", ignoreCase = true) ->
                    "csqtt://" + trimmed.substringAfter("://")
                trimmed.startsWith("csqtt://", ignoreCase = true) ->
                    "csqtt://" + trimmed.substringAfter("://")
                else -> return null
            }
            val body = link.substringAfter("://")
            val plaintext = if (body.startsWith("connect?", ignoreCase = true)) {
                body
            } else {
                decryptPayload(body) ?: return null
            }.trim()

            val query = when {
                plaintext.startsWith("csqtt://connect?", ignoreCase = true) ->
                    plaintext.substringAfter('?')
                plaintext.startsWith("connect?", ignoreCase = true) ->
                    plaintext.substringAfter('?')
                plaintext.startsWith("csqtt://", ignoreCase = true) -> {
                    plaintext.substringAfter("://").removePrefix("connect?").substringAfter('?', "")
                }
                else -> return null
            }
            val params = linkedMapOf<String, String>()
            for (part in query.split('&', ';')) {
                if (part.isBlank()) continue
                val separator = part.indexOf('=')
                if (separator <= 0) continue
                val key = decodeQueryPart(part.substring(0, separator))
                if (key.isEmpty() || params.containsKey(key)) return null
                params[key] = part.substring(separator + 1)
            }

            if (decodeQueryPart(params["v"] ?: "") != "2") return null
            val host = decodeQueryPart(params["host"] ?: "").trim()
            val port = decodeQueryPart(params["peer"] ?: "").toIntOrNull() ?: return null
            if (host.isEmpty() || port !in 1..65535 || host == "0.0.0.0" ||
                host == "127.0.0.1" || host == "::1" || host.equals("localhost", true)
            ) return null

            val password = decodeQueryPart(params["password"] ?: "").trim()
            if (password.any(Char::isWhitespace)) return null
            val hashes = params["hashes"]?.split('+')?.map(::decodeQueryPart) ?: emptyList()
            if (hashes.size > 6 || hashes.any { it.length < 16 || it.any(Char::isWhitespace) } ||
                hashes.distinct().size != hashes.size
            ) return null
            val token = decodeQueryPart(params["token"] ?: "").trim()
            if (token.length > 4096 || token.any(Char::isWhitespace) ||
                (hashes.isNotEmpty() && token.isNotEmpty())
            ) return null

            JSONObject().apply {
                put("ok", true)
                put("host", host)
                put("port", port)
                put("password", password)
                put("hashes", JSONArray(hashes))
                put("vk_access_token", token)
            }
        } catch (e: Exception) {
            Log.w(TAG, "built-in parse failed: ${e.javaClass.simpleName}")
            null
        }
    }

    private fun decryptPayload(payload: String): String? {
        val compact = payload.filterNot(Char::isWhitespace)
        if (compact.isEmpty()) return null
        val standardBase64 = compact.replace('-', '+').replace('_', '/')
        val padded = standardBase64 + "=".repeat((4 - standardBase64.length % 4) % 4)
        val encrypted = try {
            Base64.decode(padded, Base64.DEFAULT)
        } catch (_: IllegalArgumentException) {
            return null
        }
        if (encrypted.size < 28) return null

        val key = MessageDigest.getInstance("SHA-256")
            .digest("csqtt-chiper-key".toByteArray(Charsets.UTF_8))
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.DECRYPT_MODE,
            SecretKeySpec(key, "AES"),
            GCMParameterSpec(128, encrypted, 0, 12),
        )
        return cipher.doFinal(encrypted, 12, encrypted.size - 12).toString(Charsets.UTF_8)
    }

    private fun decodeQueryPart(value: String): String =
        URLDecoder.decode(value.replace("+", "%2B"), "UTF-8")

    data class ProcessResult(
        val exitCode: Int,
        val stdout: String,
        val stderr: String,
    )

    private fun runNative(
        path: String,
        args: List<String>,
        timeoutMs: Long,
    ): ProcessResult? {
        val cmd = mutableListOf(path)
        cmd.addAll(args)

        return try {
            val pb = ProcessBuilder(cmd)
            pb.redirectErrorStream(false)
            val proc = pb.start()

            // Пишем stdin пустым — бинарник читает аргументы, не stdin.
            try { proc.outputStream.close() } catch (_: Exception) {}

            val stdout = StringBuilder()
            val stderr = StringBuilder()

            val tOut = Thread {
                BufferedReader(InputStreamReader(proc.inputStream)).use { r ->
                    var line: String?
                    while (r.readLine().also { line = it } != null) {
                        stdout.append(line).append('\n')
                    }
                }
            }
            val tErr = Thread {
                BufferedReader(InputStreamReader(proc.errorStream)).use { r ->
                    var line: String?
                    while (r.readLine().also { line = it } != null) {
                        stderr.append(line).append('\n')
                    }
                }
            }
            tOut.start()
            tErr.start()

            val finished = proc.waitFor(timeoutMs, TimeUnit.MILLISECONDS)
            if (!finished) {
                proc.destroyForcibly()
                Log.w(TAG, "native process timeout after ${timeoutMs}ms")
                return null
            }

            tOut.join(1000)
            tErr.join(1000)

            ProcessResult(
                exitCode = proc.exitValue(),
                stdout = stdout.toString().trim(),
                stderr = stderr.toString().trim(),
            )
        } catch (e: Exception) {
            Log.w(TAG, "runNative failed: ${e.message}", e)
            null
        }
    }
}
