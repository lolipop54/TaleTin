package com.example.gtreader

import android.content.Context
import android.widget.Toast
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** 使用应用上下文，避免后台听书保留引擎时连带持有旧 Activity。 */
object SystemToast {
    private var current: Toast? = null

    fun register(context: Context, engine: FlutterEngine) {
        val appContext = context.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, "gtreader/toast")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "show" -> {
                        current?.cancel()
                        current = Toast.makeText(appContext, call.arguments as String,
                            Toast.LENGTH_SHORT).also { it.show() }
                        result.success(null)
                    }
                    "cancel" -> {
                        current?.cancel()
                        current = null
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
