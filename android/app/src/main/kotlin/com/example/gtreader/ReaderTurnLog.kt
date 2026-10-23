package com.example.gtreader

import android.app.Activity
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.SystemClock
import android.view.FrameMetrics
import android.view.MotionEvent
import android.view.ViewTreeObserver
import android.view.Window
import android.webkit.WebView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.ArrayDeque
import java.util.concurrent.Executors

/** 手动复现的原生观察：不申请新绘制，不逐触点写盘；与真实异常分别轮换。 */
object ReaderTurnLog {
    private const val LIMIT = 3072
    private const val FILE_LIMIT = 16 * 1024 * 1024
    private val lock = Any()
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()
    private val sessions = linkedMapOf<String, Session>()
    private val recent = ArrayDeque<LongArray>()
    private var lastDown: LongArray? = null
    private var armed = false
    private var app: Context? = null
    private var engine: FlutterEngine? = null
    private var window: Window? = null
    private var metricsThread: HandlerThread? = null
    private var web: WebView? = null
    private var drawObserver: ViewTreeObserver? = null
    private var drawListener: ViewTreeObserver.OnDrawListener? = null
    private var lastTouchUs = 0L

    private class Rows {
        val values = ArrayList<LongArray>()
        var dropped = 0
        fun add(row: LongArray) {
            if (values.size < LIMIT) values.add(row) else dropped++
        }
        fun json() = JSONArray(values.map { JSONArray(it.toList()) })
    }

    private class Session(val id: String, var viewId: Int?, val downTimeMs: Long) {
        val beginUs = System.nanoTime() / 1000
        val uptimeUs = SystemClock.uptimeMillis() * 1000
        val bootUs = SystemClock.elapsedRealtimeNanos() / 1000
        val wallMs = System.currentTimeMillis()
        val touches = Rows()
        val draws = Rows()
        val frames = Rows()
        var endUs: Long? = null
        var status = "active"
        var webFound = false
        fun inWindow(at: Long) = at >= beginUs - 100000 &&
            (endUs == null || at <= endUs!! + 300000)
        fun json() = JSONObject().apply {
            put("kind", "readerTurnNative"); put("schema", 1); put("id", id)
            put("beginUs", beginUs); put("uptimeUs", uptimeUs)
            put("bootUs", bootUs); put("wallMs", wallMs)
            put("endUs", endUs); put("status", status)
            put("viewId", viewId); put("webFound", webFound)
            put("columns", JSONObject().apply {
                put("touches", JSONArray(listOf("receivedNanoUs", "eventUptimeMs", "action",
                    "downUptimeMs", "pointer", "xMilliPx", "yMilliPx", "historical")))
                put("draws", JSONArray(listOf("nanoUs", "scrollX", "scrollY", "width", "height")))
                put("frames", JSONArray(listOf("receivedNanoUs", "intendedVsyncNs", "vsyncNs",
                    "inputNs", "animationNs", "layoutNs", "drawNs", "syncNs", "commandsNs",
                    "swapNs", "totalNs", "gpuNs", "callbackDropped")))
            })
            put("touches", touches.json()); put("draws", draws.json()); put("frames", frames.json())
            put("dropped", JSONObject().apply {
                put("touches", touches.dropped); put("draws", draws.dropped); put("frames", frames.dropped)
            })
            put("note", "WebView OnDraw and MainActivity Window FrameMetrics are callbacks, not SurfaceFlinger presentation. Event time is uptime milliseconds; nano/uptime clock pair is retained.")
        }
    }

    private val frameListener = Window.OnFrameMetricsAvailableListener { _, metrics, dropped ->
        val at = System.nanoTime() / 1000
        val row = longArrayOf(at,
            metrics.getMetric(FrameMetrics.INTENDED_VSYNC_TIMESTAMP),
            metrics.getMetric(FrameMetrics.VSYNC_TIMESTAMP),
            metrics.getMetric(FrameMetrics.INPUT_HANDLING_DURATION),
            metrics.getMetric(FrameMetrics.ANIMATION_DURATION),
            metrics.getMetric(FrameMetrics.LAYOUT_MEASURE_DURATION),
            metrics.getMetric(FrameMetrics.DRAW_DURATION),
            metrics.getMetric(FrameMetrics.SYNC_DURATION),
            metrics.getMetric(FrameMetrics.COMMAND_ISSUE_DURATION),
            metrics.getMetric(FrameMetrics.SWAP_BUFFERS_DURATION),
            metrics.getMetric(FrameMetrics.TOTAL_DURATION),
            if (Build.VERSION.SDK_INT >= 31) metrics.getMetric(FrameMetrics.GPU_DURATION) else -1,
            dropped.toLong())
        synchronized(lock) {
            sessions.values.filter { it.inWindow(at) }.forEach { it.frames.add(row) }
        }
    }

    fun register(activity: Activity, flutterEngine: FlutterEngine) {
        app = activity.applicationContext
        engine = flutterEngine
        window = activity.window
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "gtreader/reader_turn_diagnostics")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "arm" -> { arm(call.arguments == true); result.success(null) }
                    "begin" -> {
                        if (armed) begin(call.argument<String>("id")!!, call.argument<Int>("viewId"))
                        result.success(null)
                    }
                    "bind" -> {
                        if (armed) {
                            val viewId = call.argument<Int>("viewId")
                            val currentWeb = observeView(viewId)
                            synchronized(lock) {
                                sessions[call.argument<String>("id")]?.apply {
                                    this.viewId = viewId
                                    webFound = currentWeb != null
                                }
                            }
                        }
                        result.success(null)
                    }
                    "finish" -> {
                        synchronized(lock) {
                            sessions[call.argument<String>("id")]?.apply {
                                endUs = System.nanoTime() / 1000
                                status = call.argument<String>("status") ?: "complete"
                            }
                        }
                        scheduleFlush()
                        result.success(null)
                    }
                    "append" -> {
                        val text = call.arguments as String
                        io.execute {
                            try {
                                write(app!!, "reader-turn", text)
                                main.post { result.success(null) }
                            } catch (error: Exception) {
                                main.post { result.error("turn_log", error.javaClass.simpleName, null) }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun arm(value: Boolean) {
        if (armed == value) return
        armed = value
        if (value) {
            metricsThread = HandlerThread("GT-TurnFrames").apply { start() }
            window?.addOnFrameMetricsAvailableListener(frameListener, Handler(metricsThread!!.looper))
        } else {
            window?.removeOnFrameMetricsAvailableListener(frameListener)
            metricsThread?.quitSafely(); metricsThread = null
            detachDraw()
            scheduleFlush()
        }
    }

    private fun observeView(viewId: Int?): WebView? {
        val view = viewId?.let { engine?.platformViewsController?.getPlatformViewById(it) }
        val currentWeb = PageCapture.findWebView(view)
        if (currentWeb !== web) {
            detachDraw()
            web = currentWeb
            currentWeb?.let { browser ->
                drawObserver = browser.viewTreeObserver
                drawListener = ViewTreeObserver.OnDrawListener {
                    val at = System.nanoTime() / 1000
                    val row = longArrayOf(at, browser.scrollX.toLong(), browser.scrollY.toLong(),
                        browser.width.toLong(), browser.height.toLong())
                    synchronized(lock) {
                        sessions.values.filter { it.viewId == viewId && it.inWindow(at) }
                            .forEach { it.draws.add(row) }
                    }
                }
                drawObserver!!.addOnDrawListener(drawListener)
            }
        }
        return currentWeb
    }

    private fun begin(id: String, viewId: Int?) {
        val currentWeb = observeView(viewId)
        synchronized(lock) {
            // Flutter收到按下后才发begin；保留原生已收到的按下及最初移动。
            val down = lastDown
            val downTime = down?.get(3) ?: -1
            val session = Session(id, viewId, downTime)
            session.webFound = currentWeb != null
            if (down != null && recent.none { it === down }) session.touches.add(down)
            recent.filter { it[3] == downTime }.forEach { session.touches.add(it) }
            if (sessions.size == 16) {
                val oldest = sessions.remove(sessions.keys.first())!!
                oldest.status = "bufferLimit"
                io.execute { saveNative(listOf(oldest)) }
            }
            sessions[id] = session
        }
    }

    fun touch(event: MotionEvent) {
        if (!armed) return
        val received = System.nanoTime() / 1000
        synchronized(lock) {
            lastTouchUs = received
            fun add(at: Long, x: Float, y: Float, historical: Long) {
                val row = longArrayOf(received, at, event.actionMasked.toLong(), event.downTime,
                    event.getPointerId(0).toLong(), (x * 1000).toLong(), (y * 1000).toLong(), historical)
                if (event.actionMasked == MotionEvent.ACTION_DOWN) lastDown = row
                recent.addLast(row)
                if (recent.size > 64) recent.removeFirst()
                sessions.values.filter { it.downTimeMs == event.downTime }
                    .forEach { it.touches.add(row) }
            }
            for (i in 0 until event.historySize) {
                add(event.getHistoricalEventTime(i), event.getHistoricalX(0, i), event.getHistoricalY(0, i), 1)
            }
            add(event.eventTime, event.x, event.y, 0)
        }
        if (event.actionMasked == MotionEvent.ACTION_UP || event.actionMasked == MotionEvent.ACTION_CANCEL) {
            scheduleFlush()
        }
    }

    private val flush = Runnable {
        if (System.nanoTime() / 1000 - lastTouchUs < 1200000) {
            scheduleFlush()
        } else {
            val ready = synchronized(lock) {
                sessions.values.filter { it.endUs != null }.toList().also { rows ->
                    rows.forEach { sessions.remove(it.id) }
                }
            }
            if (ready.isNotEmpty()) io.execute { saveNative(ready) }
        }
    }

    private fun scheduleFlush() {
        main.removeCallbacks(flush)
        main.postDelayed(flush, 1200)
    }

    private fun detachDraw() {
        if (drawObserver?.isAlive == true) drawListener?.let { drawObserver?.removeOnDrawListener(it) }
        drawObserver = null; drawListener = null; web = null
    }

    fun detach() {
        arm(false)
        synchronized(lock) {
            sessions.values.filter { it.endUs == null }.forEach {
                it.endUs = System.nanoTime() / 1000; it.status = "activityDestroyed"
            }
        }
        scheduleFlush()
        window = null
        engine = null
    }

    private fun folder(context: Context) = File(
        context.getExternalFilesDir(null) ?: context.filesDir, "diagnostics"
    ).apply { mkdirs() }

    private fun write(context: Context, name: String, text: String) {
        val dir = folder(context)
        val file = File(dir, "$name.jsonl")
        val bytes = (text + "\n").toByteArray(Charsets.UTF_8)
        if (file.length() + bytes.size > FILE_LIMIT) {
            val previous = File(dir, "$name.previous.jsonl")
            if (previous.exists()) previous.delete()
            if (file.exists() && !file.renameTo(previous)) throw java.io.IOException("log rotation")
        }
        // 上次进程中断可能留下半行，下一条不能直接拼接在残缺JSON上。
        if (file.exists() && file.length() > 0) {
            java.io.RandomAccessFile(file, "r").use {
                it.seek(it.length() - 1)
                if (it.read() != 10) file.appendText("\n")
            }
        }
        file.appendBytes(bytes)
    }

    private fun saveNative(ready: List<Session>) {
        val context = app ?: return
        try {
            ready.forEach { write(context, "reader-turn-native", it.json().toString()) }
        } catch (_: Exception) {
            // 诊断存储失败不改变手势和异常提示；导出时仍尝试读取已保存部分。
        }
    }

    fun export(context: Context, result: MethodChannel.Result) {
        val pending = synchronized(lock) { sessions.values.toList().also { sessions.clear() } }
        io.execute {
            saveNative(pending)
            try {
                val dir = folder(context)
                val text = listOf("reader-turn", "reader-turn-native").flatMap { name ->
                    listOf(File(dir, "$name.previous.jsonl"), File(dir, "$name.jsonl"))
                }.filter { it.exists() }.joinToString("\n") { it.readText() }
                main.post { result.success(text) }
            } catch (error: Exception) {
                main.post { result.error("turn_log", error.javaClass.simpleName, null) }
            }
        }
    }
}
