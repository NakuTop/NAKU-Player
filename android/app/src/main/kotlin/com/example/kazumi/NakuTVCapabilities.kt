package com.example.kazumi

import android.content.Context
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.AudioManager
import android.hardware.display.DisplayManager
import android.net.ConnectivityManager
import android.net.Uri
import android.os.Build
import android.view.Display

/** Read-only network identity and actual hardware decoder size support. */
internal object NakuTVCapabilities {
    @Volatile private var decoderSnapshot: List<Map<String, Any>>? = null

    data class Output(val known: Boolean, val dolbyVision: Boolean, val hdr10: Boolean, val hlg: Boolean)
    fun display(context: Context): Output {
        val legacy = NakuTVColorPolicy.legacyHuawei(Build.MODEL)
        val panel = (context.getSystemService(Context.DISPLAY_SERVICE) as? DisplayManager)
            ?.getDisplay(Display.DEFAULT_DISPLAY)
        val types = if (Build.VERSION.SDK_INT >= 24) {
            try { panel?.hdrCapabilities?.supportedHdrTypes?.toSet() ?: emptySet() }
            catch (_: Exception) { emptySet() }
        } else emptySet()
        // HEGE-570 is the 2019 V75: HDR10/HLG, no Dolby Vision panel.
        // HarmonyOS may expose a DV decoder independently of that panel.
        return Output(legacy || (Build.VERSION.SDK_INT >= 24 && panel != null),
            !legacy && 1 in types, legacy || 2 in types || 4 in types, legacy || 3 in types)
    }

    fun read(context: Context): Map<String, Any?> {
        val connectivity = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val proxy = connectivity.defaultProxy
        val pac = proxy?.pacFileUrl
        val output = display(context)
        val audio = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
        return mapOf(
            "key" to "${connectivity.activeNetwork ?: "offline"}|${proxy?.host ?: ""}|${proxy?.port ?: -1}|${pac ?: ""}|${proxy?.exclusionList?.joinToString(",") ?: ""}",
            "proxyHost" to proxy?.host,
            "proxyPort" to proxy?.port,
            "proxyExclusionList" to (proxy?.exclusionList?.toList() ?: emptyList<String>()),
            "hasPac" to (pac != null && pac != Uri.EMPTY && pac.toString().isNotEmpty()),
            "displayCapabilities" to mapOf("known" to output.known,
                "dolbyVision" to output.dolbyVision, "hdr10" to output.hdr10, "hlg" to output.hlg),
            "audioOutputs" to (audio?.getDevices(AudioManager.GET_DEVICES_OUTPUTS)?.map {
                mapOf("type" to it.type, "encodings" to it.encodings.toList(),
                    "channelCounts" to it.channelCounts.toList())
            } ?: emptyList()),
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
                        val capabilities = info.getCapabilitiesForType(mime).videoCapabilities ?: return@mapNotNull null
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
