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

/** 系统栏等待现场独立落盘；Dart 没收到回调或应用重启后仍可导出。 */
object ReaderExitLog {
    private const val MAX_BYTES = 131072
    // 写入、轮换和导出按同一顺序执行，磁盘操作不占用 Android 界面线程。
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    private fun folder(context: Context) = File(context.filesDir, "diagnostics").apply {
        if (!isDirectory && !mkdirs()) error("Cannot create reader exit diagnostics")
    }

    fun append(context: Context, record: Map<String, Any?>) {
        val app = context.applicationContext
        val line = JSONObject(record).toString() + "\n"
        worker.execute {
            try {
                val root = folder(app)
                val current = File(root, "reader-exit-native.jsonl")
                val bytes = line.toByteArray(Charsets.UTF_8)
                if (current.length() + bytes.size > MAX_BYTES) {
                    val previous = File(root, "reader-exit-native.previous.jsonl")
                    if (previous.exists() && !previous.delete()) error("Cannot rotate previous exit log")
                    if (!current.renameTo(previous)) error("Cannot rotate exit log")
                }
                FileOutputStream(current, true).use { output ->
                    // 进程中断可能留下半行；新记录前加换行，导出时仍可辨认后续记录。
                    output.write('\n'.code)
                    output.write(bytes)
                    output.fd.sync()
                }
            } catch (error: Exception) {
                Log.w("GT_READER_EXIT", "Cannot save exit diagnostics", error)
            }
        }
    }

    fun export(context: Context, result: MethodChannel.Result) {
        val app = context.applicationContext
        worker.execute {
            try {
                val root = folder(app)
                val text = listOf("reader-exit-native.previous.jsonl", "reader-exit-native.jsonl")
                    .joinToString("") { name ->
                        File(root, name).let { if (it.exists()) it.readText(Charsets.UTF_8) else "" }
                    }
                main.post { result.success(text) }
            } catch (error: Exception) {
                main.post { result.error("exit-diagnostics", error.javaClass.simpleName, null) }
            }
        }
    }
}
