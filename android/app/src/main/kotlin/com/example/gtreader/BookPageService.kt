package com.example.gtreader

import android.app.Service
import android.app.ActivityManager
import android.content.ComponentCallbacks2
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.Process
import android.webkit.WebView
import com.github.dart_lang.jni.JniPlugin
import com.github.dart_lang.jni_flutter.JniFlutterPlugin
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.webviewflutter.WebViewFlutterPlugin

/** 只在阅读器打开时启动。独立进程可以使用段落测量，又不会占住阅读窗口的线程。 */
class BookPageService : Service() {
    private val engines = mutableMapOf<String, FlutterEngine>()
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        // 服务可多次创建，WebView 的目录只能在本进程第一次初始化前设置。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P && !webViewDirectorySet) {
            WebView.setDataDirectorySuffix("pagination")
            webViewDirectorySet = true
        }
        Process.setThreadPriority(Process.THREAD_PRIORITY_BACKGROUND)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val ticket = intent?.getStringExtra("ticket") ?: return START_NOT_STICKY
        val engine = FlutterEngine(this, null, false)
        engines[ticket] = engine
        // 算页在独立进程，不能借用阅读窗口的 JNI 类加载器或应用上下文。
        engine.plugins.add(JniPlugin())
        engine.plugins.add(JniFlutterPlugin())
        ReadingFonts.register(applicationContext, engine)
        engine.plugins.add(WebViewFlutterPlugin())
        MethodChannel(engine.dartExecutor.binaryMessenger, channel).setMethodCallHandler { call, reply ->
            if (call.method == "finished") {
                reply.success(null)
                android.os.Handler(mainLooper).post {
                    engines.remove(ticket)?.destroy()
                    if (engines.isEmpty()) stopSelf()
                }
            } else reply.notImplemented()
        }
        val bundle = FlutterInjector.instance().flutterLoader().findAppBundlePath()
        val memory = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val info = ActivityManager.MemoryInfo().also(memory::getMemoryInfo)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint(bundle, "bookPageWorker"),
            listOf(intent.getIntExtra("port", 0).toString(), ticket,
                if (memory.isLowRamDevice || info.lowMemory) "serial" else "prefetch"))
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        engines.values.forEach { it.destroy() }
        engines.clear()
        super.onDestroy()
    }

    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        // 独立服务没有 Activity 替它转发内存告警。普通的退后台不代表内存不足。
        if (level == ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW ||
            level == ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL ||
            level >= ComponentCallbacks2.TRIM_MEMORY_MODERATE) {
            engines.values.forEach { it.systemChannel.sendMemoryPressureWarning() }
        }
    }

    companion object {
        private const val channel = "gtreader/book_pages"
        private var webViewDirectorySet = false
        fun register(context: Context, engine: FlutterEngine) {
            MethodChannel(engine.dartExecutor.binaryMessenger, channel).setMethodCallHandler { call, reply ->
                if (call.method == "start") {
                    try {
                        context.startService(Intent(context, BookPageService::class.java)
                            .putExtra("ticket", call.argument<String>("ticket"))
                            .putExtra("port", call.argument<Int>("port")!!))
                        reply.success(null)
                    } catch (e: IllegalStateException) {
                        reply.error("unavailable", e.message, null)
                    }
                } else reply.notImplemented()
            }
        }
    }
}
