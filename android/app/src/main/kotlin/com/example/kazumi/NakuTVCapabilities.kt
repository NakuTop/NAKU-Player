package com.example.kazumi

import android.content.Context
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.net.ConnectivityManager
import android.net.Uri
import android.os.Build

/** Read-only network identity and actual hardware decoder size support. */
internal object NakuTVCapabilities {
    @Volatile private var decoderSnapshot: List<Map<String, Any>>? = null

    fun read(context: Context): Map<String, Any?> {
        val connectivity = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val proxy = connectivity.defaultProxy
        val pac = proxy?.pacFileUrl
        return mapOf(
            "key" to "${connectivity.activeNetwork ?: "offline"}|${proxy?.host ?: ""}|${proxy?.port ?: -1}|${pac ?: ""}|${proxy?.exclusionList?.joinToString(",") ?: ""}",
            "proxyHost" to proxy?.host,
            "proxyPort" to proxy?.port,
            "proxyExclusionList" to (proxy?.exclusionList?.toList() ?: emptyList<String>()),
            "hasPac" to (pac != null && pac != Uri.EMPTY && pac.toString().isNotEmpty()),
            "decoderCapabilities" to (decoderSnapshot ?: readDecoders().also { decoderSnapshot = it })
        )
    }

    private fun readDecoders(): List<Map<String, Any>> {
        val sizes = listOf(7680 to 4320, 3840 to 2160, 2560 to 1440, 1920 to 1080, 1280 to 720, 854 to 480)
        val mimes = mapOf("AVC" to "video/avc", "HEVC" to "video/hevc", "AV1" to "video/av01", "VP9" to "video/x-vnd.on2.vp9")
        val codecs = try { MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.toList() } catch (_: Exception) { emptyList() }
        return mimes.mapNotNull { (name, mime) ->
            val maximum = codecs.asSequence().filter { !it.isEncoder && hardware(it) && it.supportedTypes.any { type -> type.equals(mime, true) } }
                .mapNotNull { info ->
                    try {
                        val capabilities = info.getCapabilitiesForType(mime).videoCapabilities
                        sizes.firstOrNull { (width, height) -> capabilities.isSizeSupported(width, height) }
                    } catch (_: Exception) { null }
                }.maxByOrNull { it.first.toLong() * it.second }
            maximum?.let { mapOf("codec" to name, "maxWidth" to it.first, "maxHeight" to it.second) }
        }
    }

    private fun hardware(info: MediaCodecInfo): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) info.isHardwareAccelerated
        else !info.name.startsWith("OMX.google.") && !info.name.startsWith("c2.android.")
}
