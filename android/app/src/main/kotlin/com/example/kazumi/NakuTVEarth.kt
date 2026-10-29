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
 * No browser, controls, atmosphere, particles, landmarks or aircraft models.
 */
class NakuTVEarth(private val activity: Activity, engine: FlutterEngine) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler,
    Application.ActivityLifecycleCallbacks {
    private val handler = Handler(Looper.getMainLooper())
    private val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "naku/tv-earth")
    private val events = EventChannel(engine.dartExecutor.binaryMessenger, "naku/tv-earth/events")
    private val textureAsset = engine.flutterLoaderAsset("assets/images/tv_earth_4k.webp")
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
        private val renderer = EarthRenderer(context, textureAsset,
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
        private val asset: String,
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
        private val sphereHandles = IntArray(5)
        private val lineHandles = IntArray(4)
        private var program = 0
        private var lineProgram = 0
        private var texture = 0
        private var failed = false
        private var frameSent = false
        private var width = 1
        private var height = 1
        private var textureWidth = 0
        private var textureHeight = 0
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
                sphereHandles[0] = GLES20.glGetUniformLocation(program, "u_mvp")
                sphereHandles[1] = GLES20.glGetUniformLocation(program, "u_model")
                sphereHandles[2] = GLES20.glGetAttribLocation(program, "a_position")
                sphereHandles[3] = GLES20.glGetAttribLocation(program, "a_uv")
                sphereHandles[4] = GLES20.glGetUniformLocation(program, "u_texture")
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
                require(max[0] >= 1024)
                val memory = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
                val budget = if (memory?.isLowRamDevice == true || (memory?.memoryClass ?: 256) <= 128) 2048 else 4096
                val limit = max[0].coerceAtMost(budget)
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true; inScaled = false }
                context.assets.open(asset).use { BitmapFactory.decodeStream(it, null, bounds) }
                require(bounds.outWidth > 0 && bounds.outHeight > 0)
                var sample = 1
                while (bounds.outWidth / sample > limit || bounds.outHeight / sample > limit) sample *= 2
                val options = BitmapFactory.Options().apply {
                    inScaled = false
                    inSampleSize = sample
                    inPreferredConfig = android.graphics.Bitmap.Config.ARGB_8888
                }
                val bitmap = context.assets.open(asset).use { BitmapFactory.decodeStream(it, null, options) }
                    ?: throw IllegalStateException()
                textureWidth = bitmap.width
                textureHeight = bitmap.height
                val names = IntArray(1)
                GLES20.glGenTextures(1, names, 0)
                texture = names[0]
                GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, texture)
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR_MIPMAP_LINEAR)
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
                try {
                    GLUtils.texImage2D(GLES20.GL_TEXTURE_2D, 0, bitmap, 0)
                    // Power-of-two texture: build once, avoid moving coast shimmer.
                    GLES20.glGenerateMipmap(GLES20.GL_TEXTURE_2D)
                } finally { bitmap.recycle() }
                check(GLES20.glGetError() == GLES20.GL_NO_ERROR)
            } catch (_: Exception) { failed = true; onError() }
            catch (_: OutOfMemoryError) { failed = true; onError() }
        }
        override fun onSurfaceChanged(gl: GL10?, width: Int, height: Int) {
            this.width = width.coerceAtLeast(1)
            this.height = height.coerceAtLeast(1)
            GLES20.glViewport(0, 0, this.width, this.height)
        }
        override fun onDrawFrame(gl: GL10?) {
            GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT or GLES20.GL_DEPTH_BUFFER_BIT)
            if (failed || program == 0 || !animating) { lastFrame = 0L; return }
            val now = System.nanoTime()
            if (lastFrame != 0L) yaw = (yaw + ((now - lastFrame) / 1_000_000_000f).coerceIn(0f, .1f) * 1.68f) % 360f
            lastFrame = now
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
                    "fpsLimit" to 24, "renderer" to "gles2"))
            }
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
                varying mediump vec3 v_normal;
                void main() {
                    v_uv = a_uv;
                    v_normal = normalize((u_model * vec4(a_position, 0.0)).xyz);
                    gl_Position = u_mvp * vec4(a_position, 1.0);
                }
            """
            private const val FRAGMENT = """
                precision mediump float;
                varying UV_PRECISION vec2 v_uv;
                varying mediump vec3 v_normal;
                uniform sampler2D u_texture;
                void main() {
                    vec3 day = texture2D(u_texture, v_uv).rgb;
                    float diffuse = max(dot(normalize(v_normal), normalize(vec3(-0.45, 0.45, 1.0))), 0.0);
                    gl_FragColor = vec4(day * (0.55 + 0.45 * diffuse), 1.0);
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
