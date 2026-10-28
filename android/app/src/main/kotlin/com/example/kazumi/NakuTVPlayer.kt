package com.example.kazumi

import android.app.Activity
import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.Tracks
import androidx.media3.common.VideoSize
import androidx.media3.common.text.CueGroup
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.DecoderReuseEvaluation
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import okhttp3.OkHttpClient
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.ProxySelector
import java.net.SocketAddress
import java.net.URI
import java.util.concurrent.TimeUnit

/** Native TV-only output: MediaCodec -> SurfaceView and AudioTrack passthrough.
 * No video pixels pass through Flutter textures or software color filters.
 */
@UnstableApi
class NakuTVPlayer(private val activity: Activity, engine: FlutterEngine) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private val messenger = engine.dartExecutor.binaryMessenger
    private val channel = MethodChannel(messenger, "naku/tv-player")
    private val events = EventChannel(messenger, "naku/tv-player/events")
    private val handler = Handler(Looper.getMainLooper())
    private val sessions = mutableMapOf<Int, Session>()
    private val surfaces = mutableMapOf<Int, MutableSet<TVView>>()
    private var sink: EventChannel.EventSink? = null
    private var disposed = false
    // Direct by default. Public upstreams may explicitly opt into the selected
    // app/system proxy; NAS/loopback and redirect targets always bypass it.
    private val http = OkHttpClient.Builder()
        .proxy(Proxy.NO_PROXY)
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .followRedirects(true)
        .followSslRedirects(true)
        .build()

    init {
        channel.setMethodCallHandler(this)
        events.setStreamHandler(this)
        engine.platformViewsController.registry.registerViewFactory(
            "naku/tv-video", object : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
                override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
                    val id = ((args as? Map<*, *>)?.get("playerId") as? Number)?.toInt() ?: -1
                    return TVView(context, id)
                }
            }
        )
    }

    override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink?) {
        sink = eventSink
        sessions.values.forEach { it.emit(mapOf("tracks" to it.trackRows)) }
    }
    override fun onCancel(arguments: Any?) { sink = null }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<Number>("id")?.toInt()
        if (disposed || id == null) {
            result.error("TV_PLAYER_CLOSED", "电视播放器已关闭", null)
            return
        }
        try {
            if (call.method == "create") {
                sessions.getOrPut(id) { Session(id) }
                surfaces[id]?.forEach { it.attach() }
                result.success(null)
                return
            }
            val session = sessions[id]
            if (session == null) {
                result.error("TV_PLAYER_MISSING", "电视播放器尚未准备好", null)
                return
            }
            when (call.method) {
                "open" -> session.open(call)
                "play" -> session.player.play()
                "pause" -> session.player.pause()
                "stop" -> session.player.stop()
                "seek" -> session.player.seekTo((call.argument<Number>("positionMs")?.toLong() ?: 0L).coerceAtLeast(0))
                "volume" -> session.player.volume = (call.argument<Number>("value")?.toFloat() ?: 1f).coerceIn(0f, 1f)
                "rate" -> session.player.setPlaybackSpeed((call.argument<Number>("value")?.toFloat() ?: 1f).coerceIn(.25f, 3f))
                "track" -> session.selectTrack(call.argument<String>("type") ?: "", call.argument<String>("track") ?: "auto")
                "dispose" -> {
                    surfaces[id]?.forEach { it.view.player = null }
                    sessions.remove(id)?.close()
                }
                else -> { result.notImplemented(); return }
            }
            session.emit()
            result.success(null)
        } catch (_: Exception) {
            // Never forward exception text, media URL, headers or NAS paths.
            result.error("TV_PLAYER_COMMAND", "电视播放器操作失败，请重试", null)
        }
    }

    private class TVProxySelector(private val upstream: Proxy) : ProxySelector() {
        override fun select(uri: URI?): List<Proxy> = listOf(
            if (uri == null || isLocalTarget(uri.host.orEmpty())) Proxy.NO_PROXY else upstream
        )
        override fun connectFailed(uri: URI?, sa: SocketAddress?, ioe: IOException?) {
            // Do not log URLs or credentials and never silently retry direct.
        }
        private fun isLocalTarget(host: String): Boolean {
            if (isLocalHost(host)) return true
            // OkHttp calls ProxySelector from its network worker, not UI. A
            // public-looking NAS hostname may resolve entirely to LAN. Mixed
            // or failed DNS remains on the explicitly selected upstream proxy.
            return try {
                val addresses = InetAddress.getAllByName(host)
                addresses.isNotEmpty() && addresses.all {
                    it.isLoopbackAddress || it.isLinkLocalAddress ||
                        it.isSiteLocalAddress || isLocalHost(it.hostAddress.orEmpty())
                }
            } catch (_: Exception) { false }
        }
        private fun isLocalHost(raw: String): Boolean {
            var host = raw.lowercase().removePrefix("[").removeSuffix("]")
            if (host.startsWith("::ffff:")) host = host.substring(7)
            if (host.isBlank() || (!host.contains('.') && !host.contains(':')) ||
                host == "localhost" || host.endsWith(".localhost") ||
                host.endsWith(".local") || host.endsWith(".lan") ||
                host == "::1" || host == "::" ||
                (host.contains(':') && (host.startsWith("fc") || host.startsWith("fd") ||
                    Regex("^fe[89ab]").containsMatchIn(host)))) return true
            val bytes = host.split('.').map { it.toIntOrNull() }
            if (bytes.size != 4 || bytes.any { it == null || it !in 0..255 }) return false
            val first = bytes[0]!!
            val second = bytes[1]!!
            return first == 0 || first == 10 || first == 127 ||
                (first == 169 && second == 254) ||
                (first == 172 && second in 16..31) ||
                (first == 192 && second == 168) ||
                (first == 100 && second in 64..127)
        }
    }

    private inner class Session(val id: Int) : Player.Listener, AnalyticsListener {
        var firstFrame = false
        var closed = false
        private var droppedFrames = 0
        var trackRows: List<Map<String, Any?>> = emptyList()
        private val rendererFactory = DefaultRenderersFactory(activity)
            .setEnableDecoderFallback(true)
            .setMediaCodecSelector { mimeType, secure, tunneling ->
                val decoders = MediaCodecSelector.DEFAULT.getDecoderInfos(mimeType, secure, tunneling)
                // Older TV CPUs cannot replace video silicon without stalls.
                // Reject unsupported software video so the page can choose a
                // compatible NAS profile/source; audio PCM fallback stays valid.
                if (mimeType.startsWith("video/")) {
                    decoders.filter { it.hardwareAccelerated && !it.softwareOnly }
                } else decoders
            }
        private val loadControl = DefaultLoadControl.Builder()
            .setBufferDurationsMs(15_000, 50_000, 1_000, 2_500)
            .setTargetBufferBytes(64 * 1024 * 1024)
            .setPrioritizeTimeOverSizeThresholds(false)
            .build()
        val player: ExoPlayer = ExoPlayer.Builder(activity, rendererFactory)
            .setLoadControl(loadControl)
            .build().apply {
                setAudioAttributes(AudioAttributes.DEFAULT, true)
                setHandleAudioBecomingNoisy(true)
                setWakeMode(C.WAKE_MODE_NETWORK)
                setVideoChangeFrameRateStrategy(C.VIDEO_CHANGE_FRAME_RATE_STRATEGY_ONLY_IF_SEAMLESS)
                addListener(this@Session)
                addAnalyticsListener(this@Session)
            }
        private val ticker = object : Runnable {
            override fun run() {
                if (closed) return
                emit()
                handler.postDelayed(this, if (player.isPlaying) 250L else 1000L)
            }
        }
        init { handler.post(ticker) }

        fun open(call: MethodCall) {
            val url = call.argument<String>("url") ?: throw IllegalArgumentException()
            val uri = Uri.parse(url)
            require(uri.scheme in setOf("http", "https", "file", "content"))
            val headers = call.argument<Map<String, String>>("headers") ?: emptyMap()
            val proxyArgs = call.argument<Map<String, Any?>>("proxy")
            val client = if (proxyArgs == null) http else {
                val scheme = proxyArgs["scheme"] as? String ?: throw IllegalArgumentException()
                val host = proxyArgs["host"] as? String ?: throw IllegalArgumentException()
                val port = (proxyArgs["port"] as? Number)?.toInt() ?: 0
                require(scheme in setOf("http", "socks", "socks5"))
                require(host.isNotBlank() && host.length <= 253 && !host.any { it.isWhitespace() || it in "/@" } && port in 1..65535)
                val type = if (scheme == "http") Proxy.Type.HTTP else Proxy.Type.SOCKS
                val proxy = Proxy(type, InetSocketAddress.createUnresolved(host, port))
                http.newBuilder().proxy(null).proxySelector(TVProxySelector(proxy)).build()
            }
            val dataSource = DefaultDataSource.Factory(activity,
                OkHttpDataSource.Factory(client).setDefaultRequestProperties(headers))
            val factory = DefaultMediaSourceFactory(dataSource)
            firstFrame = false
            player.stop()
            player.clearMediaItems()
            val item = MediaItem.Builder().setUri(uri)
            call.argument<String>("mimeType")?.let { item.setMimeType(it) }
            player.setMediaSource(factory.createMediaSource(item.build()))
            player.seekTo((call.argument<Number>("positionMs")?.toLong() ?: 0L).coerceAtLeast(0))
            player.playWhenReady = call.argument<Boolean>("play") ?: true
            player.prepare()
        }

        fun emit(extra: Map<String, Any?> = emptyMap()) {
            if (closed || disposed) return
            val size = player.videoSize
            sink?.success(mapOf(
                "id" to id,
                "positionMs" to player.currentPosition.coerceAtLeast(0L),
                "durationMs" to player.duration.coerceAtLeast(0L),
                "bufferMs" to player.bufferedPosition.coerceAtLeast(0L),
                // Requested play remains true during buffering, matching media-kit.
                "playing" to (player.playWhenReady && player.playbackState != Player.STATE_ENDED),
                "buffering" to (player.playbackState == Player.STATE_BUFFERING),
                "completed" to (player.playbackState == Player.STATE_ENDED),
                "firstFrame" to firstFrame,
                "width" to size.width, "height" to size.height
            ) + extra)
        }

        private fun fact(value: String): String = value.replace(Regex("[^A-Za-z0-9_./+\\-]"), "_").take(128)
        override fun onVideoDecoderInitialized(eventTime: AnalyticsListener.EventTime,
            decoderName: String, initializedTimestampMs: Long, initializationDurationMs: Long) {
            val name = fact(decoderName)
            Log.i("NAKU-TV", "video-decoder=$name output=SurfaceView initMs=$initializationDurationMs")
            emit(mapOf("videoDecoder" to name))
        }
        override fun onVideoInputFormatChanged(eventTime: AnalyticsListener.EventTime,
            format: Format, decoderReuseEvaluation: DecoderReuseEvaluation?) {
            val color = format.colorInfo
            Log.i("NAKU-TV", "video-format=${fact(format.sampleMimeType.orEmpty())} size=${format.width}x${format.height} colorSpace=${color?.colorSpace} colorRange=${color?.colorRange} transfer=${color?.colorTransfer}")
        }
        override fun onDroppedVideoFrames(eventTime: AnalyticsListener.EventTime,
            droppedFrames: Int, elapsedMs: Long) {
            this.droppedFrames += droppedFrames
            Log.i("NAKU-TV", "droppedFrames=$droppedFrames elapsedMs=$elapsedMs total=${this.droppedFrames}")
            emit(mapOf("droppedFrames" to this.droppedFrames))
        }
        override fun onAudioTrackInitialized(eventTime: AnalyticsListener.EventTime,
            audioTrackConfig: AudioSink.AudioTrackConfig) {
            Log.i("NAKU-TV", "audio-encoding=${audioTrackConfig.encoding} sampleRate=${audioTrackConfig.sampleRate} channels=${audioTrackConfig.channelConfig} offload=${audioTrackConfig.offload} tunneling=${audioTrackConfig.tunneling}")
            emit(mapOf("audioEncoding" to audioTrackConfig.encoding))
        }
        override fun onPlaybackStateChanged(playbackState: Int) { emit() }
        override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) { emit() }
        override fun onVideoSizeChanged(videoSize: VideoSize) { emit() }
        override fun onRenderedFirstFrame() { firstFrame = true; emit() }
        override fun onPlayerError(error: PlaybackException) {
            emit(mapOf("error" to "Android TV 播放错误（${error.errorCode}）"))
        }
        override fun onCues(cueGroup: CueGroup) {
            emit(mapOf("cues" to cueGroup.cues.mapNotNull { it.text?.toString() }))
        }
        override fun onTracksChanged(tracks: Tracks) {
            val rows = mutableListOf<Map<String, Any?>>()
            tracks.groups.forEachIndexed { groupIndex, group ->
                val type = when (group.type) {
                    C.TRACK_TYPE_VIDEO -> "video"
                    C.TRACK_TYPE_AUDIO -> "audio"
                    C.TRACK_TYPE_TEXT -> "subtitle"
                    else -> return@forEachIndexed
                }
                for (i in 0 until group.length) {
                    val format = group.getTrackFormat(i)
                    rows.add(mapOf("id" to "$groupIndex:$i", "type" to type,
                        "label" to format.label, "language" to format.language,
                        "codec" to format.sampleMimeType, "width" to format.width,
                        "height" to format.height, "channels" to format.channelCount,
                        "selected" to group.isTrackSelected(i)))
                }
            }
            trackRows = rows
            emit(mapOf("tracks" to rows))
        }
        fun selectTrack(type: String, id: String) {
            val trackType = when(type) {
                "video" -> C.TRACK_TYPE_VIDEO
                "audio" -> C.TRACK_TYPE_AUDIO
                else -> C.TRACK_TYPE_TEXT
            }
            val builder = player.trackSelectionParameters.buildUpon()
                .clearOverridesOfType(trackType)
                .setTrackTypeDisabled(trackType, id == "no")
            if (id != "no" && id != "auto") {
                val pair = id.split(':')
                require(pair.size == 2)
                val group = player.currentTracks.groups.getOrNull(pair[0].toInt())
                    ?: throw IllegalArgumentException()
                require(group.type == trackType)
                val index = pair[1].toInt()
                require(index in 0 until group.length)
                builder.setOverrideForType(TrackSelectionOverride(group.mediaTrackGroup, index))
            }
            player.trackSelectionParameters = builder.build()
        }
        fun close() {
            if (closed) return
            closed = true
            handler.removeCallbacks(ticker)
            player.removeListener(this)
            player.removeAnalyticsListener(this)
            player.release()
        }
    }

    private inner class TVView(context: Context, val id: Int) : PlatformView {
        val view = PlayerView(context).apply {
            useController = false
            isFocusable = false
            isFocusableInTouchMode = false
            descendantFocusability = ViewGroup.FOCUS_BLOCK_DESCENDANTS
            resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT
            setKeepContentOnPlayerReset(false)
        }
        init {
            check(view.videoSurfaceView is SurfaceView)
            surfaces.getOrPut(id) { mutableSetOf() }.add(this)
            attach()
        }
        fun attach() { view.player = sessions[id]?.player }
        override fun getView(): View = view
        override fun dispose() {
            view.player = null
            surfaces[id]?.remove(this)
            if (surfaces[id]?.isEmpty() == true) surfaces.remove(id)
        }
    }

    fun dispose() {
        if (disposed) return
        disposed = true
        surfaces.values.flatten().forEach { it.view.player = null }
        surfaces.clear()
        sessions.values.forEach { it.close() }
        sessions.clear()
        sink = null
        channel.setMethodCallHandler(null)
        events.setStreamHandler(null)
        http.dispatcher.cancelAll()
        http.connectionPool.evictAll()
    }
}
