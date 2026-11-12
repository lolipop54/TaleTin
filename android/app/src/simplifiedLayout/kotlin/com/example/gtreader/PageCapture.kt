package com.example.gtreader

import android.content.Context
import android.util.Log
import android.view.View
import android.webkit.WebView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** 简化版保留阅读触摸诊断；不创建原书 WebView 或截图工作区。 */
@Suppress("UNUSED_PARAMETER")
object PageCapture {
    var traceInput = false
        private set

    fun register(context: Context, engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, "gtreader/page_capture")
            .setMethodCallHandler { call, result ->
                if (call.method == "setInputTracing") {
                    traceInput = call.arguments == true
                    Log.i("GT_TURN_NATIVE", "wall=${System.currentTimeMillis()} readerTrace=$traceInput")
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
    }

    fun setForeground(value: Boolean) = Unit
    fun release() = Unit
    fun findWebView(view: View?): WebView? = null
}
