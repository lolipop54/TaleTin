package com.example.gtreader

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.storage.StorageManager
import android.provider.Settings
import android.provider.MediaStore
import android.system.Os
import android.system.OsConstants
import android.system.ErrnoException
import android.system.StructStat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors
import java.security.MessageDigest

/** 仅枚举共享存储；文件内容仍交给原来的分块导入通道。 */
class LocalBookFiles(private val activity: Activity, engine: FlutterEngine) {
    private val worker = Executors.newSingleThreadExecutor()
    private var permissionResult: MethodChannel.Result? = null
    private var storageRoots: List<File>? = null
    private val transliterator by lazy {
        if (Build.VERSION.SDK_INT >= 29)
            android.icu.text.Transliterator.getInstance("Han-Latin; Latin-ASCII") else null
    }
    init {
        MethodChannel(engine.dartExecutor.binaryMessenger, "gtreader/local_book_files")
            .setMethodCallHandler { call, result ->
                if (call.method == "access") {
                    result.success(hasAccess())
                } else if (call.method == "requestAccess") {
                    requestAccess(result)
                } else {
                    worker.execute {
                        try {
                            check(hasAccess()) { "请先允许访问手机文件" }
                            val value: Any? = when (call.method) {
                                "roots" -> {
                                    storageRoots = discoverRoots()
                                    roots().map { entry(it, false) }
                                }
                                "list" -> {
                                    val extensions = call.argument<List<String>>("extensions")?.toSet()
                                        ?: setOf("txt", "epub", "mobi", "azw3", "pdf")
                                    require(extensions.isNotEmpty() && extensions.all {
                                        it in setOf("txt", "epub", "mobi", "azw3", "pdf", "ttf", "otf", "ttc") })
                                    val dir = checkedFile(call.argument<String>("path")!!)
                                    val children = dir.listFiles()
                                        ?: error("无法读取这个文件夹，请检查权限或重新选择")
                                    children.filter { supported(it, extensions) }.map {
                                        entry(it, call.argument<Boolean>("counts") == true, extensions)
                                    }
                                }
                                "delete" -> {
                                    val file = checkedFile(call.argument<String>("path")!!)
                                    check(file.isFile && supported(file)) { "只能删除 TXT、EPUB 文件" }
                                    check(file.delete()) { "删除失败，文件可能已移动或没有写入权限" }
                                    true
                                }
                                "inspect" -> inspect(call.argument<List<String>>("paths")!!)
                                "indexStamp" -> indexStamp(call.argument<List<String>>("extensions")!!)
                                else -> error("未知文件操作")
                            }
                            activity.runOnUiThread { result.success(value) }
                        } catch (e: Exception) {
                            activity.runOnUiThread { result.error("files", e.message, null) }
                        }
                    }
                }
            }
    }

    private fun hasAccess(): Boolean = if (Build.VERSION.SDK_INT >= 30)
        Environment.isExternalStorageManager() else
        activity.checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE) ==
            PackageManager.PERMISSION_GRANTED

    private fun requestAccess(result: MethodChannel.Result) {
        if (hasAccess()) { result.success(true); return }
        if (permissionResult != null) { result.success(false); return }
        permissionResult = result
        try {
            if (Build.VERSION.SDK_INT >= 30) {
                val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                    Uri.parse("package:${activity.packageName}"))
                @Suppress("DEPRECATION")
                activity.startActivityForResult(intent, REQUEST)
            } else {
                activity.requestPermissions(arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE,
                    Manifest.permission.WRITE_EXTERNAL_STORAGE), REQUEST)
            }
        } catch (e: Exception) {
            permissionResult = null
            result.error("permission", "无法打开文件授权设置：${e.message}", null)
        }
    }

    fun onResult(code: Int): Boolean {
        if (code != REQUEST) return false
        permissionResult?.success(hasAccess())
        permissionResult = null
        return true
    }

    @Suppress("DEPRECATION")
    private fun discoverRoots(): List<File> = (listOf(Environment.getExternalStorageDirectory()) +
        (if (Build.VERSION.SDK_INT >= 30) activity.getSystemService(StorageManager::class.java)
            .storageVolumes.mapNotNull { it.directory } else emptyList()) +
        activity.getExternalFilesDirs(null).filterNotNull().map {
            File(it.absolutePath.substringBefore("/Android/"))
        }).distinctBy { it.canonicalPath }.filter { it.isDirectory }

    private fun roots(): List<File> = storageRoots ?: discoverRoots().also { storageRoots = it }

    private fun checkedFile(path: String): File {
        val file = File(path).canonicalFile
        check(roots().any { file == it.canonicalFile ||
            file.path.startsWith(it.canonicalPath + File.separator) }) { "不在手机共享存储内" }
        check(!privateDirectory(file)) {
            "系统不允许访问其他应用的私有目录"
        }
        return file
    }

    private fun supported(file: File, extensions: Set<String> = setOf("txt", "epub", "mobi", "azw3", "pdf")): Boolean =
        (file.isDirectory && !privateDirectory(file) ||
            file.isFile && file.extension.lowercase() in extensions) &&
            file.canonicalPath == file.absolutePath

    private fun privateDirectory(file: File): Boolean = roots().any { root ->
        listOf("data", "obb").any { name ->
            val path = "${root.absolutePath}/Android/$name"
            file.path == path || file.path.startsWith("$path/")
        }
    }

    private fun entry(file: File, counts: Boolean,
        extensions: Set<String> = setOf("txt", "epub", "mobi", "azw3", "pdf")): Map<String, Any> {
        // One stat reads type, bytes and timestamp together. Keep millisecond API units.
        // A file may disappear between enumeration and metadata lookup, just as with File APIs.
        val info = try { Os.stat(file.absolutePath) } catch (_: ErrnoException) { null }
        val directory = info?.let { OsConstants.S_ISDIR(it.st_mode) } ?: file.isDirectory
        val modified = if (info == null) 0L else if (Build.VERSION.SDK_INT >= 27)
            info.st_mtim.tv_sec * 1000 + info.st_mtim.tv_nsec / 1_000_000
            else file.lastModified() // Older Android must retain millisecond precision too.
        val sortName = if (Build.VERSION.SDK_INT >= 29)
            transliterator?.transliterate(file.name) ?: file.name else file.name
        return mapOf("path" to file.absolutePath, "name" to file.name,
            "directory" to directory, "size" to (info?.st_size ?: 0L),
            "modified" to modified, "sortName" to sortName,
            "stamp" to (info?.let { stamp(it) } ?: ""),
            "count" to if (counts && directory)
                (file.listFiles()?.count { supported(it, extensions) &&
                    (extensions.none { ext -> ext in setOf("ttf", "otf", "ttc") } || it.isFile) } ?: -1) else -1)
    }

    /** 只核验指定路径，不遍历目录。缺失与暂时不可读分开，避免拔卡/权限变化清空缓存。 */
    private fun inspect(paths: List<String>): Map<String, Any> {
        storageRoots = discoverRoots()
        val entries = mutableListOf<Map<String, Any>>()
        val missing = mutableListOf<String>()
        val unavailable = mutableListOf<String>()
        for (path in paths) {
            try {
                val file = checkedFile(path)
                val info = Os.stat(file.path)
                if (!file.canRead()) { unavailable.add(path); continue }
                if (!OsConstants.S_ISREG(info.st_mode) && !OsConstants.S_ISDIR(info.st_mode)) {
                    missing.add(path); continue
                }
                // 不做拼音转换或目录数量统计，检查几千个目录时只读取系统属性。
                val modified = if (Build.VERSION.SDK_INT >= 27)
                    info.st_mtim.tv_sec * 1000 + info.st_mtim.tv_nsec / 1_000_000
                    else file.lastModified()
                entries.add(mapOf("path" to path, "name" to file.name,
                    "directory" to OsConstants.S_ISDIR(info.st_mode), "size" to info.st_size,
                    "modified" to modified, "sortName" to file.name, "count" to -1,
                    "stamp" to stamp(info)))
            } catch (e: ErrnoException) {
                // 上次列目录后可能已经拔卡，整个存储卷失联不等于单个文件被删除。
                val volumeGone = roots().none { root ->
                    (path == root.path || path.startsWith(root.path + File.separator)) && root.isDirectory }
                if (!volumeGone && (e.errno == OsConstants.ENOENT || e.errno == OsConstants.ENOTDIR))
                    missing.add(path) else unavailable.add(path)
            } catch (_: Exception) { unavailable.add(path) }
        }
        return mapOf("entries" to entries, "missing" to missing, "unavailable" to unavailable)
    }

    private fun stamp(info: StructStat): String {
        val times = if (Build.VERSION.SDK_INT >= 27)
            "${info.st_mtim.tv_sec}:${info.st_mtim.tv_nsec}:${info.st_ctim.tv_sec}:${info.st_ctim.tv_nsec}"
            else "${info.st_mtime}:${info.st_ctime}"
        return "${info.st_dev}:${info.st_ino}:${info.st_mode}:${info.st_size}:$times"
    }

    /** 系统索引可能缺项或滞后；这里只生成独立标记，绝不把索引数量当成真实文件总数。 */
    private fun indexStamp(extensions: List<String>): String? {
        require(extensions.isNotEmpty() && extensions.all {
            it in setOf("txt", "epub", "mobi", "azw3", "pdf", "ttf", "otf", "ttc") })
        return try {
            val columns = arrayOf("_id", "_data", "_size", "date_modified", "_display_name")
            val selection = extensions.joinToString(" OR ") { "LOWER(_display_name) LIKE ?" }
            val digest = MessageDigest.getInstance("SHA-256")
            var count = 0L
            activity.contentResolver.query(MediaStore.Files.getContentUri("external"), columns,
                selection, extensions.map { "%.$it" }.toTypedArray(), "_id ASC")?.use { cursor ->
                while (cursor.moveToNext()) {
                    val path = cursor.getString(1) ?: continue
                    if (privateDirectory(File(path)) || roots().none {
                        path.startsWith(it.path + File.separator) }) continue
                    for (column in columns.indices) {
                        digest.update((cursor.getString(column) ?: "").toByteArray(Charsets.UTF_8))
                        digest.update(0.toByte())
                    }
                    count++
                }
                "$count:" + digest.digest().joinToString("") { "%02x".format(it) }
            }
        } catch (_: Exception) { null } // 部分系统不提供文档索引，目录检查仍继续。
    }

    companion object { private const val REQUEST = 0x6704 }
}
