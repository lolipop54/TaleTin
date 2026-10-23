package com.example.gtreader

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import android.util.Log
import android.util.AtomicFile
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File

/** Dart 收不到进程已经崩溃的回调；保留原系统崩溃处理，下一次启动再交付原因。 */
object ErrorDiagnostics {
    private var installed = false
    private fun pending(context: Context) = File(context.filesDir, "pending-native-error.json")

    fun install(context: Context) {
        if (installed) return
        val app = context.applicationContext
        val previous = Thread.getDefaultUncaughtExceptionHandler() ?: return
        installed = true
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            try {
                val bytes = JSONObject().apply {
                    put("time", System.currentTimeMillis())
                    put("type", "AndroidCrash")
                    put("message", error.toString().take(4096))
                    put("stack", Log.getStackTraceString(error).take(24576))
                }.toString().toByteArray(Charsets.UTF_8)
                val atomic = AtomicFile(pending(app))
                val output = atomic.startWrite()
                try {
                    output.write(bytes)
                    atomic.finishWrite(output)
                } catch (failure: Exception) {
                    atomic.failWrite(output)
                    throw failure
                }
            } catch (failure: Exception) {
                Log.e("GT_APP_ERROR", "Cannot save native crash", failure)
            } finally {
                // 不吞掉原生崩溃，不在已经失效的主线程里强行显示 Toast。
                previous.uncaughtException(thread, error)
            }
        }
    }

    fun register(context: Context, engine: FlutterEngine) {
        val app = context.applicationContext
        install(app)
        MethodChannel(engine.dartExecutor.binaryMessenger, "gtreader/error_diagnostics")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "readerExitLog" -> ReaderExitLog.export(app, result)
                        "readerTurnLog" -> ReaderTurnLog.export(app, result)
                        "environment" -> {
                            val info = app.packageManager.getPackageInfo(app.packageName, 0)
                            result.success(mapOf(
                                "version" to info.versionName,
                                "build" to if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else {
                                    @Suppress("DEPRECATION")
                                    info.versionCode.toLong()
                                },
                                "brand" to Build.BRAND, "model" to Build.MODEL,
                                "android" to Build.VERSION.RELEASE,
                                "sdk" to Build.VERSION.SDK_INT,
                                "system" to Build.VERSION.INCREMENTAL,
                                "hardware" to Build.HARDWARE,
                                "abis" to Build.SUPPORTED_ABIS.joinToString(","),
                                "updatedAt" to info.lastUpdateTime,
                            ))
                        }
                        "previousFailure" -> result.success(previousFailure(app))
                        "acknowledgeFailure" -> {
                            val time = (call.arguments as Number).toLong()
                            app.getSharedPreferences("error_diagnostics", Context.MODE_PRIVATE)
                                .edit().putLong("seen", time).apply()
                            val file = pending(app)
                            if (file.exists() && JSONObject(file.readText()).getLong("time") <= time) file.delete()
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (error: Exception) {
                    result.error("diagnostics", error.message, null)
                }
            }
    }

    private fun previousFailure(context: Context): Map<String, Any?>? {
        val seen = context.getSharedPreferences("error_diagnostics", Context.MODE_PRIVATE)
            .getLong("seen", 0)
        val file = pending(context)
        if (file.exists()) {
            val value = JSONObject(file.readText())
            if (value.getLong("time") > seen) return mapOf(
                "time" to value.getLong("time"), "type" to value.getString("type"),
                "message" to value.getString("message"), "stack" to value.getString("stack"),
            )
        }
        if (Build.VERSION.SDK_INT < 30) return null
        val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        // 只看本应用主进程的最近一次退出，不能把历史崩溃套到后来的正常退出上。
        val exit = manager.getHistoricalProcessExitReasons(context.packageName, 0, 8)
            .firstOrNull { it.processName == context.packageName } ?: return null
        if (exit.timestamp <= seen || exit.reason !in setOf(
                ApplicationExitInfo.REASON_CRASH, ApplicationExitInfo.REASON_CRASH_NATIVE,
                ApplicationExitInfo.REASON_ANR, ApplicationExitInfo.REASON_INITIALIZATION_FAILURE,
            )) return null
        val firstInstall = context.packageManager.getPackageInfo(context.packageName, 0).firstInstallTime
        if (exit.timestamp < firstInstall) return null
        val type = when (exit.reason) {
            ApplicationExitInfo.REASON_ANR -> "AndroidANR"
            ApplicationExitInfo.REASON_CRASH_NATIVE -> "NativeCrash"
            ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "AndroidStartup"
            else -> "AndroidCrash"
        }
        // 原生 tombstone 是 protobuf，不能当成 UTF-8 堆栈文本写入导出文件。
        val stack = if (exit.reason == ApplicationExitInfo.REASON_CRASH_NATIVE) {
            "系统记录为原生进程崩溃；完整 native 堆栈需要设备系统报告。"
        } else try {
            exit.traceInputStream?.bufferedReader()?.use { reader ->
                val chars = CharArray(24576)
                val count = reader.read(chars)
                if (count > 0) String(chars, 0, count) else ""
            } ?: ""
        } catch (error: Exception) {
            "System trace unavailable: ${error.javaClass.simpleName}"
        }
        return mapOf("time" to exit.timestamp, "type" to type,
            "message" to (exit.description ?: type), "stack" to stack)
    }
}
