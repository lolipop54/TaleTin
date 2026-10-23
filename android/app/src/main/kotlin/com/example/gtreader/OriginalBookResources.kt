package com.example.gtreader

import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.SystemClock
import android.system.Os
import android.system.OsConstants
import android.util.Log
import android.webkit.WebResourceResponse
import com.pichillilorenzo.flutter_inappwebview_android.types.LocalResourceInterceptor
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayInputStream
import java.io.File
import java.io.FileInputStream
import java.util.concurrent.ConcurrentHashMap

/** 浏览器资源线程直接读同一份已准备文件；不建立第二套图片缓存。 */
object OriginalBookResources {
    private data class Binding(
        val session: String, val prefix: String, val source: File, val stamp: String,
        val imported: File, val cached: File, val shared: File?, val types: Map<String, String>,
        val chapters: Set<String>, val injection: String?, val trace: Boolean,
    )
    private val bindings = ConcurrentHashMap<String, Binding>()

    fun register(context: Context, engine: FlutterEngine) {
        LocalResourceInterceptor.handler = LocalResourceInterceptor.Handler { viewId, request ->
            intercept(viewId.toString(), Uri.parse(request.url))
        }
        val messenger = engine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "gtreader/original_resources",
            io.flutter.plugin.common.StandardMethodCodec.INSTANCE,
            messenger.makeBackgroundTaskQueue()).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "bind" -> {
                        // 旧系统保留Dart核验路径，不用秒级属性代替精确来源证明。
                        if (Build.VERSION.SDK_INT >= 27) bind(context, call.arguments as Map<*, *>)
                        result.success(null)
                    }
                    "unbind" -> { bindings.remove(call.argument<String>("view")); result.success(null) }
                    "close" -> {
                        val session = call.argument<String>("session")
                        bindings.entries.removeAll { it.value.session == session }
                        result.success(null)
                    }
                    "audit" -> {
                        // 仅登记为诊断的会话允许核对；性能轮不执行第二次文件读取。
                        val view = call.argument<String>("view")!!
                        val response = if (bindings[view]?.trace == true)
                            intercept(view, Uri.parse(call.argument<String>("url")!!)) else null
                        val bytes = response?.data?.use { it.readBytes() }
                        result.success(if (bytes == null) null else mapOf(
                            "sha256" to java.security.MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) },
                            "bytes" to bytes.size, "type" to response.mimeType,
                            "html" to if (response.mimeType == "text/html") String(bytes,Charsets.UTF_8) else null))
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                // 可选快路径登记失败不阻断原资源回调。
                if (call.argument<Boolean>("trace") == true) Log.i("GT_ORIGINAL_RESOURCE", "bind-fallback type=${error.javaClass.simpleName}")
                result.success(null)
            }
        }
    }

    private fun stamp(file: File, trace: Boolean = false): String? {
        if (Build.VERSION.SDK_INT < 27) return null
        return try {
            // Android的java.nio在此设备把时间截成整秒；Os.stat保留纳秒部分。
            val stat = Os.stat(file.path)
            if (!OsConstants.S_ISREG(stat.st_mode)) null else
                "${stat.st_size}:${stat.st_mtim.tv_sec * 1_000_000 + stat.st_mtim.tv_nsec / 1000}:${stat.st_ctim.tv_sec * 1_000_000 + stat.st_ctim.tv_nsec / 1000}"
        } catch (error: Exception) {
            if (trace) Log.i("GT_ORIGINAL_RESOURCE", "stat-fallback type=${error.javaClass.simpleName}")
            null
        }
    }

    private fun bind(context: Context, args: Map<*, *>) {
        val view = args["view"] as String
        bindings.remove(view)
        val proof = args["proof"] as Map<*, *>
        val source = File(proof["source"] as String)
        val expected = "${proof["bytes"]}:${proof["modifiedUs"]}:${proof["changedUs"]}"
        val actual = stamp(source, args["trace"] == true)
        if (actual != expected) {
            if (args["trace"] == true) Log.i("GT_ORIGINAL_RESOURCE", "proof-fallback expected=$expected actual=$actual readable=${source.canRead()}")
            return
        }
        val imported = File(proof["imported"] as String).canonicalFile
        val cached = File(proof["cached"] as String).canonicalFile
        val shared = (proof["shared"] as? String)?.let { File(it).canonicalFile }
        // 只接受本应用持有的正文/缓存目录，不提供任意本地文件服务。
        val roots = listOf(context.dataDir.canonicalFile, context.getExternalFilesDir(null)?.canonicalFile)
        require(roots.filterNotNull().any { imported.path.startsWith(it.path + File.separator) })
        require(roots.filterNotNull().any { cached.path.startsWith(it.path + File.separator) })
        require(shared == null || roots.filterNotNull().any { shared.path.startsWith(it.path + File.separator) })
        @Suppress("UNCHECKED_CAST") val types = proof["types"] as Map<String, String>
        val binding = Binding(args["session"] as String, args["prefix"] as String, source,
            expected, imported, cached, shared, types, (proof["chapters"] as List<*>).filterIsInstance<String>().toSet(),
            args["injection"] as String?, args["trace"] == true)
        bindings[view] = binding
        if (binding.trace) Log.i("GT_ORIGINAL_RESOURCE", "bound view=$view entries=${types.size}")
    }

    private fun intercept(view: String, uri: Uri): WebResourceResponse? {
        val binding = bindings[view] ?: return null
        if (uri.scheme != "https" || uri.host != "gtbook.internal") return null
        val path = uri.pathSegments.joinToString("/", prefix = "/")
        if (!path.startsWith(binding.prefix)) return null
        val entry = path.substring(binding.prefix.length)
        val type = binding.types[entry] ?: return null
        val start = if (binding.trace) SystemClock.elapsedRealtimeNanos() else 0L
        try {
            if (stamp(binding.source) != binding.stamp) {
                bindings.remove(view, binding)
                return null // 由Dart原路径发现来源变化并驱动原有更新流程。
            }
            fun existing(root: File, child: String): File? {
                val file = File(root, child).canonicalFile
                return file.takeIf { it.path.startsWith(root.path + File.separator) &&
                    it.isFile && it.length() <= 50L * 1024 * 1024 }
            }
            val file = existing(binding.imported, "res/$entry") ?: existing(binding.cached, entry)
                ?: binding.shared?.let { existing(it, entry) } ?: return null
            val stream = FileInputStream(file)
            if (stamp(binding.source) != binding.stamp) { stream.close(); return null }
            val chapter = entry in binding.chapters
            val response = if (chapter && binding.injection != null) {
                val html = stream.use { String(it.readBytes(), Charsets.UTF_8) }
                val slot = uri.getQueryParameter("gtSlot")?.toIntOrNull()
                val load = uri.getQueryParameter("gtLoad")?.toIntOrNull()
                val ordinal = uri.getQueryParameter("gtChapter")?.toIntOrNull()
                val bridge = if (slot == null || load == null || ordinal == null) "" else
                    "<script>window.__gtSend=function(event){return parent.__gtPager.post(window,$slot,$load,$ordinal,event);};</script>"
                val injection = binding.injection.replace("__GT_NATIVE_BRIDGE__", bridge)
                val index = Regex("</head>", RegexOption.IGNORE_CASE).find(html)?.range?.first
                val result = if (index == null) injection + html else html.substring(0,index) + injection + html.substring(index)
                WebResourceResponse("text/html", "utf-8", ByteArrayInputStream(result.toByteArray(Charsets.UTF_8)))
            } else WebResourceResponse(if (chapter) "text/html" else type.substringBefore(';'), "utf-8", stream)
            if (binding.trace) Log.i("GT_ORIGINAL_RESOURCE", "hit view=$view chapter=$chapter bytes=${file.length()} us=${(SystemClock.elapsedRealtimeNanos()-start)/1000}")
            return response
        } catch (error: Exception) {
            return null // 缓存缺失、清理或平台不支持时，由现有读取流程完整处理。
        }
    }
}
