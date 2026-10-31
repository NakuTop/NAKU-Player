package com.example.kazumi

import android.content.Context
import android.os.Handler
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.RendererCapabilities
import androidx.media3.exoplayer.mediacodec.MediaCodecInfo
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import androidx.media3.exoplayer.video.MediaCodecVideoRenderer
import androidx.media3.exoplayer.video.VideoRendererEventListener

/** Reject impossible color output before decoding the first frame, including adaptive switches. */
@UnstableApi
internal class NakuTVVideoRenderer(
    context: Context, selector: MediaCodecSelector, fallback: Boolean,
    eventHandler: Handler, listener: VideoRendererEventListener, joiningMs: Long,
) : MediaCodecVideoRenderer(Builder(context).setMediaCodecSelector(selector)
    .setEnableDecoderFallback(fallback).setEventHandler(eventHandler)
    .setEventListener(listener).setAllowedJoiningTimeMs(joiningMs)
    .setMaxDroppedFramesToNotify(50)) {
    private val output = NakuTVCapabilities.display(context)

    private fun safe(format: Format): Boolean = NakuTVColorPolicy.mode(
        format.sampleMimeType, format.codecs, format.colorInfo?.colorTransfer ?: -1,
        format.colorInfo?.colorRange ?: -1, output.known, output.dolbyVision,
        output.hdr10, output.hlg) != NakuTVColorPolicy.UNSUPPORTED

    override fun supportsFormat(selector: MediaCodecSelector, format: Format): Int =
        if (safe(format)) super.supportsFormat(selector, format)
        else RendererCapabilities.create(C.FORMAT_UNSUPPORTED_SUBTYPE)

    override fun getDecoderInfos(selector: MediaCodecSelector, format: Format,
        requiresSecureDecoder: Boolean): List<MediaCodecInfo> =
        if (safe(format)) super.getDecoderInfos(selector, format, requiresSecureDecoder)
        else emptyList()
}
