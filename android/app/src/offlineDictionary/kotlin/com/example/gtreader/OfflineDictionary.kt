package com.example.gtreader

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.os.SystemClock
import android.util.Log
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import java.io.File
import java.text.Normalizer
import java.util.Locale
import java.util.zip.GZIPInputStream

internal fun registerOfflineDictionary(context: Context, engine: FlutterEngine) =
    OfflineDictionary.register(context, engine)

/** Opens only the language being queried, on the channel's serial worker. */
private object OfflineDictionary {
    private const val chineseVersion = "chinese-offline-20261111-v1"
    private const val englishVersion = "english-offline-20261111-v1"
    private val whitespace = Regex("[\\p{Z}\\s]+")
    private val databases = mutableMapOf<String, SQLiteDatabase>()

    fun register(context: Context, engine: FlutterEngine) {
        val messenger = engine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "gtreader/offline_dictionary", StandardMethodCodec.INSTANCE,
            messenger.makeBackgroundTaskQueue()).setMethodCallHandler { call, result ->
            if (call.method != "lookup") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            try {
                val key = normalize(call.argument<String>("term").orEmpty())
                val trace = call.argument<Boolean>("trace") == true
                if (key.isEmpty() || key.codePointCount(0, key.length) > 96) {
                    result.success(emptyList<String>())
                    return@setMethodCallHandler
                }
                val start = SystemClock.elapsedRealtime()
                val version = if (key.codePoints().anyMatch(::isHan)) chineseVersion else englishVersion
                val (db, extracted) = open(context, version)
                val opened = SystemClock.elapsedRealtime()
                val entries = query(db, key).ifEmpty {
                    val lowercase = key.lowercase(Locale.ROOT)
                    if (lowercase == key) emptyList() else query(db, lowercase)
                }
                if (trace) Log.i("GT_DICTIONARY", "extracted=$extracted open_ms=${opened - start} " +
                    "query_ms=${SystemClock.elapsedRealtime() - opened}")
                result.success(entries)
            } catch (error: Exception) {
                result.error("dictionary_unavailable", "Cannot open offline dictionary", null)
            }
        }
    }

    private fun assetKey(version: String): String = FlutterInjector.instance().flutterLoader()
        .getLookupKeyForAsset("assets/dictionary/$version.sqlite.gz")

    @Synchronized
    private fun open(context: Context, version: String): Pair<SQLiteDatabase, Boolean> {
        databases[version]?.let { return it to false }
        val directory = dictionaryDirectory(context).apply { mkdirs() }
        val destination = File(directory, "$version.sqlite")
        val extracted = !destination.isFile
        if (extracted) {
            val temporary = File(directory, "$version.part")
            try {
                context.assets.open(assetKey(version)).use { compressed ->
                    GZIPInputStream(compressed, 128 * 1024).use { input ->
                        temporary.outputStream().use { output -> input.copyTo(output, 128 * 1024) }
                    }
                }
                check(temporary.renameTo(destination)) { "Could not install dictionary asset" }
            } finally {
                temporary.delete()
            }
        }
        val opened = SQLiteDatabase.openDatabase(destination.path, null,
            SQLiteDatabase.OPEN_READONLY or SQLiteDatabase.NO_LOCALIZED_COLLATORS)
        databases[version] = opened
        File(directory, "wiktionary-20261101-v1.sqlite").delete()
        File(directory, "wiktionary-20261101-v2.sqlite").delete()
        return opened to extracted
    }

    private fun isHan(codePoint: Int): Boolean =
        codePoint in 0x3400..0x4DBF || codePoint in 0x4E00..0x9FFF ||
            codePoint in 0xF900..0xFAFF || codePoint in 0x20000..0x33FFF

    private fun normalize(text: String): String =
        whitespace.replace(Normalizer.normalize(text, Normalizer.Form.NFC)
            .replace('’', '\'').replace('‘', '\'').replace('‐', '-').replace('‑', '-'), " ").trim()

    private fun query(db: SQLiteDatabase, key: String): List<String> =
        db.rawQuery("""
            SELECT e.payload FROM lookup l JOIN entry e ON e.id=l.entry
            WHERE l.key=? AND l.priority=(SELECT MIN(priority) FROM lookup WHERE key=?)
            ORDER BY e.word,e.id
        """.trimIndent(), arrayOf(key, key)).use { cursor ->
            buildList { while (cursor.moveToNext()) add(cursor.getString(0)) }
        }
}
