package com.example.gtreader

import android.graphics.HardwareRenderer
import android.graphics.PixelFormat
import android.graphics.RenderNode
import android.media.ImageReader
import android.os.Build
import android.os.SystemClock
import android.view.View
import android.webkit.WebView
import androidx.annotation.RequiresApi
import com.pichillilorenzo.flutter_inappwebview_android.InAppWebViewFlutterPlugin
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** 在系统启动画面下完成首个 GPU 画面；不依赖窗口出帧，也不回读或保存像素。 */
object OriginalWebViewFirstDraw {
    fun prepare(engine: FlutterEngine, id: String, reply: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 29) {
            reply.success(mapOf("supported" to false))
            return
        }
        val plugin = engine.plugins.get(InAppWebViewFlutterPlugin::class.java)
            as? InAppWebViewFlutterPlugin
        val web = plugin?.headlessInAppWebViewManager?.webViews?.get(id)
            ?.flutterWebView?.webView
        if (web == null) {
            reply.error("not_ready", "预备网页已释放", null)
            return
        }
        val visibility = web.visibility
        var finished = false
        val timeout = Runnable {
            if (!finished) {
                finished = true
                web.visibility = visibility
                reply.error("draw_timeout", "预备网页绘制超时", null)
            }
        }
        // Headless 默认不可见，短暂允许它生成绘图指令；真正绘制只进下方离屏表面。
        web.visibility = View.VISIBLE
        web.postDelayed(timeout, 750)
        web.postVisualStateCallback(0, object : WebView.VisualStateCallback() {
            override fun onComplete(requestId: Long) {
                if (finished) return
                finished = true
                web.removeCallbacks(timeout)
                try {
                    reply.success(draw(web))
                } catch (error: RuntimeException) {
                    reply.error("draw", error.javaClass.simpleName, null)
                } finally {
                    web.visibility = visibility
                }
            }
        })
    }

    @RequiresApi(29)
    private fun draw(web: WebView): Map<String, Any> {
        val started = SystemClock.elapsedRealtimeNanos()
        val width = web.width.coerceAtLeast(1)
        val height = web.height.coerceAtLeast(1)
        val images = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 2)
        val node = RenderNode("gt-webview-first-draw")
        val renderer = HardwareRenderer()
        try {
            node.setPosition(0, 0, width, height)
            val canvas = node.beginRecording(width, height)
            try { web.draw(canvas) } finally { node.endRecording() }
            renderer.setSurface(images.surface)
            renderer.setContentRoot(node)
            val result = renderer.createRenderRequest().setWaitForPresent(true).syncAndDraw()
            // 只消费这一帧，不能让 ImageReader 的队列堵住共用的渲染线程。
            images.acquireLatestImage()?.close()
            return mapOf("supported" to true, "result" to result,
                "drawUs" to (SystemClock.elapsedRealtimeNanos() - started) / 1000)
        } finally {
            renderer.destroy()
            node.discardDisplayList()
            images.close()
        }
    }
}
