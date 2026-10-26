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
    private var multiple = false
    private var output: OutputStream? = null
    private var outputUri: Uri? = null

    init {
        MethodChannel(engine.dartExecutor.binaryMessenger, "gtreader/backup_documents")
            .setMethodCallHandler { call, result ->
                if (call.method == "pick" || call.method == "create" || call.method == "pickImage" || call.method == "pickImages") {
                    if (pending != null) {
                        result.error("busy", "文件选择器已经打开", null)
                    } else {
                        val create = call.method == "create"
                        multiple = call.method == "pickImages"
                        val limit = (call.argument<Int>("limit") ?: 1).coerceIn(1, 9)
                        // 封面走相册选择；备份读写仍使用文档选择器。
                        // 旧系统用相册选择入口，并向支持多选的相册传递多选请求。
                        val intent = if (call.method == "pickImage" || call.method == "pickImages") {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                                Intent(MediaStore.ACTION_PICK_IMAGES).apply {
                                    type = "image/*"
                                    if (multiple && limit > 1) putExtra(MediaStore.EXTRA_PICK_IMAGES_MAX, limit)
                                }
                            } else {
                                Intent(Intent.ACTION_PICK).apply {
                                    setDataAndType(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, "image/*")
                                    if (multiple && limit > 1) putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
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
        if (multiple) {
            val uris = linkedSetOf<String>()
            if (code == Activity.RESULT_OK) {
                data?.clipData?.let { clip ->
                    for (i in 0 until clip.itemCount) uris.add(clip.getItemAt(i).uri.toString())
                }
                data?.data?.let { uris.add(it.toString()) }
            }
            callback?.success(uris.toList())
        } else callback?.success(if (code == Activity.RESULT_OK) data?.data?.toString() else null)
        multiple = false
        return true
    }

    companion object { const val REQUEST = 0x6702 }
}
