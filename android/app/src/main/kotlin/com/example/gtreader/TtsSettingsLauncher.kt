package com.example.gtreader

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.speech.tts.TextToSpeech
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** 系统设置需要当前 Activity；TTS 引擎自身仍独立于 Activity。 */
object TtsSettingsLauncher {
    fun register(activity: Activity, engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, "gtreader/tts_settings")
            .setMethodCallHandler { call, result ->
                if (call.method != "open") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val install = call.argument<Boolean>("install") == true
                val intent = if (install) {
                    Intent(TextToSpeech.Engine.ACTION_INSTALL_TTS_DATA).apply {
                        call.argument<String>("engine")?.let { setPackage(it) }
                    }
                } else Intent("com.android.settings.TTS_SETTINGS")
                try {
                    activity.startActivity(intent)
                    result.success(true)
                } catch (_: ActivityNotFoundException) {
                    result.success(false)
                } catch (_: SecurityException) {
                    result.success(false)
                }
            }
    }
}
