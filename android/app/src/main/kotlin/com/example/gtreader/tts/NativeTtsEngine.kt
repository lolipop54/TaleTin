package com.example.gtreader.tts

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.speech.tts.TextToSpeech
import android.media.AudioAttributes
import android.speech.tts.UtteranceProgressListener
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import java.util.Locale
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * 原生 TTS 的持有者：引擎初始化、发声提交、停止与释放。
 *
 * 三个关键决定（离线听书实现计划 第 5、7 节）：
 *
 * 1. **所有 TTS 操作都在自己的一条后台线程上**。TextToSpeech 必须在有 Looper 的线程
 *    创建，回调也只回到这条线程；用主线程的话，等待初始化的那几百毫秒会卡住界面，
 *    而且 Pigeon 的宿主方法要等初始化结果，主线程等自己就死锁了。
 * 2. **上下文只拿 applicationContext**，绝不持有 Activity：返回书架、锁屏、Activity
 *    被回收都要能继续读下一句。
 * 3. **释放只发生在引擎 detach 或被显式换引擎时**，Activity.onDestroy 不碰它。
 *
 * 事件回调（started/range/done/error）由 [UtteranceProgressListener] 转发到 Dart，
 * 见 [speakLocked] 与监听器实现。
 */
internal class NativeTtsEngine(
    private val context: Context,
    private val events: TtsEventsFlutterApi,
    private val mainScope: CoroutineScope,
) {
    private val thread = HandlerThread("gt-tts").apply { start() }
    private val handler = Handler(thread.looper)
    private val audioPlayer = SpeechAudioPlayer(
        context, handler,
        started = { id -> emit("onStarted") { events.onStarted(id) } },
        range = { id, start, end ->
            emit("onRangeStart") { events.onRangeStart(id, start.toLong(), end.toLong()) }
        },
        done = { id -> emit("onDone") { events.onDone(id) } },
        failed = { id -> emit("onError") {
            events.onError(id, TtsErrorCode.OUTPUT, "本地语音播放失败")
        } },
    )
    private var systemDefaultPackage = ""
    private var sleepVersion = -1L
    private var sleepDeadline: Long? = null
    private var sleepReported = false
    private val sleepCheck = Runnable { checkSleepDeadline() }

    fun setSleepDeadline(version: Long, deadlineMs: Long?) {
        handler.post {
            if (version < sleepVersion) return@post
            handler.removeCallbacks(sleepCheck)
            sleepVersion = version
            sleepDeadline = deadlineMs
            sleepReported = false
            checkSleepDeadline()
        }
    }

    /** elapsedRealtime 包含设备休眠；暂停不取消，换引擎不重置。 */
    private fun checkSleepDeadline(): Boolean {
        val deadline = sleepDeadline ?: return false
        val remaining = deadline - SystemClock.elapsedRealtime()
        if (remaining <= 0) {
            tts?.stop()
            audioPlayer.stop()
            if (!sleepReported) {
                sleepReported = true
                val version = sleepVersion
                Log.i(TAG, "sleep deadline version=$version deadline=$deadline stoppedAt=${SystemClock.elapsedRealtime()}")
                emit("onSleepDeadline") { events.onSleepDeadline(version) }
            }
            return true
        }
        handler.removeCallbacks(sleepCheck)
        handler.postDelayed(sleepCheck, remaining.coerceAtMost(1000L))
        return false
    }

    /** 当前引擎实例；为 null 表示没有可用引擎（未初始化或已释放）。 */
    @Volatile
    private var tts: TextToSpeech? = null

    /** 调用方要求的引擎包名；null 表示「系统默认」。用于判断能否复用现有实例。 */
    @Volatile
    private var requestedEngine: String? = null

    /** 实际生效的引擎包名；未初始化时为空串。 */
    @Volatile
    private var enginePackage: String = ""

    /** 初始化等待：onInit 回调在主线程，这里等它。 */
    @Volatile
    private var initLatch: CountDownLatch? = null

    @Volatile
    private var initStatus: Int = TextToSpeech.ERROR

    /**
     * 初始化或换引擎。阻塞调用线程（Pigeon 的后台线程），不阻塞主线程。
     * 失败通过返回值说明原因，不抛异常——界面要能显示「引擎不可用」而不是崩掉。
     */
    fun initialize(requested: String?): TtsInitResultDto {
        val want = requested?.takeIf { it.isNotBlank() }
        // 同一个引擎已经在跑：直接复用，不重建（重建会丢掉正在读的内容）
        if (tts != null && requestedEngine == want) {
            return TtsInitResultDto(ok = true, enginePackage = enginePackage)
        }

        val latch = CountDownLatch(1)
        handler.post {
            releaseLocked()
            requestedEngine = want
            initStatus = TextToSpeech.ERROR
            initLatch = latch
            val listener = TextToSpeech.OnInitListener { status ->
                initStatus = status
                initLatch?.countDown()
            }
            tts = try {
                if (want == null) {
                    TextToSpeech(context, listener)
                } else {
                    TextToSpeech(context, listener, want)
                }
            } catch (error: Throwable) {
                // 引擎崩溃等：当成初始化失败返回，不往上抛
                Log.w(TAG, "创建 TextToSpeech 失败：$want", error)
                null
            }
            // 事件回调必须挂在实例上才有；每个新建的引擎都要重新挂
            tts?.setOnUtteranceProgressListener(progressListener)
            if (tts == null) {
                initLatch = null
                latch.countDown()
            }
        }

        if (!latch.await(INIT_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
            Log.w(TAG, "等待 TTS 初始化超时：$want")
            // 超时后引擎可能才建好，留着会是个半死状态，直接收掉；线程保留，允许重试
            release()
            return TtsInitResultDto(
                ok = false,
                enginePackage = want.orEmpty(),
                errorCode = TtsErrorCode.INIT,
                message = "等待引擎初始化超时",
            )
        }
        if (initStatus != TextToSpeech.SUCCESS || tts == null) {
            return TtsInitResultDto(
                ok = false,
                enginePackage = want.orEmpty(),
                errorCode = TtsErrorCode.INIT,
                message = "引擎返回初始化失败（status=$initStatus）",
            )
        }

        // 指定的引擎没装时，TextToSpeech 会**静默退回默认引擎**（公开构造函数没有
        // useFallback 参数，关不掉这个行为）。所以必须自己核对已安装清单，
        // 否则用户选了不存在的引擎，我们会报成功、实际却是另一个引擎在发声。
        val installed = runCatching { tts?.engines.orEmpty().map { it.name } }.getOrDefault(emptyList())
        if (want != null && want !in installed) {
            Log.w(TAG, "引擎 $want 未安装，系统会退回默认引擎")
            release()
            return TtsInitResultDto(
                ok = false,
                enginePackage = want,
                errorCode = TtsErrorCode.NOT_INSTALLED,
                message = "系统里没有这个 TTS 引擎（已安装：$installed）",
            )
        }

        enginePackage = if (want != null) want else resolveDefaultEngine()
        systemDefaultPackage = tts?.defaultEngine.orEmpty()
        tts?.setAudioAttributes(AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
        return TtsInitResultDto(ok = true, enginePackage = enginePackage)
    }

    /**
     * 传 null 让系统挑引擎时，把系统默认引擎包名回填给上层——
     * 界面要显示「当前用的是哪个引擎」，不能留空让人以为没生效。
     */
    private fun resolveDefaultEngine(): String {
        val engine = tts ?: return ""
        val declared = runCatching { engine.defaultEngine }.getOrNull()
        if (!declared.isNullOrBlank()) return declared
        return runCatching { engine.engines.orEmpty().firstOrNull()?.name.orEmpty() }.getOrDefault("")
    }

    /**
     * 查询已安装且提供系统 TTS 服务的引擎；不在应用内附带语音模型。
     */
    fun listEngines(): List<TtsEngineDto> {
        return try {
            val manager = context.packageManager
            manager.queryIntentServices(Intent(TextToSpeech.Engine.INTENT_ACTION_TTS_SERVICE), 0)
                .distinctBy { it.serviceInfo.packageName }.map { info ->
                TtsEngineDto(
                    packageName = info.serviceInfo.packageName,
                    label = info.loadLabel(manager).toString(),
                    isDefault = info.serviceInfo.packageName == systemDefaultPackage,
                )
            }
        } catch (error: Throwable) {
            Log.w(TAG, "枚举 TTS 引擎失败", error)
            emptyList()
        }
    }

    /** 当前引擎的音色清单；未初始化时返回空表。 */
    fun listVoices(): List<TtsVoiceDto> {
        val engine = tts ?: return emptyList()
        return try {
            engine.voices.orEmpty().map { voice ->
                TtsVoiceDto(
                    name = voice.name ?: "",
                    locale = voice.locale?.toLanguageTag().orEmpty(),
                    isNetworkRequired = voice.isNetworkConnectionRequired,
                    // pigeon 把 Dart 的 int 生成为 Kotlin 的 Long
                    quality = voice.quality.toLong(),
                    latency = voice.latency.toLong(),
                    features = voice.features.orEmpty().toList(),
                )
            }
        } catch (error: Throwable) {
            Log.w(TAG, "枚举音色失败", error)
            emptyList()
        }
    }

    /** 切换当前引擎内的音色；名称不存在时返回 false，调用方保留原音色。 */
    fun setVoice(voiceName: String, locale: String?): Boolean {
        val engine = tts ?: return false
        // 小米引擎会为不同语言标签复用 zh；仅按名字会选错真实选项。
        val voice = engine.voices.orEmpty().firstOrNull {
            it.name == voiceName && (locale == null || it.locale?.toLanguageTag() == locale)
        } ?: return false
        if (engine.setVoice(voice) != TextToSpeech.SUCCESS) return false
        // Android getVoice() 只按名字反查，不能用其 locale 判断同名选项。
        // 向系统传入精确 Voice 对象；不承诺同名不同标签有不同声音。
        Log.i(TAG, "voice selected name=$voiceName locale=${voice.locale.toLanguageTag()}")
        return engine.voice?.name == voiceName
    }

    /** 语速倍率，相对引擎默认语速。 */
    fun setRate(rate: Double) {
        check(tts?.setSpeechRate(rate.toFloat()) == TextToSpeech.SUCCESS) {
            "语速设置失败"
        }
    }

    /** 当前引擎是否支持该语言（BCP-47 形如 zh-CN）。 */
    fun isLanguageAvailable(locale: String): Boolean {
        val engine = tts ?: return false
        return try {
            engine.isLanguageAvailable(Locale.forLanguageTag(locale)) >= TextToSpeech.LANG_AVAILABLE
        } catch (error: Throwable) {
            Log.w(TAG, "语言可用性查询失败：$locale", error)
            false
        }
    }

    /** 提交一段文本；返回即代表受理，真的开始读由 started 事件确认。 */
    fun speak(utteranceId: String, text: String) {
        handler.post { speakLocked(utteranceId, text) }
    }

    /** 停止发声并丢弃未播内容。原生没有真正的 pause，暂停也走这里。 */
    fun stop() {
        handler.post {
            tts?.stop()
            audioPlayer.stop()
        }
    }

    /**
     * 释放引擎但保留线程：停止听书后再点开始要能重新初始化。
     * 换引擎、初始化超时也走这里。
     */
    fun release() {
        handler.post { releaseLocked() }
    }

    /**
     * 释放引擎并结束原生线程。只在插件 detach（应用真正退出）时调用；
     * 之后这个实例不能再 initialize——线程已经没了，post 进去的任务永远不会执行。
     */
    fun dispose() {
        handler.removeCallbacks(sleepCheck)
        handler.post { releaseLocked() }
        // quitSafely：先把上面那条释放消息做完再退出线程
        thread.quitSafely()
    }

    private fun speakLocked(utteranceId: String, text: String) {
        // 即使 Dart 的到时事件还在排队，过期任务也不允许再次发声。
        if (checkSleepDeadline()) return
        if (audioPlayer.usePrepared(utteranceId, text)) return
        val file = audioPlayer.prepare(utteranceId)
        val engine = tts ?: return
        if (engine.synthesizeToFile(text, null, file, utteranceId) == TextToSpeech.ERROR) {
            audioPlayer.stop()
            emit("onError") {
                events.onError(utteranceId, TtsErrorCode.SYNTHESIS, "语音合成请求失败")
            }
        }
    }

    private var preparationId = 0L
    fun prepareSpeech(text: String) {
        handler.post {
            if (checkSleepDeadline()) return@post
            val id = "prepared:${++preparationId}"
            val file = audioPlayer.prepareNext(id, text)
            val engine = tts ?: return@post
            if (engine.synthesizeToFile(text, null, file, id) == TextToSpeech.ERROR) {
                audioPlayer.discard(id)
            }
        }
    }

    /**
     * 播放事件回调。这些回调在 TTS 线程（[thread]）上到达，事件自己的 ID 原样往上带，
     * 绝不用「当前正在读的那句」顶替——旧回调可能会在换句之后才迟到（实现计划 第 7 节）。
     * 转发到主线程再进 Dart，保证 Dart 侧看到的事件顺序与发出顺序一致。
     */
    private val progressListener = object : UtteranceProgressListener() {
        override fun onStart(utteranceId: String?) {
            // 这是合成开始，还没有发声；真实 started 由本应用播放器报告。
        }

        override fun onBeginSynthesis(utteranceId: String?, sampleRateInHz: Int,
            audioFormat: Int, channelCount: Int) {
            val id = utteranceId ?: return
            audioPlayer.synthesisStarted(id, sampleRateInHz)
        }

        override fun onRangeStart(utteranceId: String?, start: Int, end: Int, frame: Int) {
            val id = utteranceId ?: return
            audioPlayer.rememberRange(id, frame, start, end)
        }

        override fun onDone(utteranceId: String?) {
            val id = utteranceId ?: return
            audioPlayer.synthesized(id)
        }

        override fun onStop(utteranceId: String?, interrupted: Boolean) {
            val id = utteranceId ?: return
            audioPlayer.discard(id)
            emit("onStopped") { events.onStopped(id, interrupted) }
        }

        /** 旧版错误回调（API 26 前唯一的一个），新引擎仍可能走它。 */
        @Deprecated("旧接口，新引擎走带错误码的重载")
        override fun onError(utteranceId: String?) {
            val id = utteranceId ?: return
            audioPlayer.discard(id)
            emit("onError") { events.onError(id, TtsErrorCode.OTHER, "引擎未提供错误码") }
        }

        override fun onError(utteranceId: String?, errorCode: Int) {
            val id = utteranceId ?: return
            audioPlayer.discard(id)
            emit("onError") {
                events.onError(id, mapErrorCode(errorCode), "引擎错误码 $errorCode")
            }
        }
    }

    /**
     * 把事件送到 Dart，**送不出去也绝不能崩应用**。
     *
     * Dart 侧没注册监听时（页面已释放、测试进程正在收尾），通道会以
     * "Unable to establish connection on channel" 失败。这个异常如果从协程里冒出来，
     * 会打到主线程把进程干掉——2026-09-27 真机实测：连续跑集成测试时应用直接闪退，
     * 崩溃栈就是这里的 onStopped。丢一条播放通知是可以接受的，闪退不是。
     */
    private fun emit(event: String, block: suspend () -> Unit) {
        mainScope.launch {
            try {
                block()
            } catch (error: Throwable) {
                Log.d(TAG, "事件 $event 未送达 Dart（可能已无监听）", error)
            }
        }
    }

    /** 把 Android 的 ERROR_* 常量翻译成通道里的错误码。 */
    private fun mapErrorCode(code: Int): TtsErrorCode = when (code) {
        TextToSpeech.ERROR_SYNTHESIS -> TtsErrorCode.SYNTHESIS
        TextToSpeech.ERROR_OUTPUT -> TtsErrorCode.OUTPUT
        TextToSpeech.ERROR_NETWORK -> TtsErrorCode.NETWORK
        TextToSpeech.ERROR_NETWORK_TIMEOUT -> TtsErrorCode.NETWORK_TIMEOUT
        TextToSpeech.ERROR_SERVICE -> TtsErrorCode.SERVICE
        TextToSpeech.ERROR_NOT_INSTALLED_YET -> TtsErrorCode.NOT_INSTALLED
        TextToSpeech.ERROR_INVALID_REQUEST -> TtsErrorCode.INVALID_REQUEST
        // 通道枚举里的 UNSUPPORTED_LANGUAGE 没有对应的朗读错误码：
        // TextToSpeech 对「语言不支持」是用 setLanguage/isLanguageAvailable 的结果表达的，
        // 不是 ERROR_*。这里保留枚举值，供语言可用性检查使用。
        else -> TtsErrorCode.OTHER
    }

    private fun releaseLocked() {
        audioPlayer.stop()
        initLatch = null
        tts?.let { engine ->
            try {
                engine.stop()
                engine.shutdown()
            } catch (error: Throwable) {
                Log.w(TAG, "释放 TTS 失败", error)
            }
        }
        tts = null
        requestedEngine = null
        enginePackage = ""
    }

    private companion object {
        const val TAG = "GtTts"
        /** 个别引擎首次加载语音数据很慢，给足时间；超时按失败处理并释放。 */
        const val INIT_TIMEOUT_MS = 15_000L
    }
}
