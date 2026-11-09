package com.example.kialauncher

import android.content.Context
import android.graphics.PixelFormat
import android.opengl.GLES20
import android.opengl.GLSurfaceView
import android.opengl.Matrix
import android.os.SystemClock
import android.util.AttributeSet
import android.util.Log
import android.view.MotionEvent
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.sin
import kotlin.math.tan

// Couleurs de carrosserie : un appui sur la voiture passe à la suivante
val PALETTE = arrayOf(
    floatArrayOf(0.93f, 0.94f, 0.96f),
    floatArrayOf(0.55f, 0.58f, 0.62f),
    floatArrayOf(0.80f, 0.10f, 0.12f),
    floatArrayOf(0.12f, 0.35f, 0.80f),
    floatArrayOf(0.08f, 0.08f, 0.10f),
    floatArrayOf(0.75f, 0.85f, 0.15f)
)

private const val VS = """
uniform mat4 uMvp;
attribute vec3 aPos;
attribute vec3 aNormal;
attribute vec3 aColor;
varying vec3 vNormal;
varying vec3 vColor;
void main() {
    vNormal = aNormal;
    vColor = aColor;
    gl_Position = uMvp * vec4(aPos, 1.0);
}
"""

private const val FS = """
precision mediump float;
uniform vec3 uLight;
varying vec3 vNormal;
varying vec3 vColor;
void main() {
    float d = max(dot(normalize(vNormal), uLight), 0.0);
    float l = 0.38 + 0.75 * d;
    gl_FragColor = vec4(vColor * l, 1.0);
}
"""

class CarRenderer(private val ctx: Context) : GLSurfaceView.Renderer {
    @Volatile var touching = false
    @Volatile var colorIndex = 0
    @Volatile var dragDelta = 0f

    private var builtColor = -1
    private var angle = 25f
    private var last = 0L
    private var program = 0
    private var aPos = 0
    private var aNormal = 0
    private var aColor = 0
    private var uMvp = 0
    private var uLight = 0
    private var buffer: FloatBuffer? = null
    private var count = 0
    private val proj = FloatArray(16)
    private val view = FloatArray(16)
    private val model = FloatArray(16)
    private val vp = FloatArray(16)
    private val mvp = FloatArray(16)

    // Modèle 3D chargé depuis assets/car.bin (carrosserie en premier)
    private var base: FloatArray? = null
    private var nBody = 0
    private var loaded = false

    private fun loadModel() {
        loaded = true
        try {
            val bytes = ctx.assets.open("car.bin").readBytes()
            val bb = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
            val nb = bb.int
            val no = bb.int
            val arr = FloatArray((nb + no) * 9)
            bb.asFloatBuffer().get(arr)
            base = arr
            nBody = nb
        } catch (e: Exception) {
            Log.w("CarView", "car.bin absent : voiture simple", e)
        }
    }

    private fun compile(type: Int, src: String): Int {
        val s = GLES20.glCreateShader(type)
        GLES20.glShaderSource(s, src)
        GLES20.glCompileShader(s)
        val ok = IntArray(1)
        GLES20.glGetShaderiv(s, GLES20.GL_COMPILE_STATUS, ok, 0)
        if (ok[0] == 0) Log.e("CarView", GLES20.glGetShaderInfoLog(s))
        return s
    }

    override fun onSurfaceCreated(gl: GL10?, config: EGLConfig?) {
        GLES20.glClearColor(0f, 0f, 0f, 0f)
        GLES20.glEnable(GLES20.GL_DEPTH_TEST)
        program = GLES20.glCreateProgram()
        GLES20.glAttachShader(program, compile(GLES20.GL_VERTEX_SHADER, VS))
        GLES20.glAttachShader(program, compile(GLES20.GL_FRAGMENT_SHADER, FS))
        GLES20.glLinkProgram(program)
        aPos = GLES20.glGetAttribLocation(program, "aPos")
        aNormal = GLES20.glGetAttribLocation(program, "aNormal")
        aColor = GLES20.glGetAttribLocation(program, "aColor")
        uMvp = GLES20.glGetUniformLocation(program, "uMvp")
        uLight = GLES20.glGetUniformLocation(program, "uLight")
        builtColor = -1
        last = SystemClock.uptimeMillis()
    }

    override fun onSurfaceChanged(gl: GL10?, w: Int, h: Int) {
        GLES20.glViewport(0, 0, w, h)
        val aspect = w.toFloat() / max(h, 1).toFloat()
        val fov = 32f
        Matrix.perspectiveM(proj, 0, fov, aspect, 0.5f, 60f)
        val halfH = tan(Math.toRadians((fov / 2f).toDouble())).toFloat()
        val dist = max(7f, 2.9f / (halfH * aspect))
        Matrix.setLookAtM(view, 0, 0f, dist * 0.30f, dist, 0f, 0.1f, 0f, 0f, 1f, 0f)
    }

    private fun rebuild() {
        val idx = colorIndex
        val col = PALETTE[idx % PALETTE.size]
        if (!loaded) loadModel()

        val arr: FloatArray
        val n: Int
        val b = base
        if (b != null) {
            val floor = MeshBuilder()
            floor.discY(2.9f, -0.08f, -0.005f, 48, floatArrayOf(0.13f, 0.17f, 0.40f))
            arr = FloatArray(b.size + floor.size)
            System.arraycopy(b, 0, arr, 0, b.size)
            System.arraycopy(floor.data, 0, arr, b.size, floor.size)
            for (i in 0 until nBody) {
                arr[i * 9 + 6] = col[0]
                arr[i * 9 + 7] = col[1]
                arr[i * 9 + 8] = col[2]
            }
            n = arr.size
        } else {
            val mb = buildCar(col)
            arr = mb.data
            n = mb.size
        }

        val fb = ByteBuffer.allocateDirect(n * 4).order(ByteOrder.nativeOrder()).asFloatBuffer()
        fb.put(arr, 0, n)
        fb.position(0)
        buffer = fb
        count = n / 9
        builtColor = idx
    }

    override fun onDrawFrame(gl: GL10?) {
        val now = SystemClock.uptimeMillis()
        val dt = ((now - last) / 1000f).coerceAtMost(0.1f)
        last = now
        angle += dragDelta
        dragDelta = 0f
        if (!touching) angle += 22f * dt
        angle %= 360f
        if (builtColor != colorIndex) rebuild()

        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT or GLES20.GL_DEPTH_BUFFER_BIT)
        val buf = buffer ?: return

        Matrix.setIdentityM(model, 0)
        Matrix.translateM(model, 0, 0f, -0.6f, 0f)
        Matrix.rotateM(model, 0, angle, 0f, 1f, 0f)
        Matrix.multiplyMM(vp, 0, proj, 0, view, 0)
        Matrix.multiplyMM(mvp, 0, vp, 0, model, 0)

        // Lumière fixe dans le monde, exprimée dans le repère de la voiture
        val rad = Math.toRadians(angle.toDouble())
        val c = cos(rad).toFloat()
        val s = sin(rad).toFloat()
        val lx = 0.40f
        val ly = 0.80f
        val lz = 0.45f

        GLES20.glUseProgram(program)
        GLES20.glUniformMatrix4fv(uMvp, 1, false, mvp, 0)
        GLES20.glUniform3f(uLight, lx * c - lz * s, ly, lx * s + lz * c)

        buf.position(0)
        GLES20.glVertexAttribPointer(aPos, 3, GLES20.GL_FLOAT, false, 36, buf)
        GLES20.glEnableVertexAttribArray(aPos)
        buf.position(3)
        GLES20.glVertexAttribPointer(aNormal, 3, GLES20.GL_FLOAT, false, 36, buf)
        GLES20.glEnableVertexAttribArray(aNormal)
        buf.position(6)
        GLES20.glVertexAttribPointer(aColor, 3, GLES20.GL_FLOAT, false, 36, buf)
        GLES20.glEnableVertexAttribArray(aColor)

        GLES20.glDrawArrays(GLES20.GL_TRIANGLES, 0, count)
    }
}

class CarView @JvmOverloads constructor(context: Context, attrs: AttributeSet? = null) :
    GLSurfaceView(context, attrs) {

    private val renderer = CarRenderer(context)
    private var downX = 0f
    private var lastX = 0f
    private var downT = 0L
    private var moved = false

    init {
        setEGLContextClientVersion(2)
        setEGLConfigChooser(8, 8, 8, 8, 16, 0)
        holder.setFormat(PixelFormat.TRANSLUCENT)
        setZOrderOnTop(true)
        setRenderer(renderer)
    }

    // Glisser = faire tourner ; toucher = changer la couleur
    override fun onTouchEvent(e: MotionEvent): Boolean {
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downX = e.x
                lastX = e.x
                downT = e.eventTime
                moved = false
                renderer.touching = true
            }
            MotionEvent.ACTION_MOVE -> {
                if (abs(e.x - downX) > 24f) moved = true
                renderer.dragDelta += (e.x - lastX) * 0.5f
                lastX = e.x
            }
            MotionEvent.ACTION_UP -> {
                renderer.touching = false
                if (!moved && e.eventTime - downT < 400) {
                    renderer.colorIndex = (renderer.colorIndex + 1) % PALETTE.size
                }
            }
            MotionEvent.ACTION_CANCEL -> renderer.touching = false
        }
        return true
    }
}
