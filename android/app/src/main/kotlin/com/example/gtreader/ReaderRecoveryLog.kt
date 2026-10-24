package com.example.gtreader

import android.app.Activity
import android.view.ViewTreeObserver
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** 只观察已有布局和焦点回调；不替换Insets监听、不请求布局、不修改窗口。 */
object ReaderRecoveryLog {
    fun register(activity: Activity, engine: FlutterEngine) {
        val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "gtreader/reader_recovery")
        val decor = activity.window.decorView
        var watching = false
        var remaining = 0
        var previous: Map<String, Any?>? = null
        fun snapshot(reason: String, force: Boolean = false) {
            if (!watching || remaining <= 0) return
            val insets = ViewCompat.getRootWindowInsets(decor)
            fun edge(type: Int): List<Int>? = insets?.getInsets(type)?.let {
                listOf(it.left, it.top, it.right, it.bottom)
            }
            val xy = IntArray(2)
            decor.getLocationOnScreen(xy)
            val data = mapOf<String, Any?>(
                "windowWidth" to decor.width, "windowHeight" to decor.height,
                "windowX" to xy[0], "windowY" to xy[1],
                "focus" to decor.hasWindowFocus(), "attached" to decor.isAttachedToWindow,
                "layoutRequested" to decor.isLayoutRequested,
                "cutoutMode" to if (android.os.Build.VERSION.SDK_INT >= 28)
                    activity.window.attributes.layoutInDisplayCutoutMode else null,
                "orientation" to activity.resources.configuration.orientation,
                "statusVisible" to insets?.isVisible(WindowInsetsCompat.Type.statusBars()),
                "navigationVisible" to insets?.isVisible(WindowInsetsCompat.Type.navigationBars()),
                "statusInsets" to edge(WindowInsetsCompat.Type.statusBars()),
                "navigationInsets" to edge(WindowInsetsCompat.Type.navigationBars()),
                "cutoutInsets" to edge(WindowInsetsCompat.Type.displayCutout()),
                "imeInsets" to edge(WindowInsetsCompat.Type.ime()),
            )
            if (!force && previous == data) return
            previous = data
            remaining--
            channel.invokeMethod("native", data + mapOf(
                "reason" to reason, "wallMs" to System.currentTimeMillis(),
                "uptimeMs" to android.os.SystemClock.uptimeMillis()))
        }
        val layout = ViewTreeObserver.OnGlobalLayoutListener { snapshot("layout") }
        val focus = ViewTreeObserver.OnWindowFocusChangeListener { snapshot("focus", true) }
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "watch" -> {
                    val enabled = call.arguments == true
                    remaining = if (enabled) 2000 else 0
                    if (enabled != watching) {
                        watching = enabled
                        if (enabled) {
                            decor.viewTreeObserver.addOnGlobalLayoutListener(layout)
                            decor.viewTreeObserver.addOnWindowFocusChangeListener(focus)
                        } else if (decor.viewTreeObserver.isAlive) {
                            decor.viewTreeObserver.removeOnGlobalLayoutListener(layout)
                            decor.viewTreeObserver.removeOnWindowFocusChangeListener(focus)
                        }
                    }
                    snapshot("watch", true)
                    result.success(null)
                }
                "snapshot" -> {
                    snapshot(call.arguments as? String ?: "request", true)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
