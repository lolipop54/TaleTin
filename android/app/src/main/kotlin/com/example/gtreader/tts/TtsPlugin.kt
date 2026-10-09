package com.example.gtreader.tts

import android.content.Context
import android.speech.tts.TextToSpeech
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.FlutterPlugin.FlutterPluginBinding
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob

/**
 * 听书的原生 TTS 插件。
 *
 * **注册方式与生命周期**（离线听书实现计划 第 5 节）：由宿主在
 * `configureFlutterEngine` 里用 `flutterEngine.plugins.add(...)` 挂到引擎上，
 * 只拿 applicationContext，不实现 ActivityAware——所以 Activity 退到后台、
 * 被回收、锁屏都不影响它继续读下一句。听书需要的前台身份由 audio_service 提供。
 *
 * **重复注册防护**：audio_service 会缓存一个 FlutterEngine 给界面和后台服务共用，
 * Activity 重建时 `configureFlutterEngine` 会被再次调用；[register] 先查
 * `plugins.has(...)`，避免出现两个 TextToSpeech 抢同一个引擎。
 */
class TtsPlugin : FlutterPlugin, TtsHostApi {
    private lateinit var engine: NativeTtsEngine
    private lateinit var scope: CoroutineScope
    private lateinit var media: ListeningMediaChannel
    private lateinit var preparation: MethodChannel

    override fun onAttachedToEngine(binding: FlutterPluginBinding) {
        val messenger: BinaryMessenger = binding.binaryMessenger
        val context: Context = binding.applicationContext
        media = ListeningMediaChannel(context, messenger)
        // 事件回调统一在主线程发出，Dart 侧串行消费（实现计划 第 7 节）。
        // 兜底异常处理器：单个事件发失败只记日志，不能连带把应用崩掉。
        scope = CoroutineScope(
            Dispatchers.Main.immediate +
                SupervisorJob() +
                CoroutineExceptionHandler { _, error -> Log.w(TAG, "事件协程异常", error) },
        )
        engine = NativeTtsEngine(context, TtsEventsFlutterApi(messenger), scope)
        TtsHostApi.setUp(messenger, this)
        preparation = MethodChannel(messenger, "gtreader/tts_prepare")
        preparation.setMethodCallHandler { call, result ->
            if (call.method == "prepare") {
                engine.prepareSpeech(call.arguments as String)
                result.success(null)
            } else result.notImplemented()
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPluginBinding) {
        TtsHostApi.setUp(binding.binaryMessenger, null)
        preparation.setMethodCallHandler(null)
        engine.dispose()
        media.dispose()
    }

    override fun initialize(enginePackage: String?): TtsInitResultDto =
        engine.initialize(enginePackage)

    override fun listEngines(): List<TtsEngineDto> = engine.listEngines()

    override fun listVoices(): List<TtsVoiceDto> = engine.listVoices()

    override fun setVoice(voiceName: String, locale: String?): Boolean =
        engine.setVoice(voiceName, locale)

    override fun setRate(rate: Double) = engine.setRate(rate)

    override fun speak(utteranceId: String, text: String) = engine.speak(utteranceId, text)

    override fun stop() = engine.stop()

    override fun elapsedRealtime(): Long = android.os.SystemClock.elapsedRealtime()

    override fun setSleepDeadline(version: Long, deadlineMs: Long?) =
        engine.setSleepDeadline(version, deadlineMs)

    /** 只释放引擎，线程保留：停止听书后再点开始要能重新初始化。 */
    override fun shutdown() = engine.release()

    /** 静态方法，不需要引擎实例：长句拆分的上限就取它（实现计划 6.1 第 3 条）。 */
    override fun maxSpeechInputLength(): Long = TextToSpeech.getMaxSpeechInputLength().toLong()

    override fun isLanguageAvailable(locale: String): Boolean = engine.isLanguageAvailable(locale)

    companion object {
        private const val TAG = "GtTts"

        /**
         * 挂到引擎上；同一个引擎重复调用不会注册第二个实例。
         * 「谁注册、注册几次」只在这一处判断，宿主只负责调用。
         */
        fun register(flutterEngine: FlutterEngine) {
            if (flutterEngine.plugins.has(TtsPlugin::class.java)) return
            flutterEngine.plugins.add(TtsPlugin())
        }
    }
}
