package com.example.gtreader.tts

import android.app.ActivityManager
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** 只查询本应用媒体服务；焦点仍统一由 audio_session 管理。 */
class ListeningMediaChannel(context: Context, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "gtreader/listening_media")
    private val handler = Handler(Looper.getMainLooper())
    private val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "awaitForeground") result.notImplemented()
            else awaitForeground(SystemClock.elapsedRealtime() + 5000, result)
        }
    }

    @Suppress("DEPRECATION") // API 26 后仍可查询本应用服务。
    private fun awaitForeground(deadline: Long, result: MethodChannel.Result) {
        val ready = manager.getRunningServices(Int.MAX_VALUE).any {
            it.service.className == "com.ryanheise.audioservice.AudioService" && it.foreground
        }
        when {
            ready -> result.success(null)
            SystemClock.elapsedRealtime() >= deadline ->
                result.error("media_not_ready", "后台媒体服务未能启动，请回到应用重试", null)
            else -> handler.postDelayed({ awaitForeground(deadline, result) }, 25)
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        handler.removeCallbacksAndMessages(null)
    }
}
