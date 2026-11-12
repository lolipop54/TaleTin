package com.example.gtreader

import android.content.Context
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import java.io.File
import java.util.zip.ZipFile

internal fun dictionaryDirectory(context: Context) = File(context.noBackupFilesDir, "dictionary")

/** 统计安装包和已落盘文件，不通过查词通道，也不会触发词库解压。 */
object InstalledAppStorage {
    fun register(context: Context, engine: FlutterEngine) {
        val messenger = engine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "gtreader/installed_storage", StandardMethodCodec.INSTANCE,
            messenger.makeBackgroundTaskQueue()).setMethodCallHandler { call, result ->
            if (call.method != "storageUsage") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            try {
                result.success(storageUsage(context))
            } catch (error: Exception) {
                result.error("storage_usage_unavailable", "Cannot read installed storage", null)
            }
        }
    }

    private fun storageUsage(context: Context): Map<String, Long> {
        val info = context.applicationInfo
        val apks = listOf(info.sourceDir, *info.splitSourceDirs.orEmpty()).map(::File)
        val dictionaryPath = FlutterInjector.instance().flutterLoader().getLookupKeyForAsset("assets/dictionary")
        val bundledBytes = apks.sumOf { apk ->
            ZipFile(apk).use { zip ->
                zip.entries().asSequence().filter {
                    it.name.startsWith("assets/$dictionaryPath/") && it.name.endsWith(".sqlite.gz")
                }.sumOf { it.compressedSize }
            }
        }
        // 覆盖安装无词库版本时保留旧库并照实统计；查询只在完整解压后改名为 .sqlite。
        val extractedBytes = dictionaryDirectory(context).listFiles().orEmpty().sumOf { file ->
            if (file.isFile && file.extension == "sqlite") file.length() else 0L
        }
        return mapOf(
            "packageBytes" to apks.sumOf(File::length),
            "bundledDictionaryBytes" to bundledBytes,
            "extractedDictionaryBytes" to extractedBytes,
        )
    }
}
