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
import android.system.Os
import android.system.OsConstants
import android.system.ErrnoException
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

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
                            val value: Any = when (call.method) {
                                "roots" -> {
                                    storageRoots = discoverRoots()
                                    roots().map { entry(it, false) }
                                }
                                "list" -> {
                                    val dir = checkedFile(call.argument<String>("path")!!)
                                    val children = dir.listFiles()
                                        ?: error("无法读取这个文件夹，请检查权限或重新选择")
                                    children.filter { supported(it) }.map {
                                        entry(it, call.argument<Boolean>("counts") == true)
                                    }
                                }
                                "delete" -> {
                                    val file = checkedFile(call.argument<String>("path")!!)
                                    check(file.isFile && supported(file)) { "只能删除 TXT、EPUB 文件" }
                                    check(file.delete()) { "删除失败，文件可能已移动或没有写入权限" }
                                    true
                                }
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

    private fun supported(file: File): Boolean =
        (file.isDirectory && !privateDirectory(file) ||
            file.isFile && file.extension.lowercase() in setOf("txt", "epub", "mobi", "azw3", "pdf")) &&
            file.canonicalPath == file.absolutePath

    private fun privateDirectory(file: File): Boolean = roots().any { root ->
        listOf("data", "obb").any { name ->
            val path = "${root.absolutePath}/Android/$name"
            file.path == path || file.path.startsWith("$path/")
        }
    }

    private fun entry(file: File, counts: Boolean): Map<String, Any> {
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
            "count" to if (counts && directory)
                (file.listFiles()?.count { supported(it) } ?: -1) else -1)
    }

    companion object { private const val REQUEST = 0x6704 }
}
