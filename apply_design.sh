#!/bin/bash
# Applique le nouveau design du lanceur (style CarPlay, carte GPS, voiture 3D plus naturelle)
# Lancé par le workflow après la génération du projet et la conversion du modèle 3D.
set -e

SRC=app/src/main
KT=$SRC/java/com/example/kialauncher
mkdir -p $KT $SRC/res/layout $SRC/res/drawable $SRC/res/values

############################################################
# Gradle : ajout de la carte OpenStreetMap (osmdroid)
############################################################
cat > app/build.gradle.kts <<'ENDOFFILE'
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}
android {
    namespace = "com.example.kialauncher"
    compileSdk = 34
    defaultConfig {
        applicationId = "com.example.kialauncher"
        minSdk = 26
        targetSdk = 33
        versionCode = 1
        versionName = "1.0"
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }
    kotlinOptions { jvmTarget = "1.8" }
}
dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("org.osmdroid:osmdroid-android:6.1.18")
}
ENDOFFILE

############################################################
# Manifest : permissions Internet et localisation
############################################################
cat > $SRC/AndroidManifest.xml <<'ENDOFFILE'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
    <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
    <queries>
        <intent>
            <action android:name="android.intent.action.MAIN" />
            <category android:name="android.intent.category.LAUNCHER" />
        </intent>
    </queries>
    <application
        android:label="@string/app_name"
        android:theme="@android:style/Theme.DeviceDefault.NoActionBar">
        <activity
            android:name=".MainActivity"
            android:exported="true"
            android:launchMode="singleTask"
            android:screenOrientation="landscape"
            android:stateNotNeeded="true"
            android:configChanges="orientation|screenSize|keyboardHidden">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.HOME" />
                <category android:name="android.intent.category.DEFAULT" />
            </intent-filter>
        </activity>
        <activity
            android:name=".AppsActivity"
            android:exported="false"
            android:screenOrientation="landscape" />
    </application>
</manifest>
ENDOFFILE

############################################################
# MainActivity : icônes, carte GPS, lecteur
############################################################
cat > $KT/MainActivity.kt <<'ENDOFFILE'
package com.example.kialauncher

import android.Manifest
import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ResolveInfo
import android.location.LocationManager
import android.media.AudioManager
import android.net.Uri
import android.os.Bundle
import android.view.KeyEvent
import android.view.View
import android.widget.Toast
import org.osmdroid.config.Configuration
import org.osmdroid.tileprovider.tilesource.XYTileSource
import org.osmdroid.util.GeoPoint
import org.osmdroid.views.CustomZoomButtonsController
import org.osmdroid.views.MapView
import org.osmdroid.views.overlay.mylocation.GpsMyLocationProvider
import org.osmdroid.views.overlay.mylocation.MyLocationNewOverlay
import java.io.File

fun Context.launchableApps(): List<ResolveInfo> {
    val i = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
    return packageManager.queryIntentActivities(i, 0)
        .filter { it.activityInfo.packageName != packageName }
        .sortedBy { it.loadLabel(packageManager).toString().lowercase() }
}

fun Context.launchPackage(pkg: String) {
    val i = packageManager.getLaunchIntentForPackage(pkg)
    if (i != null) startActivity(i)
    else Toast.makeText(this, "Application introuvable", Toast.LENGTH_SHORT).show()
}

class MainActivity : Activity() {
    private val prefs by lazy { getSharedPreferences("tiles", MODE_PRIVATE) }
    private var map: MapView? = null
    private var myLoc: MyLocationNewOverlay? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Configuration de la carte (cache dans le dossier de l'appli : pas de permission stockage)
        val cfg = Configuration.getInstance()
        cfg.load(this, getSharedPreferences("osmdroid", MODE_PRIVATE))
        cfg.setUserAgentValue("KiaLauncher/1.0 (autoradio Kia Rio; github.com/kakouhicheka-dev/KiaLauncher)")
        cfg.setOsmdroidBasePath(File(cacheDir, "osmdroid"))
        cfg.setOsmdroidTileCache(File(cacheDir, "osmdroid/tiles"))

        setContentView(R.layout.activity_main)

        val navDefault = { open(Intent(Intent.ACTION_VIEW, Uri.parse("geo:0,0?q="))) }
        bindTile(R.id.tile_nav, "nav", navDefault)
        bindTile(R.id.map_tap, "nav", navDefault)
        bindTile(R.id.tile_music, "music") { openMusic() }
        bindTile(R.id.card_music, "music") { openMusic() }
        bindTile(R.id.tile_phone, "phone") { open(Intent(Intent.ACTION_DIAL)) }
        bindTile(R.id.tile_radio, "radio") { toast("Appui long pour choisir l'application Radio") }

        findViewById<View>(R.id.tile_apps).setOnClickListener {
            startActivity(Intent(this, AppsActivity::class.java))
        }
        findViewById<View>(R.id.btn_prev).setOnClickListener { media(KeyEvent.KEYCODE_MEDIA_PREVIOUS) }
        findViewById<View>(R.id.btn_play).setOnClickListener { media(KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE) }
        findViewById<View>(R.id.btn_next).setOnClickListener { media(KeyEvent.KEYCODE_MEDIA_NEXT) }

        setupMap()
    }

    private fun setupMap() {
        val m = findViewById<MapView>(R.id.map)
        map = m
        // Fond de carte sombre (CARTO / OpenStreetMap), sans clé d'API
        m.setTileSource(
            XYTileSource(
                "CartoDark", 0, 19, 256, ".png",
                arrayOf(
                    "https://a.basemaps.cartocdn.com/dark_all/",
                    "https://b.basemaps.cartocdn.com/dark_all/",
                    "https://c.basemaps.cartocdn.com/dark_all/"
                )
            )
        )
        m.setMultiTouchControls(false)
        m.zoomController.setVisibility(CustomZoomButtonsController.Visibility.NEVER)
        m.setTilesScaledToDpi(true)
        m.controller.setZoom(17.0)
        if (checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED) {
            startLocation()
        } else {
            requestPermissions(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION), 42)
        }
    }

    private fun startLocation() {
        val m = map ?: return
        if (myLoc != null) return
        val ov = MyLocationNewOverlay(GpsMyLocationProvider(this), m)
        ov.enableMyLocation()
        ov.enableFollowLocation()
        m.overlays.add(ov)
        myLoc = ov
        try {
            val lm = getSystemService(Context.LOCATION_SERVICE) as LocationManager
            val last = lm.getLastKnownLocation(LocationManager.GPS_PROVIDER)
                ?: lm.getLastKnownLocation(LocationManager.NETWORK_PROVIDER)
            if (last != null) m.controller.setCenter(GeoPoint(last.latitude, last.longitude))
        } catch (e: Exception) {
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 42 && grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
            startLocation()
        }
    }

    override fun onResume() {
        super.onResume()
        findViewById<CarView>(R.id.car_view).onResume()
        map?.onResume()
        myLoc?.enableMyLocation()
        myLoc?.enableFollowLocation()
    }

    override fun onPause() {
        findViewById<CarView>(R.id.car_view).onPause()
        myLoc?.disableMyLocation()
        map?.onPause()
        super.onPause()
    }

    // Clic = action par défaut ou appli choisie ; appui long = choisir l'appli
    private fun bindTile(id: Int, key: String, default: () -> Unit) {
        val v = findViewById<View>(id)
        v.setOnClickListener {
            val pkg = prefs.getString(key, null)
            if (pkg != null) launchPackage(pkg) else default()
        }
        v.setOnLongClickListener { pickApp(key); true }
    }

    private fun pickApp(key: String) {
        val apps = launchableApps()
        val labels = apps.map { it.loadLabel(packageManager).toString() }.toTypedArray()
        AlertDialog.Builder(this)
            .setTitle("Choisir l'application")
            .setItems(labels) { _, which ->
                prefs.edit().putString(key, apps[which].activityInfo.packageName).apply()
            }.show()
    }

    private fun openMusic() =
        open(Intent.makeMainSelectorActivity(Intent.ACTION_MAIN, Intent.CATEGORY_APP_MUSIC))

    private fun open(intent: Intent) {
        try { startActivity(intent) } catch (e: Exception) { toast("Aucune application disponible") }
    }

    private fun media(code: Int) {
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        am.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, code))
        am.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_UP, code))
    }

    private fun toast(s: String) = Toast.makeText(this, s, Toast.LENGTH_SHORT).show()

    // Un launcher ne doit pas se fermer avec « Retour »
    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {}
}
ENDOFFILE

############################################################
# CarView : éclairage plus naturel (reflets, ciel, ombre, plateau lumineux, antialiasing)
############################################################
cat > $KT/CarView.kt <<'ENDOFFILE'
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
import javax.microedition.khronos.egl.EGL10
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.egl.EGLDisplay
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
uniform mat4 uVp;
uniform vec2 uCS;
attribute vec3 aPos;
attribute vec3 aNormal;
attribute vec3 aColor;
varying vec3 vNormal;
varying vec3 vColor;
varying vec3 vWorld;
varying vec3 vLocal;
void main() {
    float c = uCS.x;
    float s = uCS.y;
    vec3 p = vec3(c * aPos.x + s * aPos.z, aPos.y - 0.6, -s * aPos.x + c * aPos.z);
    vNormal = vec3(c * aNormal.x + s * aNormal.z, aNormal.y, -s * aNormal.x + c * aNormal.z);
    vColor = aColor;
    vWorld = p;
    vLocal = aPos;
    gl_Position = uVp * vec4(p, 1.0);
}
"""

private const val FS = """
#ifdef GL_FRAGMENT_PRECISION_HIGH
precision highp float;
#else
precision mediump float;
#endif
uniform vec3 uLight;
uniform vec3 uEye;
uniform float uSpec;
uniform float uEnv;
uniform float uFloor;
varying vec3 vNormal;
varying vec3 vColor;
varying vec3 vWorld;
varying vec3 vLocal;
void main() {
    if (uFloor > 0.5) {
        // Plateau : lueur centrale, ombre douce sous la voiture, liseré lumineux
        float r = length(vLocal.xz) / 2.7;
        float e = length(vec2(vLocal.x / 2.25, vLocal.z / 1.05));
        float shadow = smoothstep(1.25, 0.15, e);
        vec3 fc = vColor * (0.9 + 0.5 * (1.0 - r));
        fc = mix(fc, fc * 0.18, shadow * 0.85);
        fc += vec3(0.20, 0.42, 1.0) * smoothstep(0.80, 1.0, r) * 0.9;
        gl_FragColor = vec4(fc, 1.0);
        return;
    }
    vec3 N = normalize(vNormal);
    vec3 V = normalize(uEye - vWorld);
    vec3 L = normalize(uLight);
    float diff = max(dot(N, L), 0.0);
    float hemi = 0.5 + 0.5 * N.y;
    vec3 amb = mix(vec3(0.12, 0.13, 0.24), vec3(0.62, 0.68, 0.85), hemi);
    vec3 col = vColor * (amb * 0.80 + vec3(1.0, 0.96, 0.90) * diff * 0.80);
    vec3 H = normalize(L + V);
    float sp = pow(max(dot(N, H), 0.0), 70.0) * uSpec;
    vec3 R = reflect(-V, N);
    float fres = pow(1.0 - max(dot(N, V), 0.0), 3.0);
    float sky = smoothstep(-0.3, 0.9, R.y);
    col += vec3(0.70, 0.82, 1.0) * fres * sky * uEnv;
    col += vec3(1.0) * sp;
    gl_FragColor = vec4(col, 1.0);
}
"""

// Choix d'une configuration EGL avec antialiasing (4x, sinon 2x, sinon aucun)
private class AaChooser : GLSurfaceView.EGLConfigChooser {
    override fun chooseConfig(egl: EGL10, display: EGLDisplay): EGLConfig {
        for (samples in intArrayOf(4, 2, 0)) {
            val spec = intArrayOf(
                EGL10.EGL_RED_SIZE, 8,
                EGL10.EGL_GREEN_SIZE, 8,
                EGL10.EGL_BLUE_SIZE, 8,
                EGL10.EGL_ALPHA_SIZE, 8,
                EGL10.EGL_DEPTH_SIZE, 16,
                0x3040, 4, // EGL_RENDERABLE_TYPE = OpenGL ES 2
                EGL10.EGL_SAMPLE_BUFFERS, if (samples > 0) 1 else 0,
                EGL10.EGL_SAMPLES, samples,
                EGL10.EGL_NONE
            )
            val n = IntArray(1)
            egl.eglChooseConfig(display, spec, null, 0, n)
            if (n[0] > 0) {
                val cfgs = arrayOfNulls<EGLConfig>(n[0])
                egl.eglChooseConfig(display, spec, cfgs, n[0], n)
                val c = cfgs[0]
                if (c != null) return c
            }
        }
        throw IllegalStateException("Aucune configuration EGL")
    }
}

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
    private var uVp = 0
    private var uCS = 0
    private var uLight = 0
    private var uEye = 0
    private var uSpec = 0
    private var uEnv = 0
    private var uFloor = 0
    private var buffer: FloatBuffer? = null
    private var count = 0
    private var bodyCount = 0
    private var floorStart = 0
    private var eyeY = 1.4f
    private var eyeZ = 5f
    private val proj = FloatArray(16)
    private val view = FloatArray(16)
    private val vp = FloatArray(16)

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
        uVp = GLES20.glGetUniformLocation(program, "uVp")
        uCS = GLES20.glGetUniformLocation(program, "uCS")
        uLight = GLES20.glGetUniformLocation(program, "uLight")
        uEye = GLES20.glGetUniformLocation(program, "uEye")
        uSpec = GLES20.glGetUniformLocation(program, "uSpec")
        uEnv = GLES20.glGetUniformLocation(program, "uEnv")
        uFloor = GLES20.glGetUniformLocation(program, "uFloor")
        builtColor = -1
        last = SystemClock.uptimeMillis()
    }

    override fun onSurfaceChanged(gl: GL10?, w: Int, h: Int) {
        GLES20.glViewport(0, 0, w, h)
        val aspect = w.toFloat() / max(h, 1).toFloat()
        val fov = 32f
        Matrix.perspectiveM(proj, 0, fov, aspect, 0.5f, 60f)
        val halfH = tan(Math.toRadians((fov / 2f).toDouble())).toFloat()
        // Caméra plus proche : la voiture occupe davantage la carte
        val dist = max(5.0f, 2.7f / (halfH * aspect))
        eyeY = dist * 0.28f
        eyeZ = dist
        Matrix.setLookAtM(view, 0, 0f, eyeY, eyeZ, 0f, -0.15f, 0f, 0f, 1f, 0f)
        Matrix.multiplyMM(vp, 0, proj, 0, view, 0)
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
            floor.discY(2.7f, -0.08f, -0.005f, 64, floatArrayOf(0.13f, 0.17f, 0.40f))
            arr = FloatArray(b.size + floor.size)
            System.arraycopy(b, 0, arr, 0, b.size)
            System.arraycopy(floor.data, 0, arr, b.size, floor.size)
            for (i in 0 until nBody) {
                arr[i * 9 + 6] = col[0]
                arr[i * 9 + 7] = col[1]
                arr[i * 9 + 8] = col[2]
            }
            n = arr.size
            bodyCount = nBody
            floorStart = b.size / 9
        } else {
            val mb = buildCar(col)
            arr = mb.data
            n = mb.size
            bodyCount = 0
            floorStart = n / 9
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

        val rad = Math.toRadians(angle.toDouble())

        GLES20.glUseProgram(program)
        GLES20.glUniformMatrix4fv(uVp, 1, false, vp, 0)
        GLES20.glUniform2f(uCS, cos(rad).toFloat(), sin(rad).toFloat())
        // Lumière fixe dans le monde (haut, un peu de côté) ; position de la caméra pour les reflets
        GLES20.glUniform3f(uLight, -0.35f, 0.85f, 0.55f)
        GLES20.glUniform3f(uEye, 0f, eyeY, eyeZ)

        buf.position(0)
        GLES20.glVertexAttribPointer(aPos, 3, GLES20.GL_FLOAT, false, 36, buf)
        GLES20.glEnableVertexAttribArray(aPos)
        buf.position(3)
        GLES20.glVertexAttribPointer(aNormal, 3, GLES20.GL_FLOAT, false, 36, buf)
        GLES20.glEnableVertexAttribArray(aNormal)
        buf.position(6)
        GLES20.glVertexAttribPointer(aColor, 3, GLES20.GL_FLOAT, false, 36, buf)
        GLES20.glEnableVertexAttribArray(aColor)

        GLES20.glUniform1f(uFloor, 0f)
        // Carrosserie : peinture brillante avec reflet du ciel
        if (bodyCount > 0) {
            GLES20.glUniform1f(uSpec, 0.9f)
            GLES20.glUniform1f(uEnv, 0.55f)
            GLES20.glDrawArrays(GLES20.GL_TRIANGLES, 0, bodyCount)
        }
        // Vitres, roues, phares : reflets plus discrets
        GLES20.glUniform1f(uSpec, 0.35f)
        GLES20.glUniform1f(uEnv, 0.18f)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLES, bodyCount, floorStart - bodyCount)
        // Plateau
        if (floorStart < count) {
            GLES20.glUniform1f(uFloor, 1f)
            GLES20.glDrawArrays(GLES20.GL_TRIANGLES, floorStart, count - floorStart)
        }
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
        setEGLConfigChooser(AaChooser())
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
ENDOFFILE

############################################################
# Layout principal
############################################################
cat > $SRC/res/layout/activity_main.xml <<'ENDOFFILE'
<?xml version="1.0" encoding="utf-8"?>
<LinearLayout xmlns:android="http://schemas.android.com/apk/res/android"
    android:layout_width="match_parent"
    android:layout_height="match_parent"
    android:orientation="vertical"
    android:background="@drawable/bg_main"
    android:paddingLeft="20dp"
    android:paddingRight="20dp"
    android:paddingTop="10dp"
    android:paddingBottom="14dp">

    <!-- Barre du haut : heure et date -->
    <LinearLayout
        android:layout_width="match_parent"
        android:layout_height="52dp"
        android:orientation="horizontal"
        android:gravity="center_vertical"
        android:paddingLeft="6dp">

        <TextClock
            android:layout_width="wrap_content"
            android:layout_height="wrap_content"
            android:format24Hour="HH:mm"
            android:format12Hour="HH:mm"
            android:textColor="#FFFFFF"
            android:textSize="30sp"
            android:textStyle="bold" />

        <TextClock
            android:layout_width="wrap_content"
            android:layout_height="wrap_content"
            android:layout_marginLeft="16dp"
            android:format24Hour="EEEE d MMMM"
            android:format12Hour="EEEE d MMMM"
            android:textColor="#A5B4FC"
            android:textSize="16sp" />
    </LinearLayout>

    <LinearLayout
        android:layout_width="match_parent"
        android:layout_height="0dp"
        android:layout_weight="1"
        android:orientation="horizontal">

        <!-- Colonne d'icônes -->
        <LinearLayout
            android:layout_width="68dp"
            android:layout_height="match_parent"
            android:orientation="vertical">

            <ImageView
                android:id="@+id/tile_nav"
                android:layout_width="match_parent"
                android:layout_height="0dp"
                android:layout_weight="1"
                android:layout_margin="5dp"
                android:padding="14dp"
                android:scaleType="fitCenter"
                android:src="@drawable/ic_nav"
                android:background="@drawable/tile_nav"
                android:contentDescription="Navigation" />

            <ImageView
                android:id="@+id/tile_music"
                android:layout_width="match_parent"
                android:layout_height="0dp"
                android:layout_weight="1"
                android:layout_margin="5dp"
                android:padding="14dp"
                android:scaleType="fitCenter"
                android:src="@drawable/ic_music"
                android:background="@drawable/tile_music"
                android:contentDescription="Musique" />

            <ImageView
                android:id="@+id/tile_phone"
                android:layout_width="match_parent"
                android:layout_height="0dp"
                android:layout_weight="1"
                android:layout_margin="5dp"
                android:padding="14dp"
                android:scaleType="fitCenter"
                android:src="@drawable/ic_phone"
                android:background="@drawable/tile_phone"
                android:contentDescription="Téléphone" />

            <ImageView
                android:id="@+id/tile_radio"
                android:layout_width="match_parent"
                android:layout_height="0dp"
                android:layout_weight="1"
                android:layout_margin="5dp"
                android:padding="14dp"
                android:scaleType="fitCenter"
                android:src="@drawable/ic_radio"
                android:background="@drawable/tile_radio"
                android:contentDescription="Radio" />

            <ImageView
                android:id="@+id/tile_apps"
                android:layout_width="match_parent"
                android:layout_height="0dp"
                android:layout_weight="1"
                android:layout_margin="5dp"
                android:padding="14dp"
                android:scaleType="fitCenter"
                android:src="@drawable/ic_apps"
                android:background="@drawable/tile_apps"
                android:contentDescription="Applications" />
        </LinearLayout>

        <!-- Voiture 3D -->
        <LinearLayout
            android:layout_width="0dp"
            android:layout_height="match_parent"
            android:layout_weight="2.1"
            android:layout_margin="6dp"
            android:orientation="vertical"
            android:gravity="center_horizontal"
            android:paddingTop="18dp"
            android:paddingBottom="8dp"
            android:background="@drawable/card_car">

            <TextView
                android:layout_width="wrap_content"
                android:layout_height="wrap_content"
                android:text="Kia Rio 2019"
                android:textColor="#FFFFFF"
                android:textSize="26sp"
                android:textStyle="bold" />

            <TextView
                android:layout_width="wrap_content"
                android:layout_height="wrap_content"
                android:text="● Tout est fermé"
                android:textColor="#4ADE80"
                android:textSize="15sp" />

            <com.example.kialauncher.CarView
                android:id="@+id/car_view"
                android:layout_width="match_parent"
                android:layout_height="0dp"
                android:layout_weight="1" />
        </LinearLayout>

        <!-- Colonne de droite : GPS et lecteur -->
        <LinearLayout
            android:layout_width="0dp"
            android:layout_height="match_parent"
            android:layout_weight="1.15"
            android:orientation="vertical">

            <FrameLayout
                android:id="@+id/card_gps"
                android:layout_width="match_parent"
                android:layout_height="0dp"
                android:layout_weight="1.15"
                android:layout_margin="6dp"
                android:background="@drawable/card"
                android:clipToOutline="true">

                <org.osmdroid.views.MapView
                    android:id="@+id/map"
                    android:layout_width="match_parent"
                    android:layout_height="match_parent" />

                <View
                    android:id="@+id/map_tap"
                    android:layout_width="match_parent"
                    android:layout_height="match_parent" />

                <TextView
                    android:layout_width="wrap_content"
                    android:layout_height="wrap_content"
                    android:layout_gravity="top|start"
                    android:layout_margin="10dp"
                    android:paddingLeft="12dp"
                    android:paddingRight="12dp"
                    android:paddingTop="4dp"
                    android:paddingBottom="4dp"
                    android:text="Navigation"
                    android:textColor="#FFFFFF"
                    android:textSize="13sp"
                    android:background="@drawable/chip" />

                <TextView
                    android:layout_width="wrap_content"
                    android:layout_height="wrap_content"
                    android:layout_gravity="bottom|end"
                    android:layout_margin="6dp"
                    android:text="© OpenStreetMap © CARTO"
                    android:textColor="#99FFFFFF"
                    android:textSize="9sp" />
            </FrameLayout>

            <LinearLayout
                android:id="@+id/card_music"
                android:layout_width="match_parent"
                android:layout_height="0dp"
                android:layout_weight="1.1"
                android:layout_margin="6dp"
                android:orientation="vertical"
                android:gravity="center"
                android:padding="10dp"
                android:background="@drawable/card">

                <LinearLayout
                    android:layout_width="wrap_content"
                    android:layout_height="wrap_content"
                    android:orientation="horizontal"
                    android:gravity="center_vertical">

                    <ImageView
                        android:layout_width="22dp"
                        android:layout_height="22dp"
                        android:src="@drawable/ic_music"
                        android:tint="#FF5CAA" />

                    <TextView
                        android:layout_width="wrap_content"
                        android:layout_height="wrap_content"
                        android:layout_marginLeft="8dp"
                        android:text="Musique"
                        android:textColor="#FFFFFF"
                        android:textSize="20sp" />
                </LinearLayout>

                <LinearLayout
                    android:layout_width="wrap_content"
                    android:layout_height="wrap_content"
                    android:layout_marginTop="8dp"
                    android:orientation="horizontal"
                    android:gravity="center_vertical">

                    <ImageView
                        android:id="@+id/btn_prev"
                        android:layout_width="44dp"
                        android:layout_height="44dp"
                        android:padding="10dp"
                        android:src="@drawable/ic_prev"
                        android:contentDescription="Précédent" />

                    <ImageView
                        android:id="@+id/btn_play"
                        android:layout_width="48dp"
                        android:layout_height="48dp"
                        android:layout_marginLeft="6dp"
                        android:layout_marginRight="6dp"
                        android:padding="11dp"
                        android:src="@drawable/ic_play"
                        android:background="@drawable/btn_round"
                        android:contentDescription="Lecture / pause" />

                    <ImageView
                        android:id="@+id/btn_next"
                        android:layout_width="44dp"
                        android:layout_height="44dp"
                        android:padding="10dp"
                        android:src="@drawable/ic_next"
                        android:contentDescription="Suivant" />
                </LinearLayout>
            </LinearLayout>
        </LinearLayout>
    </LinearLayout>
</LinearLayout>
ENDOFFILE

############################################################
# Fonds et cartes
############################################################
cat > $SRC/res/drawable/bg_main.xml <<'ENDOFFILE'
<shape xmlns:android="http://schemas.android.com/apk/res/android" android:shape="rectangle">
    <gradient
        android:startColor="#060A24"
        android:centerColor="#0F1A55"
        android:endColor="#24348F"
        android:angle="315" />
</shape>
ENDOFFILE

cat > $SRC/res/drawable/card.xml <<'ENDOFFILE'
<shape xmlns:android="http://schemas.android.com/apk/res/android" android:shape="rectangle">
    <gradient android:startColor="#33FFFFFF" android:endColor="#14FFFFFF" android:angle="270" />
    <stroke android:width="1dp" android:color="#33FFFFFF" />
    <corners android:radius="26dp" />
</shape>
ENDOFFILE

cat > $SRC/res/drawable/card_car.xml <<'ENDOFFILE'
<shape xmlns:android="http://schemas.android.com/apk/res/android" android:shape="rectangle">
    <gradient
        android:type="radial"
        android:centerX="0.5"
        android:centerY="0.62"
        android:gradientRadius="70%p"
        android:startColor="#4A5BC4"
        android:endColor="#141B4D" />
    <stroke android:width="1dp" android:color="#33FFFFFF" />
    <corners android:radius="28dp" />
</shape>
ENDOFFILE

cat > $SRC/res/drawable/chip.xml <<'ENDOFFILE'
<shape xmlns:android="http://schemas.android.com/apk/res/android" android:shape="rectangle">
    <solid android:color="#99000000" />
    <corners android:radius="14dp" />
</shape>
ENDOFFILE

cat > $SRC/res/drawable/btn_round.xml <<'ENDOFFILE'
<shape xmlns:android="http://schemas.android.com/apk/res/android" android:shape="oval">
    <solid android:color="#33FFFFFF" />
    <stroke android:width="1dp" android:color="#55FFFFFF" />
</shape>
ENDOFFILE

############################################################
# Pastilles colorées des icônes (dégradés)
############################################################
cat > $SRC/res/drawable/tile_nav.xml <<'ENDOFFILE'
<shape xmlns:android="http://schemas.android.com/apk/res/android" android:shape="rectangle">
    <gradient android:startColor="#3D8BFF" android:endColor="#0B4FD8" android:angle="270" />
    <corners android:radius="22dp" />
</shape>
ENDOFFILE

cat > $SRC/res/drawable/tile_music.xml <<'ENDOFFILE'
<shape xmlns:android="http://schemas.android.com/apk/res/android" android:shape="rectangle">
    <gradient android:startColor="#FF5CAA" android:endColor="#D81E7C" android:angle="270" />
    <corners android:radius="22dp" />
</shape>
ENDOFFILE

cat > $SRC/res/drawable/tile_phone.xml <<'ENDOFFILE'
<shape xmlns:android="http://schemas.android.com/apk/res/android" android:shape="rectangle">
    <gradient android:startColor="#58E06E" android:endColor="#1FA83A" android:angle="270" />
    <corners android:radius="22dp" />
</shape>
ENDOFFILE

cat > $SRC/res/drawable/tile_radio.xml <<'ENDOFFILE'
<shape xmlns:android="http://schemas.android.com/apk/res/android" android:shape="rectangle">
    <gradient android:startColor="#FFB04A" android:endColor="#F26B1D" android:angle="270" />
    <corners android:radius="22dp" />
</shape>
ENDOFFILE

cat > $SRC/res/drawable/tile_apps.xml <<'ENDOFFILE'
<shape xmlns:android="http://schemas.android.com/apk/res/android" android:shape="rectangle">
    <gradient android:startColor="#66FFFFFF" android:endColor="#26FFFFFF" android:angle="270" />
    <stroke android:width="1dp" android:color="#44FFFFFF" />
    <corners android:radius="22dp" />
</shape>
ENDOFFILE

############################################################
# Pictogrammes (vectoriels, blancs)
############################################################
cat > $SRC/res/drawable/ic_nav.xml <<'ENDOFFILE'
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp" android:height="24dp"
    android:viewportWidth="24" android:viewportHeight="24">
    <path android:fillColor="#FFFFFFFF"
        android:pathData="M12,2L4.5,20.29l0.71,0.71L12,18l6.79,3 0.71,-0.71z" />
</vector>
ENDOFFILE

cat > $SRC/res/drawable/ic_music.xml <<'ENDOFFILE'
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp" android:height="24dp"
    android:viewportWidth="24" android:viewportHeight="24">
    <path android:fillColor="#FFFFFFFF"
        android:pathData="M12,3v10.55c-0.59,-0.34 -1.27,-0.55 -2,-0.55 -2.21,0 -4,1.79 -4,4s1.79,4 4,4 4,-1.79 4,-4V7h4V3h-6z" />
</vector>
ENDOFFILE

cat > $SRC/res/drawable/ic_phone.xml <<'ENDOFFILE'
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp" android:height="24dp"
    android:viewportWidth="24" android:viewportHeight="24">
    <path android:fillColor="#FFFFFFFF"
        android:pathData="M6.62,10.79c1.44,2.83 3.76,5.14 6.59,6.59l2.2,-2.2c0.27,-0.27 0.67,-0.36 1.02,-0.24 1.12,0.37 2.33,0.57 3.57,0.57 0.55,0 1,0.45 1,1V20c0,0.55 -0.45,1 -1,1 -9.39,0 -17,-7.61 -17,-17 0,-0.55 0.45,-1 1,-1h3.5c0.55,0 1,0.45 1,1 0,1.25 0.2,2.45 0.57,3.57 0.11,0.35 0.03,0.74 -0.25,1.02l-2.2,2.2z" />
</vector>
ENDOFFILE

cat > $SRC/res/drawable/ic_radio.xml <<'ENDOFFILE'
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp" android:height="24dp"
    android:viewportWidth="24" android:viewportHeight="24">
    <path android:fillColor="#FFFFFFFF"
        android:fillType="evenOdd"
        android:pathData="M3,8h18v12H3z M6,14a2.5,2.5 0 1,0 5,0a2.5,2.5 0 1,0 -5,0z M14,11h5v1.5h-5z M14,14h5v1.5h-5z M4,5.4l13.2,-3.3 0.5,1.7 -13.2,3.3z" />
</vector>
ENDOFFILE

cat > $SRC/res/drawable/ic_apps.xml <<'ENDOFFILE'
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp" android:height="24dp"
    android:viewportWidth="24" android:viewportHeight="24">
    <path android:fillColor="#FFFFFFFF"
        android:pathData="M4,4h7v7H4z M13,4h7v7h-7z M4,13h7v7H4z M13,13h7v7h-7z" />
</vector>
ENDOFFILE

cat > $SRC/res/drawable/ic_prev.xml <<'ENDOFFILE'
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp" android:height="24dp"
    android:viewportWidth="24" android:viewportHeight="24">
    <path android:fillColor="#FFFFFFFF"
        android:pathData="M6,6h2v12H6z M9.5,12l8.5,6V6z" />
</vector>
ENDOFFILE

cat > $SRC/res/drawable/ic_play.xml <<'ENDOFFILE'
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp" android:height="24dp"
    android:viewportWidth="24" android:viewportHeight="24">
    <path android:fillColor="#FFFFFFFF"
        android:pathData="M8,5v14l11,-7z" />
</vector>
ENDOFFILE

cat > $SRC/res/drawable/ic_next.xml <<'ENDOFFILE'
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp" android:height="24dp"
    android:viewportWidth="24" android:viewportHeight="24">
    <path android:fillColor="#FFFFFFFF"
        android:pathData="M16,6h2v12h-2z M6,18l8.5,-6L6,6z" />
</vector>
ENDOFFILE

echo "Design appliqué."
