package com.example.gtreader

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import java.io.BufferedInputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.InputStream
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.nio.ByteBuffer
import java.nio.charset.Charset
import java.nio.charset.CodingErrorAction
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

/**
 * 由 MainActivity 提供的文件选择桥：选择器必须在主线程弹出，
 * 而 [DocumentHostApi.pickDocuments] 跑在后台线程上等待结果。
 */
interface DocumentPicker {
    fun startPick(onResult: (List<PickedDocumentDto>) -> Unit)
}

/**
 * 文档读取的平台实现（设计文档 6.1）。
 *
 * - 选择结果只有 URI，不能当路径用，因此统一转成输入流按块读取；
 * - 大文件不做整本传输：每次最多 [MAX_CHUNK_BYTES]，Dart 侧边写暂存边算哈希；
 * - GB18030 等中文常见编码交给 Android 的 ICU 解码，Dart 只原生支持
 *   UTF-8 / UTF-16。
 */
class DocumentHostApiImpl(
    private val context: Context,
    private val picker: DocumentPicker,
) : DocumentHostApi {

    /** 会话 ID → 输入流。由 Dart 侧负责在结束或取消时关闭。 */
    private val sessions = ConcurrentHashMap<Long, InputStream>()
    private val nextSessionId = AtomicLong(1)

    override fun pickDocuments(): List<PickedDocumentDto> {
        val latch = CountDownLatch(1)
        var result: List<PickedDocumentDto> = emptyList()
        picker.startPick { picked ->
            result = picked
            latch.countDown()
        }
        // 用户在选择器里停留多久都合理，这里只是防止回调永远不来的兜底
        latch.await(10, TimeUnit.MINUTES)
        return result
    }

    override fun openDocument(uri: String): DocumentSessionDto {
        val parsed = Uri.parse(uri)
        val stream = context.contentResolver.openInputStream(parsed)
            ?: throw IllegalArgumentException("无法打开所选文件")
        val id = nextSessionId.getAndIncrement()
        sessions[id] = BufferedInputStream(stream, IO_BUFFER_BYTES)
        return DocumentSessionDto(id, sizeOf(parsed))
    }

    override fun readDocumentChunk(sessionId: Long, maxBytes: Long): ByteArray? {
        val stream = sessions[sessionId] ?: throw IllegalArgumentException("读取会话已关闭")
        val size = maxBytes.coerceIn(1L, MAX_CHUNK_BYTES.toLong()).toInt()
        val buffer = ByteArray(size)
        var filled = 0
        // 尽量填满一块，减少通道往返次数
        while (filled < size) {
            val read = stream.read(buffer, filled, size - filled)
            if (read < 0) break
            filled += read
        }
        return when {
            filled <= 0 -> null
            filled == size -> buffer
            else -> buffer.copyOf(filled)
        }
    }

    override fun closeDocument(sessionId: Long) {
        sessions.remove(sessionId)?.close()
    }

    override fun decodeBytes(bytes: ByteArray, charsetName: String): String {
        // 预览片段可能在多字节字符中间截断，用替换字符而不是报错
        val decoder = charsetOf(charsetName).newDecoder()
            .onMalformedInput(CodingErrorAction.REPLACE)
            .onUnmappableCharacter(CodingErrorAction.REPLACE)
        return decoder.decode(ByteBuffer.wrap(bytes)).toString()
    }

    override fun transcodeToUtf8(
        sourcePath: String,
        charsetName: String,
        targetPath: String,
    ): String {
        val charset = charsetOf(charsetName)
        File(targetPath).parentFile?.mkdirs()
        val decoder = charset.newDecoder()
            .onMalformedInput(CodingErrorAction.REPLACE)
            .onUnmappableCharacter(CodingErrorAction.REPLACE)
        FileInputStream(sourcePath).use { input ->
            FileOutputStream(targetPath).use { output ->
                InputStreamReader(input, decoder).use { reader ->
                    OutputStreamWriter(output, Charsets.UTF_8).use { writer ->
                        val buffer = CharArray(IO_BUFFER_BYTES)
                        while (true) {
                            val read = reader.read(buffer)
                            if (read < 0) break
                            writer.write(buffer, 0, read)
                        }
                    }
                }
            }
        }
        return charset.name()
    }

    override fun availableBytes(path: String): Long {
        val dir = File(path)
        // 目录还不存在时退到最近的已存在父目录，统计的是同一卷
        var target = dir
        while (!target.exists() && target.parentFile != null) {
            target = target.parentFile!!
        }
        return target.usableSpace
    }

    override fun supportedCharsets(): List<String> =
        CHARSET_CANDIDATES.filter { name ->
            try {
                Charset.isSupported(name)
            } catch (_: IllegalArgumentException) {
                false
            }
        }

    private fun charsetOf(name: String): Charset =
        try {
            Charset.forName(name)
        } catch (_: Exception) {
            throw IllegalArgumentException("不支持的字符集：$name")
        }

    /** 通过 OpenableColumns 读取显示名与大小；提供方不返回时为 null。 */
    private fun sizeOf(uri: Uri): Long? =
        try {
            context.contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                val index = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (index >= 0 && cursor.moveToFirst() && !cursor.isNull(index)) {
                    cursor.getLong(index)
                } else {
                    null
                }
            }
        } catch (_: Exception) {
            null
        }

    private companion object {
        const val IO_BUFFER_BYTES = 64 * 1024
        const val MAX_CHUNK_BYTES = 1024 * 1024

        /** 「手动切换编码」的候选；GB18030 覆盖 GBK/GB2312 的中文常见范围。 */
        val CHARSET_CANDIDATES = listOf(
            "UTF-8", "UTF-16LE", "UTF-16BE",
            "GB18030", "GBK", "GB2312", "Big5",
            "Shift_JIS", "EUC-KR", "ISO-8859-1", "windows-1252",
        )
    }
}
