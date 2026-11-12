package com.example.gtreader

import android.os.Build
import android.view.View
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformViewWrapper

/** 原书按视图选择纹理调度：滚动连续跟随运动，分页只响应内容变化。 */
object OriginalScrollDraw {
    internal fun wrapper(view: View?): PlatformViewWrapper? {
        var node = view
        while (node != null) {
            if (node is PlatformViewWrapper) return node
            node = node.parent as? View
        }
        return null
    }

    fun register(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, "gtreader/original_scroll_draw")
            .setMethodCallHandler { call, result ->
                if (call.method != "enable" && call.method != "enablePaged") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val id = call.argument<Int>("viewId")!!
                val view = engine.platformViewsController.getPlatformViewById(id)
                val target = wrapper(view)
                // 当前验证使用 ImageReader + 硬件画布；旧 Android 保留原管线。
                val enabled = Build.VERSION.SDK_INT >= 29 && target != null
                if (enabled) {
                    // 分页的运动由 Flutter 页图承担，不能让静止网页连续补画，
                    // 否则多余纹理会占用缓冲，并把等待带回主线程。
                    val scrolling = call.method == "enable"
                    target!!.setTextureDrawMode(if (scrolling) 3 else 2)
                    // WebView插件先调用super.onScrollChanged，保留它原有事件上报。
                    if (scrolling) {
                        PageCapture.findWebView(view)?.setOnScrollChangeListener { _, _, _, _, _ ->
                            target.scrollMotion()
                        }
                    }
                }
                result.success(enabled)
            }
    }
}
