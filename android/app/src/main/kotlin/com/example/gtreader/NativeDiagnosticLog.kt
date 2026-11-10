package com.example.gtreader

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.Executors

/** 每类记录独立轮换；即使 Dart 未响应，Android 仍能保存现场。 */
internal class NativeDiagnosticLog(private val name: String, private val tag: String) {
    companion object {
        val readerExit = NativeDiagnosticLog("reader-exit-native", "GT_READER_EXIT")
        val appResume = NativeDiagnosticLog("app-resume", "GT_APP_RESUME")
        private const val MAX_BYTES = 131072
        // 写入、轮换和导出按同一顺序执行，磁盘操作不占用 Android 界面线程。
        private val worker = Executors.newSingleThreadExecutor()
        private val main = Handler(Looper.getMainLooper())
    }

    private fun folder(context: Context) = File(context.filesDir, "diagnostics").apply {
        if (!isDirectory && !mkdirs()) error("Cannot create diagnostics directory")
    }

    fun append(context: Context, record: Map<String, Any?>) {
        val app = context.applicationContext
        val line = JSONObject(record).toString() + "\n"
        worker.execute {
            try {
                val root = folder(app)
                val current = File(root, "$name.jsonl")
                val bytes = line.toByteArray(Charsets.UTF_8)
                if (current.length() + bytes.size + 1 > MAX_BYTES) {
                    val previous = File(root, "$name.previous.jsonl")
                    if (previous.exists() && !previous.delete()) error("Cannot remove previous log")
                    if (!current.renameTo(previous)) error("Cannot rotate log")
                }
                FileOutputStream(current, true).use { output ->
                    // 进程中断可能留下半行；新记录前加换行，导出时仍可辨认后续记录。
                    output.write('\n'.code)
                    output.write(bytes)
                    output.fd.sync()
                }
            } catch (error: Exception) {
                Log.w(tag, "Cannot save diagnostics", error)
            }
        }
    }

    fun export(context: Context, result: MethodChannel.Result) {
        val app = context.applicationContext
        worker.execute {
            try {
                val root = folder(app)
                val text = listOf("$name.previous.jsonl", "$name.jsonl")
                    .joinToString("") { name ->
                        File(root, name).let { if (it.exists()) it.readText(Charsets.UTF_8) else "" }
                    }
                main.post { result.success(text) }
            } catch (error: Exception) {
                main.post { result.error("diagnostics", error.javaClass.simpleName, null) }
            }
        }
    }
}
