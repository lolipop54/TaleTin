package com.example.gtreader

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.PorterDuff
import android.view.View
import android.view.ViewGroup
import android.view.ViewTreeObserver
import android.webkit.WebView
import android.os.SystemClock
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer

/** 翻页截图直接传 RGBA 像素，避免在 Android 主线程压 PNG、在 Dart 再解码。 */
object PageCapture {
    private var readerInputTracing = false
    private var captureInputTracing = false
    val traceInput: Boolean get() = readerInputTracing || captureInputTracing
    // 三个章节宿主在主线程串行取图，共用一套原尺寸工作区，不按章节累积。
    private var bitmap: Bitmap? = null
    private var pixels: ByteBuffer? = null
    private var enabled = false
    private var foreground = true
    private var generation = 0

    fun release() {
        generation++
        bitmap?.recycle()
        bitmap = null
        pixels = null
    }

    fun setForeground(value: Boolean) {
        foreground = value
        if (!value) release()
    }

    fun register(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, "gtreader/page_capture")
            .setMethodCallHandler { call, result ->
                if (call.method == "setInputTracing") {
                    readerInputTracing = call.arguments == true
                    Log.i("GT_TURN_NATIVE", "wall=${System.currentTimeMillis()} readerTrace=$readerInputTracing")
                    result.success(null)
                    return@setMethodCallHandler
                }
                if (call.method == "setEnabled") {
                    enabled = call.arguments == true
                    if (!enabled) { captureInputTracing = false; release() }
                    result.success(null)
                    return@setMethodCallHandler
                }
                if (call.method != "capture" && call.method != "presented" && call.method != "stopFling") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val id = call.argument<Int>("viewId")!!
                val tracing = call.argument<Boolean>("trace") == true
                captureInputTracing = tracing || call.argument<Boolean>("traceInput") == true
                val started = if (tracing) SystemClock.elapsedRealtimeNanos() else 0L
                fun trace(stage: String) {
                    if (tracing) Log.i("GT_TURN_NATIVE", "wall=${System.currentTimeMillis()} web=$id op=${call.method} request=$started stage=$stage us=${(SystemClock.elapsedRealtimeNanos() - started) / 1000}")
                }
                trace("received")
                val web = findWebView(engine.platformViewsController.getPlatformViewById(id))
                if (web == null || web.width == 0 || web.height == 0) {
                    result.error("not_ready", "原书页面尚未就绪", null)
                    return@setMethodCallHandler
                }
                if (call.method == "stopFling") {
                    web.flingScroll(0, 0)
                    result.success(null)
                    return@setMethodCallHandler
                }
                val requestedGeneration = generation
                // DOM 切页完成后再画，替代多次 JS requestAnimationFrame 往返。
                web.postVisualStateCallback(0, object : WebView.VisualStateCallback() {
                    override fun onComplete(requestId: Long) {
                        trace("visual-ready")
                        if (!web.isAttachedToWindow) {
                            result.error("detached", "原书页面已关闭", null)
                            return
                        }
                        if (call.method == "presented") {
                            // JS 的 rAF 不代表平台视图已经显示。等目标 DOM 的实际绘制，
                            // 再过一帧才通知 Flutter 撤掉遮盖，避免露出旧纹理。
                            val observer = web.viewTreeObserver
                            val listener = object : ViewTreeObserver.OnDrawListener {
                                var completed = false
                                override fun onDraw() {
                                    if (completed) return
                                    completed = true
                                    trace("draw-ready")
                                    web.post {
                                        if (observer.isAlive) observer.removeOnDrawListener(this)
                                        web.postOnAnimation { trace("presented-return"); result.success(null) }
                                    }
                                }
                            }
                            observer.addOnDrawListener(listener)
                            web.invalidate()
                            return
                        }
                        // 退出阅读或退到后台后，晚到的绘制回调不能重新占用工作区。
                        if (!enabled || !foreground || requestedGeneration != generation) {
                            result.error("cancelled", "截图请求已结束", null)
                            return
                        }
                        try {
                            if (bitmap?.width != web.width || bitmap?.height != web.height) {
                                // 尺寸变化时先丢掉旧工作区，避免同时保留两套大图。
                                bitmap?.recycle()
                                bitmap = null
                                pixels = null
                                bitmap = Bitmap.createBitmap(web.width, web.height, Bitmap.Config.ARGB_8888)
                                pixels = ByteBuffer.allocate(bitmap!!.byteCount)
                                trace("allocated")
                            }
                            val output = bitmap!!
                            val buffer = pixels!!
                            val canvas = Canvas(output)
                            canvas.drawColor(Color.TRANSPARENT, PorterDuff.Mode.CLEAR)
                            canvas.translate(-web.scrollX.toFloat(), -web.scrollY.toFloat())
                            web.draw(canvas)
                            trace("bitmap-drawn")
                            buffer.rewind()
                            output.copyPixelsToBuffer(buffer)
                            trace("pixels-copied")
                            // MethodChannel 在 success 内同步编码复制 byte[]，下一次取图
                            // 才能复用它；不能把这一步异步派发到其它线程。
                            result.success(mapOf("width" to output.width, "height" to output.height,
                                "rowBytes" to output.rowBytes, "pixels" to buffer.array()))
                            trace("channel-encoded")
                        } catch (error: Exception) {
                            release()
                            result.error("capture_failed", error.message, null)
                        }
                    }
                })
            }
    }

    private fun findWebView(view: View?): WebView? {
        if (view is WebView) return view
        if (view is ViewGroup) {
            for (index in 0 until view.childCount) {
                findWebView(view.getChildAt(index))?.let { return it }
            }
        }
        return null
    }
}
