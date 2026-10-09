package com.example.gtreader

import android.content.Context
import android.graphics.Paint
import android.graphics.Typeface
import android.graphics.fonts.Font
import android.graphics.fonts.FontFamily
import android.graphics.fonts.SystemFonts
import android.graphics.text.TextRunShaper
import android.os.Build
import android.util.Xml
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** 读取真实中文回退字体；将 TTC 中选中的字体提取为两种引擎共用的文件。 */
object ReadingFonts {
    fun register(context: Context, engine: FlutterEngine) {
        val messenger = engine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "gtreader/reading_fonts",
            io.flutter.plugin.common.StandardMethodCodec.INSTANCE,
            messenger.makeBackgroundTaskQueue()).setMethodCallHandler { call, result ->
            if (call.method !in listOf("list", "system", "selected")) result.notImplemented()
            else try {
                result.success(if (call.method == "selected")
                    selected(context, call.argument<String>("family")!!)
                    else read(context, call.method == "system"))
            }
            catch (error: Exception) { result.error("FONTS", error.message, null) }
        }
    }

    private fun selected(context: Context, family: String): List<Map<String, Any>> {
        if (Regex("gt-device-[0-9a-f]{24}").matches(family)) {
            // 字体选择时已提取过这个文件，重新打开应用只读这一份。
            val cached = File(context.cacheDir, "$family.ttf")
            if (cached.isFile) return listOf(mapOf("id" to family,
                "path" to cached.absolutePath, "name" to name(cached.readBytes(), family),
                "aliases" to emptyList<String>()))
            // Android 清掉缓存后，旧设置只保存摘要编号，需要重新查找原字体。
            return read(context, false).filter { it["id"] == family }
        }
        return read(context, false, family)
    }

    private fun read(context: Context, onlySystem: Boolean, selectedFamily: String? = null): List<Map<String, Any>> {
        // 旧系统没有公开的逐字字体查询接口，不能把猜测名称当真实结果。
        if (Build.VERSION.SDK_INT < 31) return emptyList()
        val candidates = linkedSetOf(selectedFamily ?: "sans-serif")
        if (!onlySystem && selectedFamily == null) candidates.addAll(listOf("serif", "monospace", "KaiTi"))
        for (path in if (onlySystem || selectedFamily != null) emptyList() else
            listOf("/system/etc/fonts.xml", "/product/etc/fonts_customization.xml")) {
            val file = File(path)
            if (!file.canRead()) continue
            file.inputStream().use { stream ->
                val parser = Xml.newPullParser()
                parser.setInput(stream, "UTF-8")
                while (parser.eventType != org.xmlpull.v1.XmlPullParser.END_DOCUMENT) {
                    if (parser.eventType == org.xmlpull.v1.XmlPullParser.START_TAG &&
                        parser.name == "family") {
                        parser.getAttributeValue(null, "name")?.let { candidates.add(it) }
                    }
                    parser.next()
                }
            }
        }
        val found = linkedMapOf<String, MutableMap<String, Any>>()
        val sample = "山风与灯火"
        fun record(font: Font, alias: String? = null) {
            val source = font.file ?: return
            val key = "${source.absolutePath}#${font.ttcIndex}"
            val entry = found.getOrPut(key) {
                val data = extract(font.buffer, font.ttcIndex)
                val id = "gt-device-" + java.security.MessageDigest.getInstance("SHA-256")
                    .digest(data).take(12).joinToString("") { "%02x".format(it) }
                val target = File(context.cacheDir, "$id.ttf")
                if (!target.exists()) target.writeBytes(data)
                mutableMapOf("id" to id, "name" to name(data, source.name),
                    "path" to target.absolutePath, "aliases" to mutableListOf<String>())
            }
            @Suppress("UNCHECKED_CAST")
            if (alias != null) (entry["aliases"] as MutableList<String>).add(alias)
        }
        fun shaped(typeface: Typeface): Font? {
            val paint = Paint().apply {
                this.typeface = typeface
                textLocale = java.util.Locale.SIMPLIFIED_CHINESE
            }
            val glyphs = TextRunShaper.shapeTextRun(sample, 0, sample.length,
                0, sample.length, 0f, 0f, false, paint)
            return if (glyphs.glyphCount() == 0 || glyphs.getGlyphId(0) == 0) null
                else glyphs.getFont(0)
        }
        for (family in candidates) {
            shaped(Typeface.create(family, Typeface.NORMAL))?.let {
                // 主题字体常在固定路径替换文件；读取磁盘新文件，避免 Typeface 的旧映射。
                val current = if (family == "sans-serif" && it.file?.canRead() == true)
                    Font.Builder(it.file!!).setTtcIndex(it.ttcIndex).build() else it
                record(current, family)
            }
        }
        if (!onlySystem && selectedFamily == null) {
            // 无名称的公开中文字体也要列出；不能只枚举会回退到当前字体的别名。
            // 仅保留常规字重，避免把同一字体的粗细版本列成多个选择。
            for (font in SystemFonts.getAvailableFonts()) {
                if (font.style.weight != 400 || font.style.slant != 0) continue
                val locales = font.localeList
                if (!locales.isEmpty && (0 until locales.size()).none {
                    locales[it].language == "zh" && locales[it].country != "TW" &&
                        locales[it].country != "HK"
                }) continue
                val face = Typeface.CustomFallbackBuilder(FontFamily.Builder(font).build()).build()
                val actual = shaped(face) ?: continue
                // 拉丁字体会借用系统中文回退，不能把它误报为中文字体。
                if (actual.file != font.file || actual.ttcIndex != font.ttcIndex) continue
                record(font)
            }
        }
        android.util.Log.i("GTReadingFonts", found.values.joinToString { "${it["name"]}: ${it["aliases"]}" })
        return found.values.toList()
    }

    // SFNT 表偏移在 TTC 中相对整个文件；复制表后重写偏移及校验和。
    private fun extract(source: ByteBuffer, index: Int): ByteArray {
        val src = source.duplicate().order(ByteOrder.BIG_ENDIAN)
        val base = if (src.getInt(0) == 0x74746366) src.getInt(12 + index * 4) else 0
        val count = src.getShort(base + 4).toInt() and 0xffff
        val size = 12 + count * 16 + (0 until count).sumOf {
            (src.getInt(base + 12 + it * 16 + 12) + 3) and -4
        }
        val bytes = ByteArray(size)
        val out = ByteBuffer.wrap(bytes).order(ByteOrder.BIG_ENDIAN)
        // 使用缓冲区批量复制；逐字节 JNI 读取大字体会拖慢首次准备。
        src.position(base)
        src.get(bytes, 0, 12 + count * 16)
        var offset = 12 + count * 16
        var head = 0
        repeat(count) { i ->
            val record = 12 + i * 16
            val from = src.getInt(base + record + 8)
            val length = src.getInt(base + record + 12)
            src.position(from)
            src.get(bytes, offset, length)
            out.putInt(record + 8, offset)
            if (out.getInt(record) == 0x68656164) {
                head = offset
                out.putInt(head + 8, 0)
            }
            offset += (length + 3) and -4
        }
        var sum = 0
        for (i in bytes.indices step 4) sum += out.getInt(i)
        if (head != 0) out.putInt(head + 8, 0xB1B0AFBA.toInt() - sum)
        return bytes
    }

    private fun name(bytes: ByteArray, fallback: String): String {
        val data = ByteBuffer.wrap(bytes).order(ByteOrder.BIG_ENDIAN)
        fun u16(at: Int) = data.getShort(at).toInt() and 0xffff
        for (i in 0 until u16(4)) {
            val table = 12 + i * 16
            if (data.getInt(table) != 0x6e616d65) continue
            val base = data.getInt(table + 8)
            val names = mutableListOf<Pair<Int, String>>()
            for (j in 0 until u16(base + 2)) {
                val record = base + 6 + j * 12
                val platform = u16(record)
                val nameId = u16(record + 6)
                if (platform !in listOf(0, 3) || nameId !in listOf(1, 16)) continue
                val start = base + u16(base + 4) + u16(record + 10)
                val value = String(bytes, start, u16(record + 8), Charsets.UTF_16BE)
                val priority = (if (nameId == 16) 4 else 0) +
                    (if (u16(record + 4) == 0x804) 2 else if (u16(record + 4) == 0x409) 1 else 0)
                names.add(priority to value)
            }
            return names.maxByOrNull { it.first }?.second ?: fallback
        }
        return fallback
    }
}
