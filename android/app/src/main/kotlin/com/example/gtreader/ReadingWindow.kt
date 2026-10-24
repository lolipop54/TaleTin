package com.example.gtreader

import android.app.Activity
import android.view.WindowManager
import android.view.KeyEvent
import android.os.Build
import android.os.SystemClock
import android.util.Log
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.core.view.ViewCompat
import androidx.core.graphics.Insets
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** 只修改本应用窗口，不改变系统永久设置。 */
object ReadingWindow {
    private var volumeKeys = false
    private var channel: MethodChannel? = null
    private var barsRequest = 0L
    /** 无系统栏的设备没有可等待的可见状态；临时隐藏的栏仍有非零最大占位。 */
    private fun systemBarReady(insets: WindowInsetsCompat, type: Int): Boolean =
        insets.isVisible(type) || insets.getInsetsIgnoringVisibility(type) == Insets.NONE
    fun onKey(event: KeyEvent): Boolean {
        if (!volumeKeys || (event.keyCode != KeyEvent.KEYCODE_VOLUME_DOWN &&
            event.keyCode != KeyEvent.KEYCODE_VOLUME_UP)) return false
        // 长按不连翻；只处理首次按下，抬起也消费，避免同时改系统音量。
        if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
            channel?.invokeMethod("turn", event.keyCode == KeyEvent.KEYCODE_VOLUME_DOWN)
        }
        return true
    }
    fun pause() { volumeKeys = false }
    fun register(activity: Activity, engine: FlutterEngine) {
        ReaderRecoveryLog.register(activity, engine)
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, "gtreader/reading_window")
        channel!!.setMethodCallHandler { call, result ->
                val flag = WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
                when (call.method) {
                    "appInfo" -> {
                        @Suppress("DEPRECATION")
                        val info = activity.packageManager.getPackageInfo(activity.packageName, 0)
                        @Suppress("DEPRECATION")
                        val code = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
                        result.success(mapOf("version" to info.versionName, "build" to code,
                            "package" to activity.packageName))
                    }
                    "volumeKeys" -> { volumeKeys = call.arguments == true; result.success(null) }
                    "systemBars" -> {
                        val tracing = call.argument<Boolean>("trace") == true
                        val request = ++barsRequest
                        val started = SystemClock.uptimeMillis()
                        val diagnosticId = "${System.currentTimeMillis()}-$request"
                        val waitingForInsets = call.argument<Boolean>("waitForInsets") == true
                        fun save(event: String, details: Map<String, Any?> = emptyMap()) {
                            if (waitingForInsets) ReaderExitLog.append(activity, mapOf(
                                "kind" to "readerExitNative", "id" to diagnosticId,
                                "event" to event, "timeMs" to System.currentTimeMillis(),
                                "elapsedMs" to SystemClock.uptimeMillis() - started,
                                "requestedStatus" to (call.argument<Boolean>("status") != false),
                                "requestedNavigation" to (call.argument<Boolean>("navigation") != false),
                            ) + details)
                        }
                        fun trace(stage: String, detail: String = "") {
                            if (tracing) Log.i("GT_READER_EXIT", "wall=${System.currentTimeMillis()} request=$request stage=$stage elapsedMs=${SystemClock.uptimeMillis() - started} $detail")
                        }
                        trace("system-bars-request", "status=${call.argument<Boolean>("status")} navigation=${call.argument<Boolean>("navigation")} wait=${call.argument<Boolean>("waitForInsets")}")
                        save("begin")
                        // 隐藏状态栏不会自动解除挖孔区域限制。Android 9～14 的默认策略
                        // 会把整个窗口下移，留下系统绘制的黑边，Flutter 无法在其中画正文。
                        // 窗口始终允许铺满屏幕；系统栏显示时仍由 Flutter 的安全区避让。
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                            val cutoutMode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R)
                                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
                            else WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
                            val attributes = activity.window.attributes
                            if (attributes.layoutInDisplayCutoutMode != cutoutMode) {
                                attributes.layoutInDisplayCutoutMode = cutoutMode
                                activity.window.attributes = attributes
                            }
                        }
                        val controller = WindowCompat.getInsetsController(activity.window, activity.window.decorView)
                        controller.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                        val status = WindowInsetsCompat.Type.statusBars()
                        val navigation = WindowInsetsCompat.Type.navigationBars()
                        if (call.argument<Boolean>("status") != false) controller.show(status) else controller.hide(status)
                        if (call.argument<Boolean>("navigation") != false) controller.show(navigation) else controller.hide(navigation)
                        if (waitingForInsets) {
                            // 现有系统栏要等到可见；MuMu等没有导航栏的设备不可能报告它可见。
                            // 使用“不考虑隐藏”的占位区分不存在与暂时隐藏，仍等两帧布局稳定。
                            val decor = activity.window.decorView
                            var readyFrames = 0
                            var lastLoggedAt = 0L
                            var nextSnapshotMs = 2000L
                            val check = object : Runnable {
                                override fun run() {
                                    val insets = ViewCompat.getRootWindowInsets(decor)
                                    if (insets != null && systemBarReady(insets, status) &&
                                        systemBarReady(insets, navigation) && !decor.isLayoutRequested) {
                                        readyFrames++
                                    } else readyFrames = 0
                                    val elapsed = SystemClock.uptimeMillis() - started
                                    // 两秒首次保存，十秒补一次，之后每分钟一次；不逐帧写盘。
                                    if (elapsed >= nextSnapshotMs || readyFrames >= 2) {
                                        save(if (readyFrames >= 2) "end" else "waiting", mapOf(
                                            "insetsAvailable" to (insets != null),
                                            "statusVisible" to insets?.isVisible(status),
                                            "navigationVisible" to insets?.isVisible(navigation),
                                            "statusMax" to insets?.getInsetsIgnoringVisibility(status)?.toString(),
                                            "navigationMax" to insets?.getInsetsIgnoringVisibility(navigation)?.toString(),
                                            "statusCurrent" to insets?.getInsets(status)?.toString(),
                                            "navigationCurrent" to insets?.getInsets(navigation)?.toString(),
                                            "layoutRequested" to decor.isLayoutRequested,
                                            "readyFrames" to readyFrames,
                                            "attached" to decor.isAttachedToWindow,
                                            "focus" to decor.hasWindowFocus(),
                                            "finishing" to activity.isFinishing,
                                            "destroyed" to activity.isDestroyed,
                                            "orientation" to activity.resources.configuration.orientation,
                                            "windowWidth" to decor.width, "windowHeight" to decor.height,
                                        ))
                                        nextSnapshotMs = if (nextSnapshotMs == 2000L) 10000L else elapsed + 60000L
                                    }
                                    // 只观察原有等待，每秒最多一条；不补超时、不强制完成。
                                    if (tracing && (lastLoggedAt == 0L || SystemClock.uptimeMillis() - lastLoggedAt >= 1000L || readyFrames >= 2)) {
                                        lastLoggedAt = SystemClock.uptimeMillis()
                                        trace("system-bars-check", "statusVisible=${insets?.isVisible(status)} navigationVisible=${insets?.isVisible(navigation)} statusMax=${insets?.getInsetsIgnoringVisibility(status)} navigationMax=${insets?.getInsetsIgnoringVisibility(navigation)} layoutRequested=${decor.isLayoutRequested} readyFrames=$readyFrames attached=${decor.isAttachedToWindow} focus=${decor.hasWindowFocus()} finishing=${activity.isFinishing} destroyed=${activity.isDestroyed} statusTop=${insets?.getInsets(status)?.top} navigationBottom=${insets?.getInsets(navigation)?.bottom}")
                                    }
                                    if (readyFrames >= 2) {
                                        trace("system-bars-return")
                                        result.success(null)
                                    }
                                    else decor.postOnAnimation(this)
                                }
                            }
                            decor.postOnAnimation(check)
                        } else {
                            trace("system-bars-return", "wait=false")
                            result.success(null)
                        }
                    }
                    "hasVolumeKeys" -> result.success(volumeKeys)
                    "keepAwake" -> {
                        if (call.arguments == true) activity.window.addFlags(flag)
                        else activity.window.clearFlags(flag)
                        result.success(null)
                    }
                    "isAwake" -> result.success(activity.window.attributes.flags and flag != 0)
                    else -> result.notImplemented()
                }
            }
    }
}
