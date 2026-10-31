package com.example.kazumi

import android.app.Activity
import android.app.ActivityManager
import android.app.Application
import android.content.Context
import android.graphics.BitmapFactory
import android.opengl.GLES20
import android.opengl.GLSurfaceView
import android.opengl.GLUtils
import android.opengl.Matrix
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.View
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.nio.ShortBuffer
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10
import kotlin.math.*

/** A bounded GLES2 sphere replaces the WebView/WebGL scene on old televisions.
 * Texture is the exact Home Display NASA Blue Marble equirectangular asset.
 * No browser, controls, interactive particles, landmarks or aircraft models.
 */
class NakuTVEarth(private val activity: Activity, engine: FlutterEngine) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler,
    Application.ActivityLifecycleCallbacks {
    private val handler = Handler(Looper.getMainLooper())
    private val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "naku/tv-earth")
    private val events = EventChannel(engine.dartExecutor.binaryMessenger, "naku/tv-earth/events")
    private val dayTextureAsset = engine.flutterLoaderAsset("assets/images/tv_earth_day_8k.webp")
    private val nightTextureAsset = engine.flutterLoaderAsset("assets/images/tv_earth_night_8k.webp")
    private val cloudTextureAsset = engine.flutterLoaderAsset("assets/images/tv_earth_clouds_2k.jpg")
    private val views = mutableMapOf<Int, EarthView>()
    private var sink: EventChannel.EventSink? = null
    private var foreground = true
    private var disposed = false

    init {
        channel.setMethodCallHandler(this)
        events.setStreamHandler(this)
        activity.application.registerActivityLifecycleCallbacks(this)
        engine.platformViewsController.registry.registerViewFactory("naku/tv-earth",
            object : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
                override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
                    val values = args as? Map<*, *> ?: emptyMap<Any, Any>()
                    val id = (values["id"] as? Number)?.toInt() ?: viewId
                    views.remove(id)?.close()
                    return EarthView(context, id, values).also { views[id] = it }
                }
            })
    }

    // Flutter's asset key is independent of the app's Android package name.
    private fun FlutterEngine.flutterLoaderAsset(path: String): String =
        io.flutter.FlutterInjector.instance().flutterLoader().getLookupKeyForAsset(path)

    override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink?) {
        sink = eventSink
        views.values.forEach { it.replayStatus() }
    }
    override fun onCancel(arguments: Any?) { sink = null }
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<Number>("id")?.toInt()
        if (id == null || disposed) { result.success(null); return }
        when (call.method) {
            "update" -> views[id]?.configure(call.arguments as? Map<*, *> ?: emptyMap<Any, Any>())
            "dispose" -> views.remove(id)?.close()
            else -> { result.notImplemented(); return }
        }
        result.success(null)
    }
    private fun emit(id: Int, values: Map<String, Any>) {
        if (!disposed) sink?.success(mapOf("id" to id) + values)
    }

    private inner class EarthView(context: Context, val id: Int, values: Map<*, *>) : PlatformView {
        private var enabled = values["active"] == true
        private var closed = false
        private var ready = false
        private var rendering = false
        private var failed = false
        private var firstFrame = false
        private var firstFrameFacts = emptyMap<String, Any>()
        private val renderer = EarthRenderer(context, dayTextureAsset, nightTextureAsset, cloudTextureAsset,
            onFrame = { facts -> handler.post {
                if (!closed) {
                    firstFrame = true
                    firstFrameFacts = facts
                    emit(id, mapOf("firstFrame" to true) + facts)
                }
            } },
            onError = { handler.post {
                if (!closed) {
                    failed = true
                    refresh()
                    emit(id, mapOf("error" to true))
                }
            } })
        private val surface: GLSurfaceView = object : GLSurfaceView(context) {
            override fun onAttachedToWindow() {
                super.onAttachedToWindow()
                if (ready) refresh()
            }
            override fun onDetachedFromWindow() {
                handler.removeCallbacks(frame)
                rendering = false
                renderer.animating = false
                super.onDetachedFromWindow()
            }
            override fun onWindowVisibilityChanged(visibility: Int) {
                super.onWindowVisibilityChanged(visibility)
                if (ready) refresh()
            }
            override fun onVisibilityChanged(changedView: View, visibility: Int) {
                super.onVisibilityChanged(changedView, visibility)
                if (ready) refresh()
            }
        }.apply {
            isFocusable = false
            isFocusableInTouchMode = false
            isClickable = false
            isLongClickable = false
            setEGLContextClientVersion(2)
            setEGLConfigChooser(8, 8, 8, 8, 16, 0)
            preserveEGLContextOnPause = false
            setRenderer(renderer)
            renderMode = GLSurfaceView.RENDERMODE_WHEN_DIRTY
        }
        private val frame: Runnable = object : Runnable {
            override fun run() {
                if (!rendering || closed) return
                surface.requestRender()
                // At most 24fps, including on 60/120Hz panels. No busy GL loop.
                handler.postDelayed(this, 42L)
            }
        }
        init {
            renderer.setRoutes(values["routes"])
            // Bound only the old-TV screensaver framebuffer. Video output is
            // a separate native SurfaceView and retains its full HDR resolution.
            val memory = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
            if (memory?.isLowRamDevice == true || (memory?.memoryClass ?: 256) <= 256) {
                surface.addOnLayoutChangeListener { _, left, top, right, bottom, _, _, _, _ ->
                    val width = right - left
                    val height = bottom - top
                    if (width > 0 && height > 0) {
                        val scale = min(1.0, min(1920.0 / width, 1080.0 / height))
                        if (scale < 1.0) surface.holder.setFixedSize((width * scale).roundToInt(), (height * scale).roundToInt())
                        else surface.holder.setSizeFromLayout()
                    }
                }
            }
            ready = true
            surface.onPause()
        }
        fun configure(values: Map<*, *>) {
            if (closed) return
            enabled = values["active"] == true
            renderer.setRoutes(values["routes"])
            refresh()
        }
        fun refreshFromActivity() { refresh() }
        fun replayStatus() {
            if (failed) emit(id, mapOf("error" to true))
            else if (firstFrame) emit(id, mapOf("firstFrame" to true) + firstFrameFacts)
        }
        private fun refresh() {
            if (!ready || closed) return
            val next = enabled && foreground && !failed && surface.isAttachedToWindow && surface.isShown
            if (next == rendering) return
            rendering = next
            renderer.animating = next
            handler.removeCallbacks(frame)
            if (next) {
                surface.onResume()
                handler.post(frame)
            } else surface.onPause()
        }
        override fun getView(): View = surface
        override fun dispose() {
            if (views[id] === this) views.remove(id)
            close()
        }
        fun close() {
            if (closed) return
            closed = true
            handler.removeCallbacks(frame)
            rendering = false
            renderer.animating = false
            surface.onPause() // releases its EGL context and texture allocations
        }
    }

    override fun onActivityResumed(value: Activity) {
        if (value === activity) { foreground = true; views.values.forEach { it.refreshFromActivity() } }
    }
    override fun onActivityPaused(value: Activity) {
        if (value === activity) { foreground = false; views.values.forEach { it.refreshFromActivity() } }
    }
    override fun onActivityCreated(value: Activity, savedInstanceState: Bundle?) {}
    override fun onActivityStarted(value: Activity) {}
    override fun onActivityStopped(value: Activity) {
        if (value === activity) { foreground = false; views.values.forEach { it.refreshFromActivity() } }
    }
    override fun onActivitySaveInstanceState(value: Activity, outState: Bundle) {}
    override fun onActivityDestroyed(value: Activity) { if (value === activity) dispose() }
    fun dispose() {
        if (disposed) return
        disposed = true
        views.values.toList().forEach { it.close() }
        views.clear()
        sink = null
        channel.setMethodCallHandler(null)
        events.setStreamHandler(null)
        activity.application.unregisterActivityLifecycleCallbacks(this)
    }

    private class EarthRenderer(
        private val context: Context,
        private val dayAsset: String,
        private val nightAsset: String,
        private val cloudAsset: String,
        private val onFrame: (Map<String, Any>) -> Unit,
        private val onError: () -> Unit,
    ) : GLSurfaceView.Renderer {
        @Volatile var animating = false
        private data class FlightGeometry(val routes: List<FloatBuffer>, val positions: List<FloatBuffer>)
        @Volatile private var geometry = FlightGeometry(emptyList(), emptyList())
        private var uploadedGeometry: FlightGeometry? = null
        private val routeBuffers = mutableListOf<Pair<Int, Int>>()
        private val positionBuffers = mutableListOf<Int>()
        private val sphereBuffers = IntArray(2)
        private val sphereHandles = IntArray(10)
        private val lineHandles = IntArray(4)
        private val starHandles = IntArray(4)
        private val atmosphereHandles = IntArray(3)
        private var atmosphereProgram = 0
        private var atmosphereBuffer = 0
        private var starPhase = 0f
        private var starProgram = 0
        private var starBuffer = 0
        private var starCount = 0
        private var starWidth = 0
        private var starHeight = 0
        private var starPointScale = 1f
        private var program = 0
        private var lineProgram = 0
        private var texture = 0
        private var cloudTexture = 0
        private var nightTexture = 0
        private var anisotropy = 1f
        private var failed = false
        private var frameSent = false
        private var width = 1
        private var height = 1
        private var textureWidth = 0
        private var textureHeight = 0
        private var nightTextureWidth = 0
        private var nightTextureHeight = 0
        private var solarSecond = Long.MIN_VALUE
        private val sunLocal = FloatArray(4)
        private val sunWorld = FloatArray(4)
        private var yaw = -45f
        private var lastFrame = 0L
        private val projection = FloatArray(16)
        private val view = FloatArray(16)
        private val model = FloatArray(16)
        private val temp = FloatArray(16)
        private val mvp = FloatArray(16)
        private val mesh = sphere()

        fun setRoutes(raw: Any?) {
            if (raw !is List<*>) return
            val rows = raw.take(8).filterIsInstance<Map<*, *>>()
            geometry = FlightGeometry(rows.mapNotNull { route(it) }, rows.mapNotNull { position(it) })
        }
        override fun onSurfaceCreated(gl: GL10?, config: EGLConfig?) {
            failed = false
            frameSent = false
            lastFrame = 0L
            solarSecond = Long.MIN_VALUE
            texture = 0
            nightTexture = 0
            try {
                GLES20.glClearColor(0f, 0f, 0f, 1f)
                GLES20.glEnable(GLES20.GL_DEPTH_TEST)
                GLES20.glEnable(GLES20.GL_CULL_FACE)
                // GLES2 fragment highp is optional. Query once per GL context;
                // both stages must use matching varying precision for linking.
                val floatRange = IntArray(2)
                val floatPrecision = IntArray(1)
                GLES20.glGetShaderPrecisionFormat(GLES20.GL_FRAGMENT_SHADER,
                    GLES20.GL_HIGH_FLOAT, floatRange, 0, floatPrecision, 0)
                val uvPrecision = if (floatPrecision[0] > 0) "highp" else "mediump"
                program = program(
                    VERTEX.replace("UV_PRECISION", uvPrecision),
                    FRAGMENT.replace("UV_PRECISION", uvPrecision))
                lineProgram = program(LINE_VERTEX, LINE_FRAGMENT)
                starProgram = program(STAR_VERTEX, STAR_FRAGMENT)
                starHandles[0] = GLES20.glGetAttribLocation(starProgram, "a_starPosition")
                starHandles[1] = GLES20.glGetAttribLocation(starProgram, "a_starAppearance")
                starHandles[2] = GLES20.glGetUniformLocation(starProgram, "u_pointScale")
                starHandles[3] = GLES20.glGetUniformLocation(starProgram, "u_twinklePhase")
                atmosphereProgram = program(ATMOSPHERE_VERTEX, ATMOSPHERE_FRAGMENT)
                atmosphereHandles[0] = GLES20.glGetAttribLocation(atmosphereProgram, "a_corner")
                atmosphereHandles[1] = GLES20.glGetUniformLocation(atmosphereProgram, "u_disc")
                atmosphereHandles[2] = GLES20.glGetUniformLocation(atmosphereProgram, "u_sunWorld")
                val haloNames = IntArray(1)
                GLES20.glGenBuffers(1, haloNames, 0)
                atmosphereBuffer = haloNames[0]
                GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, atmosphereBuffer)
                GLES20.glBufferData(GLES20.GL_ARRAY_BUFFER, 32,
                    floats(floatArrayOf(-1f,-1f, 1f,-1f, -1f,1f, 1f,1f)), GLES20.GL_STATIC_DRAW)
                GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, 0)
                val starNames = IntArray(1)
                GLES20.glGenBuffers(1, starNames, 0)
                starBuffer = starNames[0]
                starCount = 0
                starWidth = 0
                starHeight = 0
                sphereHandles[0] = GLES20.glGetUniformLocation(program, "u_mvp")
                sphereHandles[1] = GLES20.glGetUniformLocation(program, "u_model")
                sphereHandles[2] = GLES20.glGetAttribLocation(program, "a_position")
                sphereHandles[3] = GLES20.glGetAttribLocation(program, "a_uv")
                sphereHandles[4] = GLES20.glGetUniformLocation(program, "u_texture")
                sphereHandles[5] = GLES20.glGetUniformLocation(program, "u_nightTexture")
                sphereHandles[6] = GLES20.glGetUniformLocation(program, "u_sunLocal")
                sphereHandles[7] = GLES20.glGetUniformLocation(program, "u_sunWorld")
                sphereHandles[8] = GLES20.glGetUniformLocation(program, "u_cloudTexture")
                sphereHandles[9] = GLES20.glGetUniformLocation(program, "u_cloudEnabled")
                lineHandles[0] = GLES20.glGetUniformLocation(lineProgram, "u_mvp")
                lineHandles[1] = GLES20.glGetAttribLocation(lineProgram, "a_position")
                lineHandles[2] = GLES20.glGetUniformLocation(lineProgram, "u_points")
                lineHandles[3] = GLES20.glGetUniformLocation(lineProgram, "u_pointSize")
                GLES20.glGenBuffers(2, sphereBuffers, 0)
                mesh.first.position(0)
                GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, sphereBuffers[0])
                GLES20.glBufferData(GLES20.GL_ARRAY_BUFFER, mesh.first.limit() * 4, mesh.first, GLES20.GL_STATIC_DRAW)
                mesh.second.position(0)
                GLES20.glBindBuffer(GLES20.GL_ELEMENT_ARRAY_BUFFER, sphereBuffers[1])
                GLES20.glBufferData(GLES20.GL_ELEMENT_ARRAY_BUFFER, mesh.second.limit() * 2, mesh.second, GLES20.GL_STATIC_DRAW)
                GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, 0)
                GLES20.glBindBuffer(GLES20.GL_ELEMENT_ARRAY_BUFFER, 0)
                // IDs from a lost EGL context are no longer valid.
                routeBuffers.clear()
                positionBuffers.clear()
                uploadedGeometry = null
                val max = IntArray(1)
                GLES20.glGetIntegerv(GLES20.GL_MAX_TEXTURE_SIZE, max, 0)
                val memory = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
                val free = ActivityManager.MemoryInfo()
                memory?.getMemoryInfo(free)
                val tier = NakuTVSolar.textureTier(max[0], free.availMem,
                    memory?.memoryClass ?: 0, memory?.isLowRamDevice == true || free.lowMemory)
                require(tier >= NakuTVSolar.MIN_TEXTURE_TIER)
                check(GLES20.glGetError() == GLES20.GL_NO_ERROR)
                if (GLES20.glGetString(GLES20.GL_EXTENSIONS)?.contains("GL_EXT_texture_filter_anisotropic") == true) {
                    val maximum = FloatArray(1)
                    GLES20.glGetFloatv(0x84FF, maximum, 0)
                    if (maximum[0].isFinite()) anisotropy = maximum[0].coerceIn(1f, 4f)
                }
                loadTexturePair(tier)
                // The same optional 2K historical cloud map as the other clients.
                // Its ~20 MiB bitmap + mipmap peak fits the reserved headroom.
                cloudTexture = try { loadTexture(cloudAsset, 2048).id }
                    catch (_: Exception) { clearGlErrors(); 0 }
                    catch (_: OutOfMemoryError) { clearGlErrors(); 0 }
            } catch (_: Exception) { failed = true; onError() }
            catch (_: OutOfMemoryError) { failed = true; onError() }
        }
        override fun onSurfaceChanged(gl: GL10?, width: Int, height: Int) {
            this.width = width.coerceAtLeast(1)
            this.height = height.coerceAtLeast(1)
            GLES20.glViewport(0, 0, this.width, this.height)
            uploadStars()
        }
        override fun onDrawFrame(gl: GL10?) {
            GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT or GLES20.GL_DEPTH_BUFFER_BIT)
            if (failed || program == 0 || !animating) { lastFrame = 0L; return }
            val now = System.nanoTime()
            val delta = if (lastFrame == 0L) 0f else ((now - lastFrame) / 1_000_000_000f).coerceIn(0f, .1f)
            yaw = (yaw + delta * 1.68f) % 360f
            // Integer star frequencies make a seamless two-minute phase loop.
            starPhase = (starPhase + delta * (2f * PI.toFloat() / 120f)) % (2f * PI.toFloat())
            drawStars()
            lastFrame = now
            val utcMillis = System.currentTimeMillis()
            if (utcMillis / 1000L != solarSecond) {
                val direction = NakuTVSolar.earthFixedSunDirection(utcMillis)
                for (axis in 0..2) sunLocal[axis] = direction[axis].toFloat()
                sunLocal[3] = 0f
                solarSecond = utcMillis / 1000L
            }
            val aspect = width.toFloat() / height
            val radius = min(.88f, aspect * .90f)
            val center = if (aspect >= 1.2f) .32f * aspect else 0f
            Matrix.orthoM(projection, 0, -aspect, aspect, -1f, 1f, 1f, 10f)
            Matrix.setLookAtM(view, 0, 0f, 0f, 4f, 0f, 0f, 0f, 0f, 1f, 0f)
            Matrix.setIdentityM(model, 0)
            Matrix.translateM(model, 0, center, 0f, 0f)
            Matrix.scaleM(model, 0, radius, radius, radius)
            Matrix.rotateM(model, 0, 24f, 1f, 0f, 0f)
            Matrix.rotateM(model, 0, yaw, 0f, 1f, 0f)
            Matrix.multiplyMM(temp, 0, view, 0, model, 0)
            Matrix.multiplyMM(mvp, 0, projection, 0, temp, 0)
            // Transform only for view-dependent ocean/limb appearance. The
            // day/night mask itself uses unrotated geographic normals below.
            Matrix.multiplyMV(sunWorld, 0, model, 0, sunLocal, 0)
            drawAtmosphere(center / aspect, radius / aspect, radius)
            GLES20.glUseProgram(program)
            GLES20.glUniformMatrix4fv(sphereHandles[0], 1, false, mvp, 0)
            GLES20.glUniformMatrix4fv(sphereHandles[1], 1, false, model, 0)
            val position = sphereHandles[2]
            val uv = sphereHandles[3]
            GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, sphereBuffers[0])
            GLES20.glBindBuffer(GLES20.GL_ELEMENT_ARRAY_BUFFER, sphereBuffers[1])
            GLES20.glEnableVertexAttribArray(position)
            GLES20.glVertexAttribPointer(position, 3, GLES20.GL_FLOAT, false, 20, 0)
            GLES20.glEnableVertexAttribArray(uv)
            GLES20.glVertexAttribPointer(uv, 2, GLES20.GL_FLOAT, false, 20, 12)
            GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, texture)
            GLES20.glUniform1i(sphereHandles[4], 0)
            GLES20.glActiveTexture(GLES20.GL_TEXTURE1)
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, nightTexture)
            GLES20.glUniform1i(sphereHandles[5], 1)
            GLES20.glUniform3fv(sphereHandles[6], 1, sunLocal, 0)
            GLES20.glUniform3fv(sphereHandles[7], 1, sunWorld, 0)
            GLES20.glActiveTexture(GLES20.GL_TEXTURE2)
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, if (cloudTexture != 0) cloudTexture else texture)
            GLES20.glUniform1i(sphereHandles[8], 2)
            GLES20.glUniform1f(sphereHandles[9], if (cloudTexture != 0) 1f else 0f)
            GLES20.glDrawElements(GLES20.GL_TRIANGLES, mesh.second.limit(), GLES20.GL_UNSIGNED_SHORT, 0)
            GLES20.glBindBuffer(GLES20.GL_ELEMENT_ARRAY_BUFFER, 0)
            GLES20.glDisableVertexAttribArray(position)
            GLES20.glDisableVertexAttribArray(uv)
            GLES20.glUseProgram(lineProgram)
            GLES20.glUniformMatrix4fv(lineHandles[0], 1, false, mvp, 0)
            uploadFlightGeometry()
            val routePosition = lineHandles[1]
            GLES20.glEnableVertexAttribArray(routePosition)
            GLES20.glUniform1f(lineHandles[2], 0f)
            GLES20.glUniform1f(lineHandles[3], (height / 180f).coerceIn(4f, 10f))
            routeBuffers.forEach { (buffer, count) ->
                GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, buffer)
                GLES20.glVertexAttribPointer(routePosition, 3, GLES20.GL_FLOAT, false, 12, 0)
                GLES20.glDrawArrays(GLES20.GL_LINE_STRIP, 0, count)
            }
            GLES20.glUniform1f(lineHandles[2], 1f)
            positionBuffers.forEach { buffer ->
                GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, buffer)
                GLES20.glVertexAttribPointer(routePosition, 3, GLES20.GL_FLOAT, false, 12, 0)
                GLES20.glDrawArrays(GLES20.GL_POINTS, 0, 1)
            }
            GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, 0)
            GLES20.glDisableVertexAttribArray(routePosition)
            if (!frameSent) {
                if (GLES20.glGetError() != GLES20.GL_NO_ERROR) { failed = true; onError(); return }
                GLES20.glFinish()
                frameSent = true
                onFrame(mapOf("width" to width, "height" to height,
                    "textureWidth" to textureWidth, "textureHeight" to textureHeight,
                    "nightTextureWidth" to nightTextureWidth, "nightTextureHeight" to nightTextureHeight,
                    "solarUtcMillis" to solarSecond * 1000L, "dayNight" to true,
                    "fpsLimit" to 24, "renderer" to "gles2",
                    "staticStars" to false, "twinklingStars" to true, "atmosphere" to true, "clouds" to (cloudTexture != 0), "starCount" to starCount))
            }
        }
        private fun drawAtmosphere(centerX: Float, radiusX: Float, radiusY: Float) {
            // Four vertices and analytic falloff; no extra planet mesh/map,
            // ray marching, blur render target or independent animation loop.
            GLES20.glDisable(GLES20.GL_DEPTH_TEST)
            GLES20.glDepthMask(false)
            GLES20.glDisable(GLES20.GL_CULL_FACE)
            GLES20.glEnable(GLES20.GL_BLEND)
            GLES20.glBlendFunc(GLES20.GL_ONE, GLES20.GL_ONE_MINUS_SRC_ALPHA)
            GLES20.glUseProgram(atmosphereProgram)
            GLES20.glUniform4f(atmosphereHandles[1], centerX, 0f, radiusX, radiusY)
            GLES20.glUniform3fv(atmosphereHandles[2], 1, sunWorld, 0)
            GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, atmosphereBuffer)
            GLES20.glEnableVertexAttribArray(atmosphereHandles[0])
            GLES20.glVertexAttribPointer(atmosphereHandles[0], 2, GLES20.GL_FLOAT, false, 8, 0)
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
            GLES20.glDisableVertexAttribArray(atmosphereHandles[0])
            GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, 0)
            GLES20.glDisable(GLES20.GL_BLEND)
            GLES20.glDepthMask(true)
            GLES20.glEnable(GLES20.GL_DEPTH_TEST)
            GLES20.glEnable(GLES20.GL_CULL_FACE)
        }
        private fun uploadStars() {
            if (failed || starProgram == 0 || starBuffer == 0 ||
                (starWidth == width && starHeight == height)) return
            val points = NakuTVStars.geometry(width, height)
            val data = floats(points)
            GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, starBuffer)
            GLES20.glBufferData(GLES20.GL_ARRAY_BUFFER, points.size * 4, data, GLES20.GL_STATIC_DRAW)
            GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, 0)
            starCount = points.size / NakuTVStars.STRIDE
            starWidth = width
            starHeight = height
            starPointScale = (height / 720f).coerceIn(.75f, 3f)
        }

        private fun drawStars() {
            if (starCount == 0) return
            // Positions stay in a static clip-space VBO; only luminance receives a phase.
            // Draw first without depth writes; the opaque Earth covers it fully,
            // including its dark hemisphere. No stars shine through the globe.
            GLES20.glDisable(GLES20.GL_DEPTH_TEST)
            GLES20.glDepthMask(false)
            GLES20.glDisable(GLES20.GL_CULL_FACE)
            GLES20.glEnable(GLES20.GL_BLEND)
            GLES20.glBlendFunc(GLES20.GL_SRC_ALPHA, GLES20.GL_ONE)
            GLES20.glUseProgram(starProgram)
            GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, starBuffer)
            GLES20.glEnableVertexAttribArray(starHandles[0])
            GLES20.glVertexAttribPointer(starHandles[0], 2, GLES20.GL_FLOAT, false, 20, 0)
            GLES20.glEnableVertexAttribArray(starHandles[1])
            GLES20.glVertexAttribPointer(starHandles[1], 3, GLES20.GL_FLOAT, false, 20, 8)
            GLES20.glUniform1f(starHandles[2], starPointScale)
            GLES20.glUniform1f(starHandles[3], starPhase)
            GLES20.glDrawArrays(GLES20.GL_POINTS, 0, starCount)
            GLES20.glDisableVertexAttribArray(starHandles[0])
            GLES20.glDisableVertexAttribArray(starHandles[1])
            GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, 0)
            GLES20.glDisable(GLES20.GL_BLEND)
            GLES20.glDepthMask(true)
            GLES20.glEnable(GLES20.GL_DEPTH_TEST)
            GLES20.glEnable(GLES20.GL_CULL_FACE)
        }

        private data class TextureData(val id: Int, val width: Int, val height: Int)
        private fun loadTexturePair(initialTier: Int) {
            var tier = initialTier
            while (tier >= NakuTVSolar.MIN_TEXTURE_TIER) {
                var day: TextureData? = null
                var night: TextureData? = null
                try {
                    day = loadTexture(dayAsset, tier)
                    night = loadTexture(nightAsset, tier)
                    require(day.width == night.width && day.height == night.height)
                    texture = day.id
                    nightTexture = night.id
                    textureWidth = day.width
                    textureHeight = day.height
                    nightTextureWidth = night.width
                    nightTextureHeight = night.height
                    return
                } catch (_: OutOfMemoryError) {
                    // Both textures retry at the next complete supported tier.
                } catch (_: RuntimeException) {
                    // Includes GL_OUT_OF_MEMORY / faulty advertised texture size.
                }
                val ids = listOfNotNull(day?.id, night?.id).toIntArray()
                if (ids.isNotEmpty()) GLES20.glDeleteTextures(ids.size, ids, 0)
                clearGlErrors()
                GLES20.glFinish()
                tier /= 2
            }
            throw IllegalStateException("Earth day/night textures could not be allocated")
        }
        private fun loadTexture(asset: String, tier: Int): TextureData {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true; inScaled = false }
            context.assets.open(asset).use { BitmapFactory.decodeStream(it, null, bounds) }
            require(bounds.outWidth == 8192 && bounds.outHeight == 4096 ||
                asset == cloudAsset && bounds.outWidth == 2048 && bounds.outHeight == 1024)
            var sample = 1
            while (bounds.outWidth / sample > tier) sample *= 2
            val options = BitmapFactory.Options().apply {
                inScaled = false
                inSampleSize = sample
                inPreferredConfig = android.graphics.Bitmap.Config.ARGB_8888
            }
            val bitmap = context.assets.open(asset).use { BitmapFactory.decodeStream(it, null, options) }
                ?: throw IllegalStateException("Earth texture could not be decoded")
            val ids = IntArray(1)
            try {
                GLES20.glGenTextures(1, ids, 0)
                GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, ids[0])
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR_MIPMAP_LINEAR)
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_REPEAT)
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
                if (anisotropy > 1f) GLES20.glTexParameterf(GLES20.GL_TEXTURE_2D, 0x84FE, anisotropy)
                GLUtils.texImage2D(GLES20.GL_TEXTURE_2D, 0, bitmap, 0)
                GLES20.glGenerateMipmap(GLES20.GL_TEXTURE_2D)
                check(GLES20.glGetError() == GLES20.GL_NO_ERROR)
                return TextureData(ids[0], bitmap.width, bitmap.height)
            } catch (error: Throwable) {
                if (ids[0] != 0) GLES20.glDeleteTextures(1, ids, 0)
                throw error
            } finally { bitmap.recycle() }
        }
        private fun clearGlErrors() {
            // Lost-context drivers must never trap the renderer in a busy loop.
            repeat(8) { if (GLES20.glGetError() == GLES20.GL_NO_ERROR) return }
        }
        private fun uploadFlightGeometry() {
            val next = geometry
            if (next === uploadedGeometry) return
            val previous = (routeBuffers.map { it.first } + positionBuffers).toIntArray()
            if (previous.isNotEmpty()) GLES20.glDeleteBuffers(previous.size, previous, 0)
            routeBuffers.clear()
            positionBuffers.clear()
            fun upload(values: FloatBuffer): Int {
                val id = IntArray(1)
                GLES20.glGenBuffers(1, id, 0)
                GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, id[0])
                values.position(0)
                GLES20.glBufferData(GLES20.GL_ARRAY_BUFFER, values.limit() * 4, values, GLES20.GL_STATIC_DRAW)
                return id[0]
            }
            next.routes.forEach { routeBuffers.add(upload(it) to it.limit() / 3) }
            next.positions.forEach { positionBuffers.add(upload(it)) }
            uploadedGeometry = next
        }
        companion object {
            private const val VERTEX = """
                attribute vec3 a_position;
                attribute vec2 a_uv;
                uniform mat4 u_mvp;
                uniform mat4 u_model;
                varying UV_PRECISION vec2 v_uv;
                varying mediump vec3 v_localNormal;
                varying mediump vec3 v_worldNormal;
                void main() {
                    v_uv = a_uv;
                    v_localNormal = a_position;
                    v_worldNormal = normalize((u_model * vec4(a_position, 0.0)).xyz);
                    gl_Position = u_mvp * vec4(a_position, 1.0);
                }
            """
            private const val FRAGMENT = """
                precision mediump float;
                varying UV_PRECISION vec2 v_uv;
                varying mediump vec3 v_localNormal;
                varying mediump vec3 v_worldNormal;
                uniform sampler2D u_texture;
                uniform sampler2D u_nightTexture;
                uniform sampler2D u_cloudTexture;
                uniform float u_cloudEnabled;
                uniform mediump vec3 u_sunLocal;
                uniform mediump vec3 u_sunWorld;
                vec3 srgbToLinear(vec3 c) {
                    return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
                }
                vec3 linearToSrgb(vec3 c) {
                    return mix(c * 12.92, 1.055 * pow(max(c, vec3(0.0)), vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), c));
                }
                // Same ACES display transform used by Home Display's R3F Canvas.
                vec3 displayTone(vec3 c) {
                    mat3 inputMat = mat3(0.59719,0.07600,0.02840,
                        0.35458,0.90834,0.13383,0.04823,0.01566,0.83777);
                    mat3 outputMat = mat3(1.60475,-0.10208,-0.00327,
                        -0.53108,1.10813,-0.07276,-0.07367,-0.00605,1.07602);
                    c = inputMat * (c / 0.6);
                    vec3 a = c * (c + 0.0245786) - 0.000090537;
                    vec3 b = c * (0.983729 * c + 0.4329510) + 0.238081;
                    return clamp(outputMat * (a / b), 0.0, 1.0);
                }
                void main() {
                    // The solar dot is Earth-fixed, independent of visual yaw.
                    float solar = dot(normalize(v_localNormal), normalize(u_sunLocal));
                    vec3 n = normalize(v_worldNormal);
                    vec3 sun = normalize(u_sunWorld);
                    // Orthographic native projection has parallel +Z view rays.
                    vec3 view = vec3(0.0, 0.0, 1.0);
                    // Day RGB is sRGB; the historical VIIRS mask below is raw data.
                    vec3 texel = texture2D(u_texture, v_uv).rgb;
                    vec3 mapColor = srgbToLinear(texel);
                    float daylight = smoothstep(-0.075, 0.12, solar);
                    float direct = 0.64 + 0.40 * pow(max(0.0, solar), 0.65);
                    // Compute the water mask before gamma decoding: dark blue
                    // oceans must not collapse into a coarse near-black mask.
                    float ocean = smoothstep(0.015, 0.10, texel.b - texel.g)
                        * smoothstep(0.025, 0.13, texel.b - texel.r);
                    mapColor *= mix(vec3(1.0), vec3(0.94, 0.98, 1.035), ocean);
                    vec3 color = mapColor * mix(vec3(0.54, 0.68, 0.91) * 0.13, vec3(direct), daylight);
                    vec3 halfVector = normalize(sun + view);
                    float highlight = pow(max(0.0, dot(n, halfVector)), 64.0) * 0.032
                        + pow(max(0.0, dot(n, halfVector)), 12.0) * 0.007;
                    color += vec3(0.72, 0.82, 0.89) * highlight * ocean * daylight;
                    float limb = pow(1.0 - max(0.0, dot(n, view)), 4.0);
                    float dusk = exp(-pow((solar + 0.018) / 0.085, 2.0));
                    color = mix(color, vec3(0.18, 0.34, 0.49), limb * daylight * 0.23);
                    color += vec3(0.10, 0.047, 0.014) * dusk * (0.025 + limb * 0.09);
                    float darkness = smoothstep(0.015, 0.215, -solar);
                    float emission = texture2D(u_nightTexture, v_uv).r;
                    vec3 lamp = mix(vec3(0.80, 0.48, 0.19), vec3(1.0, 0.85, 0.57), smoothstep(0.12, 0.8, emission));
                    color += lamp * pow(emission, 0.94) * darkness * 0.95;
                    // Composite clouds into the existing sphere: no third mesh
                    // or spinning model, and nothing can bleed outside the limb.
                    float cloud = srgbToLinear(texture2D(u_cloudTexture, v_uv).rgb).r;
                    float density = smoothstep(0.09, 0.83, cloud) * u_cloudEnabled;
                    vec3 cloudColor = mix(vec3(0.10, 0.15, 0.21), vec3(0.76, 0.83, 0.86), daylight);
                    color = mix(color, cloudColor, density * (0.045 + daylight * 0.31));
                    gl_FragColor = vec4(linearToSrgb(displayTone(color)), 1.0);
                }
            """
            private const val ATMOSPHERE_VERTEX = """
                attribute vec2 a_corner;
                uniform vec4 u_disc;
                varying mediump vec2 v_disc;
                void main() {
                    v_disc = a_corner * 1.05;
                    gl_Position = vec4(u_disc.xy + v_disc * u_disc.zw, 0.0, 1.0);
                }
            """
            private const val ATMOSPHERE_FRAGMENT = """
                precision mediump float;
                varying mediump vec2 v_disc;
                uniform vec3 u_sunWorld;
                void main() {
                    float radius = length(v_disc);
                    if (radius < 1.0 || radius > 1.05) discard;
                    float altitude = radius - 1.0;
                    float solar = dot(vec3(v_disc / radius, 0.0), normalize(u_sunWorld));
                    float day = smoothstep(-0.16, 0.20, solar);
                    float dusk = exp(-pow(solar / 0.12, 2.0));
                    vec3 color = mix(vec3(0.10,0.18,0.29), vec3(0.28,0.52,0.76), day);
                    color = mix(color, vec3(0.63,0.40,0.21), dusk * 0.23);
                    color = 1.055 * pow(color, vec3(1.0/2.4)) - 0.055;
                    float alpha = exp(-altitude * 110.0) * (1.0 - smoothstep(0.025,0.05,altitude)) * (0.045 + day * 0.36);
                    gl_FragColor = vec4(color * alpha, alpha);
                }
            """
            private const val STAR_VERTEX = """
                precision mediump float;
                attribute vec2 a_starPosition;
                attribute vec3 a_starAppearance;
                uniform float u_pointScale;
                uniform float u_twinklePhase;
                varying mediump float v_light;
                varying mediump float v_warmth;
                varying mediump float v_size;
                void main() {
                    float phase = dot(a_starPosition, vec2(9.7, 17.3)) + a_starAppearance.y * 6.2831853;
                    float frequency = 6.0 + floor(a_starAppearance.y * 12.0);
                    v_light = a_starAppearance.x * (0.80 + 0.20 * sin(phase + u_twinklePhase * frequency));
                    v_warmth = a_starAppearance.y;
                    v_size = a_starAppearance.z;
                    gl_PointSize = v_size * u_pointScale;
                    gl_Position = vec4(a_starPosition, 0.0, 1.0);
                }
            """
            private const val STAR_FRAGMENT = """
                precision mediump float;
                varying mediump float v_light;
                varying mediump float v_warmth;
                varying mediump float v_size;
                void main() {
                    vec2 p = gl_PointCoord * 2.0 - 1.0;
                    float r2 = dot(p, p);
                    float halo = exp(-r2 * 4.8) * 0.28;
                    float core = exp(-r2 * 16.0);
                    float rays = exp(-abs(p.x * p.y) * 95.0) * exp(-r2 * 6.0)
                        * step(7.0, v_size) * 0.22;
                    float alpha = (core + halo + rays) * v_light
                        * (1.0 - smoothstep(0.65, 1.0, r2));
                    vec3 color = mix(vec3(0.67, 0.80, 1.0), vec3(1.0, 0.94, 0.83), v_warmth);
                    gl_FragColor = vec4(color, alpha);
                }
            """
            private const val LINE_VERTEX = """
                attribute vec3 a_position;
                uniform mat4 u_mvp;
                uniform float u_pointSize;
                void main() { gl_Position = u_mvp * vec4(a_position, 1.0); gl_PointSize = u_pointSize; }
            """
            private const val LINE_FRAGMENT = """
                precision mediump float;
                uniform float u_points;
                void main() {
                    if (u_points > 0.5 && distance(gl_PointCoord, vec2(0.5)) > 0.5) discard;
                    gl_FragColor = vec4(0.91, 0.76, 0.43, 1.0);
                }
            """
            private fun program(vertex: String, fragment: String): Int {
                fun shader(type: Int, source: String): Int {
                    val shader = GLES20.glCreateShader(type)
                    GLES20.glShaderSource(shader, source)
                    GLES20.glCompileShader(shader)
                    val ok = IntArray(1)
                    GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, ok, 0)
                    if (ok[0] == 0) { GLES20.glDeleteShader(shader); throw IllegalStateException() }
                    return shader
                }
                val v = shader(GLES20.GL_VERTEX_SHADER, vertex)
                val f = shader(GLES20.GL_FRAGMENT_SHADER, fragment)
                val program = GLES20.glCreateProgram()
                GLES20.glAttachShader(program, v)
                GLES20.glAttachShader(program, f)
                GLES20.glLinkProgram(program)
                GLES20.glDeleteShader(v)
                GLES20.glDeleteShader(f)
                val ok = IntArray(1)
                GLES20.glGetProgramiv(program, GLES20.GL_LINK_STATUS, ok, 0)
                if (ok[0] == 0) { GLES20.glDeleteProgram(program); throw IllegalStateException() }
                return program
            }
            private fun floats(values: FloatArray): FloatBuffer = ByteBuffer
                .allocateDirect(values.size * 4).order(ByteOrder.nativeOrder()).asFloatBuffer().apply {
                    put(values); position(0)
                }
            private fun sphere(): Pair<FloatBuffer, ShortBuffer> {
                val rows = 48; val columns = 96
                val vertices = FloatArray((rows + 1) * (columns + 1) * 5)
                var at = 0
                for (row in 0..rows) {
                    val latitude = PI / 2 - row * PI / rows
                    for (column in 0..columns) {
                        val longitude = column * 2 * PI / columns - PI
                        vertices[at++] = (cos(latitude) * sin(longitude)).toFloat()
                        vertices[at++] = sin(latitude).toFloat()
                        vertices[at++] = (cos(latitude) * cos(longitude)).toFloat()
                        vertices[at++] = column.toFloat() / columns
                        vertices[at++] = row.toFloat() / rows
                    }
                }
                val indices = ShortArray(rows * columns * 6)
                at = 0
                for (row in 0 until rows) for (column in 0 until columns) {
                    val a = row * (columns + 1) + column
                    val b = a + columns + 1
                    indices[at++] = a.toShort(); indices[at++] = b.toShort(); indices[at++] = (a + 1).toShort()
                    indices[at++] = (a + 1).toShort(); indices[at++] = b.toShort(); indices[at++] = (b + 1).toShort()
                }
                return floats(vertices) to ByteBuffer.allocateDirect(indices.size * 2)
                    .order(ByteOrder.nativeOrder()).asShortBuffer().apply { put(indices); position(0) }
            }
            private fun position(row: Map<*, *>): FloatBuffer? {
                val lat = (row["positionLat"] as? Number)?.toDouble()
                    ?.takeIf { it.isFinite() && abs(it) <= 90 } ?: return null
                val lon = (row["positionLon"] as? Number)?.toDouble()
                    ?.takeIf { it.isFinite() && abs(it) <= 180 } ?: return null
                val a = lat * PI / 180; val b = lon * PI / 180
                return floats(floatArrayOf((cos(a) * sin(b) * 1.014).toFloat(),
                    (sin(a) * 1.014).toFloat(), (cos(a) * cos(b) * 1.014).toFloat()))
            }
            private fun route(row: Map<*, *>): FloatBuffer? {
                fun value(key: String, limit: Double): Double? = (row[key] as? Number)?.toDouble()
                    ?.takeIf { it.isFinite() && abs(it) <= limit }
                fun point(lat: Double, lon: Double): DoubleArray {
                    val a = lat * PI / 180; val b = lon * PI / 180
                    return doubleArrayOf(cos(a) * sin(b), sin(a), cos(a) * cos(b))
                }
                val from = point(value("originLat", 90.0) ?: return null, value("originLon", 180.0) ?: return null)
                val to = point(value("destinationLat", 90.0) ?: return null, value("destinationLon", 180.0) ?: return null)
                val angle = acos(from.indices.sumOf { from[it] * to[it] }.coerceIn(-1.0, 1.0))
                if (angle < 1e-6 || PI - angle < 1e-6) return null
                val values = FloatArray(65 * 3)
                for (i in 0..64) {
                    val t = i / 64.0
                    val a = sin((1 - t) * angle) / sin(angle)
                    val b = sin(t * angle) / sin(angle)
                    for (axis in 0..2) values[i * 3 + axis] = ((from[axis] * a + to[axis] * b) * 1.008).toFloat()
                }
                return floats(values)
            }
        }
    }
}
