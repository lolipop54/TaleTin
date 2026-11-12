package com.example.gtreader

import android.content.Context
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewOutcomeReceiver
import androidx.webkit.WebViewStartUpConfig
import androidx.webkit.WebViewStartUpResult
import androidx.webkit.WebViewStartupException
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/** 分开处理后台内核准备与静态启动画面下的首帧绘制。 */
object OriginalWebViewStartup {
    fun register(context: Context, engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, "gtreader/original-startup")
            .setMethodCallHandler { call, reply ->
                if (call.method == "drawPrepared") {
                    OriginalWebViewFirstDraw.prepare(engine, call.argument<String>("id")!!, reply)
                    return@setMethodCallHandler
                }
                if (call.method != "warmup") {
                    reply.notImplemented()
                    return@setMethodCallHandler
                }
                val executor = Executors.newSingleThreadExecutor()
                val config = WebViewStartUpConfig.Builder(executor)
                    .setShouldRunUiThreadStartUpTasks(false).build()
                try {
                    WebViewCompat.startUpWebView(context.applicationContext, config,
                        object : WebViewOutcomeReceiver<WebViewStartUpResult, WebViewStartupException> {
                            override fun onResult(result: WebViewStartUpResult) {
                                executor.shutdown()
                                reply.success(if (call.argument<Boolean>("trace") == true) mapOf(
                                    "strategy" to "background",
                                    "mainTotalMs" to result.totalTimeInUiThreadMillis,
                                    "mainMaxTaskMs" to result.maxTimePerTaskInUiThreadMillis,
                                ) else null)
                            }
                            override fun onError(error: WebViewStartupException) {
                                executor.shutdown()
                                reply.error("startup", error.message, null)
                            }
                        })
                } catch (error: RuntimeException) {
                    executor.shutdown()
                    reply.error("startup", error.message, null)
                }
            }
    }
}
