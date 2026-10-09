package com.example.gtreader

import android.app.Activity
import android.view.WindowManager
import android.view.KeyEvent
import android.os.Build
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.core.view.ViewCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** 只修改本应用窗口，不改变系统永久设置。 */
object ReadingWindow {
    private var volumeKeys = false
    private var channel: MethodChannel? = null
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
                        val controller = WindowCompat.getInsetsController(activity.window, activity.window.decorView)
                        controller.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                        val status = WindowInsetsCompat.Type.statusBars()
                        val navigation = WindowInsetsCompat.Type.navigationBars()
                        if (call.argument<Boolean>("status") != false) controller.show(status) else controller.hide(status)
                        if (call.argument<Boolean>("navigation") != false) controller.show(navigation) else controller.hide(navigation)
                        if (call.argument<Boolean>("waitForInsets") == true) {
                            // show()只提交请求。等系统栏真实可见并经过两次绘制机会再返回Flutter。
                            val decor = activity.window.decorView
                            var readyFrames = 0
                            val check = object : Runnable {
                                override fun run() {
                                    val insets = ViewCompat.getRootWindowInsets(decor)
                                    if (insets?.isVisible(status or navigation) == true && !decor.isLayoutRequested) {
                                        readyFrames++
                                    } else readyFrames = 0
                                    if (readyFrames >= 2) result.success(null)
                                    else decor.postOnAnimation(this)
                                }
                            }
                            decor.postOnAnimation(check)
                        } else result.success(null)
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
