package com.example.kazumi

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import com.github.junrar.Archive
import com.github.junrar.ArchiveOptions
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.OutputStream
import java.nio.ByteBuffer
import java.nio.charset.Charset
import java.nio.charset.CodingErrorAction
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

/** RAR subtitle data never becomes an archive-controlled filesystem path. */
internal object NakuSubtitleArchive {
    private const val LIMIT = 8 * 1024 * 1024
    private const val MAX_ENTRIES = 1000
    private val main = Handler(Looper.getMainLooper())
    private val worker = ThreadPoolExecutor(1, 1, 30, TimeUnit.SECONDS,
        ArrayBlockingQueue<Runnable>(2)).apply { allowCoreThreadTimeOut(true) }
    private val extension = Regex("\\.(srt|ass|ssa|vtt)$", RegexOption.IGNORE_CASE)

    private fun safeName(name: String): Boolean = name.isNotEmpty() && name.length <= 1024 &&
        !name.startsWith("/") && !name.startsWith("\\") && !name.contains("..") &&
        !name.contains(':') && !name.contains('\u0000') && extension.containsMatchIn(name)

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, "naku/subtitle_archive").setMethodCallHandler { call, result ->
            if (call.method != "list" && call.method != "extract" && call.method != "decodeChinese") {
                result.notImplemented(); return@setMethodCallHandler
            }
            val bytes = call.argument<ByteArray>("bytes")
            val entry = call.argument<String>("entry")
            if (bytes == null || bytes.isEmpty() || bytes.size > LIMIT ||
                call.method == "extract" && (entry == null || !safeName(entry))) {
                result.error("INVALID_ARCHIVE", "字幕包或文件名无效", null)
                return@setMethodCallHandler
            }
            try {
                worker.execute {
                    try {
                        val deadline = SystemClock.elapsedRealtime() + 20000
                        if (call.method == "decodeChinese") {
                            val decoded = Charset.forName("GB18030").newDecoder()
                                .onMalformedInput(CodingErrorAction.REPORT)
                                .onUnmappableCharacter(CodingErrorAction.REPORT)
                                .decode(ByteBuffer.wrap(bytes)).toString()
                            main.post { result.success(decoded) }
                            return@execute
                        }
                        val options = ArchiveOptions.builder().maxDictionarySize(32L * 1024 * 1024).build()
                        val answer: Any = Archive(ByteArrayInputStream(bytes), options).use { archive ->
                            require(!archive.isEncrypted) { "加密字幕包暂不可读取" }
                            val headers = archive.fileHeaders
                            require(headers.size <= MAX_ENTRIES) { "字幕包文件数量过多" }
                            var total = 0L
                            headers.forEach {
                                require(it.fullUnpackSize >= 0) { "字幕包文件大小无效" }
                                total += it.fullUnpackSize
                                require(total <= 64L * 1024 * 1024) { "字幕包解压总量过大" }
                            }
                            if (call.method == "list") {
                                headers.filter { !it.isDirectory && !it.isEncrypted &&
                                    it.fullUnpackSize in 1..LIMIT.toLong() && safeName(it.fileName) }
                                    .map { it.fileName }
                            } else {
                                val header = headers.singleOrNull { it.fileName == entry }
                                    ?: throw IllegalArgumentException("未找到唯一的字幕文件")
                                require(!header.isDirectory && !header.isEncrypted &&
                                    header.fullUnpackSize in 1..LIMIT.toLong()) { "字幕文件过大或加密" }
                                val output = LimitedOutput(LIMIT, deadline)
                                archive.extractFile(header, output)
                                output.bytes().also {
                                    require(it.isNotEmpty() && it.size.toLong() == header.fullUnpackSize) { "字幕包文件大小不一致" }
                                }
                            }
                        }
                        main.post { result.success(answer) }
                    } catch (_: Exception) {
                        // Do not log archive filenames or user media metadata.
                        main.post { result.error("INVALID_ARCHIVE", "字幕包无法读取或超出限制", null) }
                    }
                }
            } catch (_: java.util.concurrent.RejectedExecutionException) {
                result.error("BUSY", "字幕包正在读取，请稍后重试", null)
            }
        }
    }

    private class LimitedOutput(private val limit: Int, private val deadline: Long) : OutputStream() {
        private val output = ByteArrayOutputStream()
        private fun check(count: Int) {
            require(count >= 0 && output.size().toLong() + count <= limit) { "字幕文件过大" }
            require(SystemClock.elapsedRealtime() <= deadline) { "字幕包读取超时" }
        }
        override fun write(value: Int) { check(1); output.write(value) }
        override fun write(bytes: ByteArray, offset: Int, length: Int) { check(length); output.write(bytes, offset, length) }
        fun bytes(): ByteArray = output.toByteArray()
    }
}
