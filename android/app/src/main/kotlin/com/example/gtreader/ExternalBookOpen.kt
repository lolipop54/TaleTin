package com.example.gtreader

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.system.Os
import android.widget.Toast
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/** 外部打开在启动准备期间暂存；只由已就绪的 Dart 界面领取和确认。 */
object ExternalBookOpen {
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private var channel: MethodChannel? = null
    private var serial = 0L
    private var pending: Map<String, Any?>? = null
    private val extensions = setOf("txt", "epub", "mobi", "azw3", "pdf")
    val hasPending: Boolean get() = pending != null

    fun register(engine: FlutterEngine) {
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, "gtreader/external_book_open")
            .also { bridge ->
                bridge.setMethodCallHandler { call, result ->
                    when (call.method) {
                        "next" -> result.success(pending)
                        "complete" -> {
                            val current = pending?.get("id") == call.argument<Number>("id")?.toLong()
                            if (current) pending = null
                            result.success(current)
                        }
                        else -> result.notImplemented()
                    }
                }
            }
    }

    fun accept(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_VIEW) return
        val uri = intent.data ?: return
        if (uri.scheme != "content" && uri.scheme != "file") return
        val app = context.applicationContext
        // 新请求立即使旧请求的自动开书失效，慢文件查询也不能倒序覆盖。
        val id = ++serial
        pending = mapOf("id" to id, "loading" to true)
        if (uri.scheme == "content" &&
            intent.flags and Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION != 0) {
            try {
                app.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            } catch (_: SecurityException) {
                // ACTION_VIEW 通常只有临时授权；现有导入会分块保存私有原书。
            }
        }
        worker.execute {
            try {
                val document = describe(app, uri)
                main.post {
                    if (id != serial) return@post
                    pending = document + ("id" to id)
                    channel?.invokeMethod("changed", null)
                }
            } catch (error: Exception) {
                main.post {
                    if (id != serial) return@post
                    pending = null
                    Toast.makeText(app, error.message ?: "无法打开所选文件", Toast.LENGTH_LONG).show()
                }
            }
        }
    }

    private fun describe(context: Context, uri: Uri): Map<String, Any?> {
        var name = uri.lastPathSegment?.substringAfterLast('/') ?: "未命名文件"
        var size: Long? = null
        var dataPath: String? = null
        if (uri.scheme == "content") {
            // 不依赖提供方支持 _data；数字文档 URI 也能通过 DISPLAY_NAME 识别格式。
            try {
                context.contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        fun string(column: String): String? {
                            val index = cursor.getColumnIndex(column)
                            return if (index >= 0 && !cursor.isNull(index)) cursor.getString(index) else null
                        }
                        name = string(OpenableColumns.DISPLAY_NAME) ?: name
                        size = string(OpenableColumns.SIZE)?.toLongOrNull()
                        dataPath = string("_data")
                    }
                }
            } catch (_: UnsupportedOperationException) {
                // 少数提供方只支持读取流；文件名沿用 URI，大小由导入实际计数。
            }
        }
        require(name.substringAfterLast('.', "").lowercase() in extensions) {
            "仅支持 TXT、EPUB、MOBI、AZW3、PDF 文件"
        }
        val local = if (uri.scheme == "file") File(requireNotNull(uri.path)).canonicalFile
            else localFile(context, uri, dataPath)
        if (local != null) {
            require(local.isFile && local.canRead()) { "无法读取所选文件，请检查文件是否存在及访问权限" }
            name = local.name
            size = local.length()
        }
        return mapOf("uri" to (local?.let { Uri.fromFile(it).toString() } ?: uri.toString()),
            "name" to name, "sizeBytes" to size)
    }

    /** 仅将能够确认的共享存储路径转为 file URI，与应用内导入按同一路径查重。 */
    fun localFile(context: Context, uri: Uri, dataPath: String?): File? {
        val candidates = mutableListOf<String>()
        // FileProvider 的 URI 常用自定义根名，不能从 URI 字符串猜路径。
        // 文件描述符指向的真实共享文件可以与应用内导入准确对应；管道仍走 content 导入。
        try {
            context.contentResolver.openFileDescriptor(uri, "r")?.use { descriptor ->
                candidates.add(Os.readlink("/proc/self/fd/${descriptor.fd}"))
            }
        } catch (_: Exception) {
            // 有些文档提供方只支持流或资产描述符，继续使用其元数据及原 URI。
        }
        dataPath?.let(candidates::add)
        if (DocumentsContract.isDocumentUri(context, uri)) {
            val documentId = DocumentsContract.getDocumentId(uri)
            if (uri.authority == "com.android.externalstorage.documents") {
                val volume = documentId.substringBefore(':')
                val relative = documentId.substringAfter(':', "")
                val root = if (volume.equals("primary", true))
                    Environment.getExternalStorageDirectory() else File("/storage", volume)
                candidates.add(File(root, relative).path)
            } else if (uri.authority == "com.android.providers.downloads.documents" && documentId.startsWith("raw:")) {
                candidates.add(documentId.removePrefix("raw:"))
            }
        }
        return candidates.asSequence().map { File(it).canonicalFile }.firstOrNull {
            it.path.startsWith("/storage/") && it.isFile && it.canRead() &&
                it.extension.lowercase() in extensions
        }
    }
}
