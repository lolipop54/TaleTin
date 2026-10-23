package com.example.gtreader

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import android.provider.MediaStore
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.OutputStream
import java.util.concurrent.Executors

/** SAF 导出单独串行执行 IO；不在主线程写大文件，不取得整个存储的权限。 */
class BackupDocuments(private val activity: Activity, engine: FlutterEngine) {
    private val io = Executors.newSingleThreadExecutor()
    private var pending: MethodChannel.Result? = null
    private var output: OutputStream? = null
    private var outputUri: Uri? = null

    init {
        MethodChannel(engine.dartExecutor.binaryMessenger, "gtreader/backup_documents")
            .setMethodCallHandler { call, result ->
                if (call.method == "pick" || call.method == "create" || call.method == "pickImage") {
                    if (pending != null) {
                        result.error("busy", "文件选择器已经打开", null)
                    } else {
                        val create = call.method == "create"
                        // 封面走相册选择；备份读写仍使用文档选择器。
                        // 旧系统没有 Photo Picker 时用相册的单图选择，不退回文件管理器。
                        val intent = if (call.method == "pickImage") {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                                Intent(MediaStore.ACTION_PICK_IMAGES).apply { type = "image/*" }
                            } else {
                                Intent(Intent.ACTION_PICK).apply {
                                    setDataAndType(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, "image/*")
                                }
                            }
                        } else Intent(if (create) Intent.ACTION_CREATE_DOCUMENT else Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = call.argument<String>("mime") ?: "*/*"
                            if (create) putExtra(Intent.EXTRA_TITLE, call.argument<String>("name"))
                        }
                        pending = result
                        try {
                            activity.startActivityForResult(intent, REQUEST)
                        } catch (error: Exception) {
                            pending = null
                            result.error("picker", error.message, null)
                        }
                    }
                } else io.execute {
                    try {
                        val value: Any? = when (call.method) {
                            "open" -> {
                                check(output == null) { "还有未关闭的导出文件" }
                                val uri = Uri.parse(call.argument<String>("uri")!!)
                                output = activity.contentResolver.openOutputStream(uri, "wt")
                                    ?: error("无法打开导出文件")
                                outputUri = uri
                                null
                            }
                            "write" -> {
                                val bytes = call.argument<ByteArray>("bytes")!!
                                require(bytes.size <= 1024 * 1024) { "写入块超过 1 MiB" }
                                (output ?: error("导出文件未打开")).write(bytes)
                                null
                            }
                            "finish" -> {
                                // close 可能报告存储已满，不能先回复成功。
                                val stream = output ?: error("导出文件未打开")
                                try { stream.flush() } finally {
                                    try { stream.close() } finally { output = null }
                                }
                                outputUri = null
                                null
                            }
                            "abort" -> {
                                // 即使提供方在关闭时报告空间不足，也继续尝试删除半成品。
                                try { output?.close() } catch (_: Exception) { } finally { output = null }
                                val uri = outputUri ?: call.argument<String>("uri")?.let(Uri::parse)
                                outputUri = null
                                if (uri == null) true else DocumentsContract.deleteDocument(activity.contentResolver, uri)
                            }
                            else -> throw IllegalArgumentException("未知文档操作")
                        }
                        activity.runOnUiThread { result.success(value) }
                    } catch (error: Exception) {
                        activity.runOnUiThread { result.error("document_io", error.message, null) }
                    }
                }
            }
    }

    fun onResult(request: Int, code: Int, data: Intent?): Boolean {
        if (request != REQUEST) return false
        val callback = pending
        pending = null
        callback?.success(if (code == Activity.RESULT_OK) data?.data?.toString() else null)
        return true
    }

    companion object { const val REQUEST = 0x6702 }
}
