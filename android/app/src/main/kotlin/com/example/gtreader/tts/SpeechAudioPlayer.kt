package com.example.gtreader.tts

import android.content.Context
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.os.Handler
import android.os.PowerManager
import java.io.File

/**
 * 系统 TTS 只负责合成；实际音频由本应用播放，系统才能识别音频所属者。
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
        var output: MediaPlayer? = null
        var outputReady = false
        var sampleRate = 0
        val ranges = mutableListOf<Range>()
        var nextRange = 0
    }
    private var audio: Audio? = null
    private var prepared: Audio? = null

    /**
     * 提示音等待期间按住发声。按住只影响「出声」，
     * 不删合成结果、不推进队列，所以续播仍是同一段音频的同一帧。
     */
    private var held = false
    private val reportRange = Runnable { reportPlaybackRange() }
    val activeId: String? get() = audio?.id

    fun prepare(id: String): File {
        // 不能用 stop()：那会清掉按住状态，提示音还没放完就会出声。
        stopCurrent()
        releasePrepared()
        val file = File.createTempFile("gt-speech-", ".wav", context.cacheDir)
        audio = Audio(id, file)
        return file
    }

    fun prepareNext(id: String, text: String): File {
        releasePrepared()
        val file = File.createTempFile("gt-speech-", ".wav", context.cacheDir)
        prepared = Audio(id, file, text)
        return file
    }

    /** 暂停当前音频并停下进度上报；之后合成的下一段也等解除按住才发声。 */
    fun hold() {
        handler.post {
            held = true
            handler.removeCallbacks(reportRange)
            try {
                audio?.output?.takeIf { it.isPlaying }?.pause()
            } catch (_: Exception) {
                // 播放器已在结束/错误状态时 pause 会抛；按住失败最多和提示音同时响，不影响后续。
            }
        }
    }

    /** 系统交还焦点后从同一帧继续；没有按住或没有可播音频时什么也不做。 */
    fun resume() {
        handler.post {
            if (!held) return@post
            held = false
            val current = audio ?: return@post
            if (current.outputReady) start(current)
        }
    }

    /** 缓存只在 Dart 真正提交同一段时使用，合成完成不能自行推进播放。 */
    fun usePrepared(id: String, text: String): Boolean {
        val next = prepared?.takeIf { it.text == text } ?: return false
        stopCurrent()
        prepared = null
        next.id = id
        audio = next
        if (next.outputReady) start(next)
        return true
    }

    private fun find(id: String): Audio? =
        audio?.takeIf { it.synthesisId == id } ?:
        prepared?.takeIf { it.synthesisId == id }

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
            // 下一段提前完成播放器准备，但只有 usePrepared 受理正文后才发声。
            play(current)
        }
    }

    private fun play(current: Audio) {
        try {
            val output = MediaPlayer()
            current.output = output
            output.setAudioAttributes(AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
            output.setWakeMode(context, PowerManager.PARTIAL_WAKE_LOCK)
            output.setDataSource(current.file.absolutePath)
            output.setOnPreparedListener {
                if (audio !== current && prepared !== current) return@setOnPreparedListener
                current.outputReady = true
                if (audio === current) start(current)
            }
            output.setOnCompletionListener {
                if (audio !== current) return@setOnCompletionListener
                stopCurrent()
                done(current.id)
            }
            output.setOnErrorListener { _, _, _ ->
                discard(current.synthesisId)
                true
            }
            output.prepareAsync()
        } catch (_: Exception) {
            discard(current.synthesisId)
        }
    }

    private fun start(current: Audio) {
        // 提示音期间即使合成已完成，也不许自己出声。
        if (held) return
        try {
            val output = current.output ?: return
            output.start()
            started(current.id)
            if (current.ranges.isNotEmpty()) reportPlaybackRange()
        } catch (_: Exception) { discard(current.synthesisId) }
    }

    /** 合成引擎的范围回调是提前到达的；按实际播放帧报告，不提前推进书籍位置。 */
    private fun reportPlaybackRange() {
        val current = audio ?: return
        val output = current.output ?: return
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
                current.output?.release()
                current.file.delete()
            }
        }
    }

    fun stop() {
        // 用户暂停/停止、换章、到时都走这里：按住状态一并清掉，
        // 之后迟到的焦点归还不能再让它开口。
        held = false
        stopCurrent()
        releasePrepared()
    }

    private fun stopCurrent() {
        handler.removeCallbacks(reportRange)
        val previous = audio
        audio = null
        previous?.output?.release()
        previous?.file?.delete()
    }

    private fun releasePrepared() {
        prepared?.output?.release()
        prepared?.file?.delete()
        prepared = null
    }
}
