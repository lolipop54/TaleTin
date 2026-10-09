package com.example.gtreader.tts

import android.content.Context
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.os.Handler
import android.os.PowerManager
import java.io.File

/**
 * 系统 TTS 或内置模型只负责合成；实际音频由本应用播放，系统才能识别音频所属者。
 * 只持有当前段和下一段缓存，不决定正文顺序；完成回调仍交回 Dart 控制器。
 * 所有操作回到 gt-tts 线程，停止后旧合成回调不能重新发声。
 */
internal class SpeechAudioPlayer(
    private val context: Context,
    private val handler: Handler,
    private val started: (String) -> Unit,
    private val range: (String, Int, Int) -> Unit,
    private val done: (String) -> Unit,
    private val failed: (String) -> Unit,
) {
    private data class Range(val frame: Int, val start: Int, val end: Int)
    private class Audio(var id: String, val file: File, val text: String = "") {
        val synthesisId = id
        var ready = false
        var sampleRate = 0
        val ranges = mutableListOf<Range>()
        var nextRange = 0
    }
    private var audio: Audio? = null
    private var prepared: Audio? = null
    private var player: MediaPlayer? = null
    private val reportRange = Runnable { reportPlaybackRange() }

    fun prepare(id: String): File {
        stop()
        val file = File.createTempFile("gt-speech-", ".wav", context.cacheDir)
        audio = Audio(id, file)
        return file
    }

    fun prepareNext(id: String, text: String): File {
        prepared?.file?.delete()
        val file = File.createTempFile("gt-speech-", ".wav", context.cacheDir)
        prepared = Audio(id, file, text)
        return file
    }

    /** 缓存只在 Dart 真正提交同一段时使用，合成完成不能自行推进播放。 */
    fun usePrepared(id: String, text: String): Boolean {
        val next = prepared?.takeIf { it.text == text } ?: return false
        stopCurrent()
        prepared = null
        next.id = id
        audio = next
        if (next.ready) play(next)
        return true
    }

    private fun find(id: String): Audio? =
        audio?.takeIf { it.synthesisId == id } ?:
        prepared?.takeIf { it.synthesisId == id }

    /** 在播放线程提交内置模型结果前，确认这段缓存仍有人使用。 */
    fun accepts(id: String): Boolean = find(id) != null

    fun synthesisStarted(id: String, sampleRate: Int) {
        handler.post { find(id)?.sampleRate = sampleRate }
    }

    fun rememberRange(id: String, frame: Int, start: Int, end: Int) {
        handler.post {
            find(id)?.ranges?.add(Range(frame, start, end))
        }
    }

    fun synthesized(id: String) {
        handler.post {
            val current = find(id) ?: return@post
            current.ready = true
            if (audio === current) play(current)
        }
    }

    private fun play(current: Audio) {
            val id = current.id
            try {
                val output = MediaPlayer()
                player = output
                output.setAudioAttributes(AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
                output.setWakeMode(context, PowerManager.PARTIAL_WAKE_LOCK)
                output.setDataSource(current.file.absolutePath)
                output.setOnPreparedListener {
                    if (audio !== current) return@setOnPreparedListener
                    output.start()
                    started(id)
                    if (current.ranges.isNotEmpty()) reportPlaybackRange()
                }
                output.setOnCompletionListener {
                    if (audio !== current) return@setOnCompletionListener
                    stopCurrent()
                    done(id)
                }
                output.setOnErrorListener { _, _, _ ->
                    if (audio === current) {
                        stopCurrent()
                        failed(id)
                    }
                    true
                }
                output.prepareAsync()
            } catch (_: Exception) {
                stopCurrent()
                failed(id)
            }
    }

    /** 合成引擎的范围回调是提前到达的；按实际播放帧报告，不提前推进书籍位置。 */
    private fun reportPlaybackRange() {
        val current = audio ?: return
        val output = player ?: return
        val frame = output.currentPosition.toLong() * current.sampleRate / 1000
        while (current.nextRange < current.ranges.size &&
            current.ranges[current.nextRange].frame <= frame) {
            val point = current.ranges[current.nextRange++]
            range(current.id, point.start, point.end)
        }
        handler.postDelayed(reportRange, 30)
    }

    fun discard(id: String) {
        handler.post {
            val current = find(id) ?: return@post
            if (audio === current) {
                val playbackId = current.id
                stopCurrent()
                failed(playbackId)
            } else {
                prepared = null
                current.file.delete()
            }
        }
    }

    fun stop() {
        stopCurrent()
        prepared?.file?.delete()
        prepared = null
    }

    private fun stopCurrent() {
        handler.removeCallbacks(reportRange)
        val file = audio?.file
        audio = null
        player?.release()
        player = null
        file?.delete()
    }
}
