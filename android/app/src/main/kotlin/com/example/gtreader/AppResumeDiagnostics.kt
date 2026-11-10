package com.example.gtreader

import android.app.Activity
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.Process
import android.os.SystemClock
import android.util.Log
import org.json.JSONObject

/** 白屏时 Dart 可能没有机会回调，Android 独立记录窗口与 Flutter 显示状态。 */
internal class AppResumeDiagnostics(private val activity: Activity) {
    private val main = Handler(Looper.getMainLooper())
    private val activityId = System.identityHashCode(activity)
    private val power = activity.getSystemService(PowerManager::class.java)
    private var stoppedAt: Long? = null
    private var resumedAt: Long? = null
    private var flutterDisplaying = false
    private val afterTwoSeconds = Runnable { record("check_2s") }
    private val afterTenSeconds = Runnable { record("check_10s") }

    fun resume() {
        cancelChecks()
        val now = SystemClock.elapsedRealtime()
        resumedAt = now
        record("resume", mapOf("backgroundMs" to stoppedAt?.let { now - it }))
        stoppedAt = null
        main.postDelayed(afterTwoSeconds, 2_000)
        main.postDelayed(afterTenSeconds, 10_000)
    }

    fun stop() {
        stoppedAt = SystemClock.elapsedRealtime()
        record("stop")
        resumedAt = null
        cancelChecks()
    }

    fun destroy() {
        cancelChecks()
        record("destroy")
    }

    fun flutterDisplayed(displayed: Boolean) {
        flutterDisplaying = displayed
        record(if (displayed) "flutter_displayed" else "flutter_hidden")
    }

    fun record(event: String, details: Map<String, Any?> = emptyMap()) {
        // peekDecorView 只查看已有窗口，冷启动记录不会提前创建视图。
        val decor = activity.window.peekDecorView()
        write(activity, "native.$event", mapOf(
            "activity" to activityId,
            "sinceResumeMs" to resumedAt?.let { SystemClock.elapsedRealtime() - it },
            "focus" to decor?.hasWindowFocus(),
            "attached" to decor?.isAttachedToWindow,
            "visibility" to decor?.windowVisibility,
            "width" to decor?.width,
            "height" to decor?.height,
            "interactive" to power?.isInteractive,
            "flutterDisplaying" to flutterDisplaying,
        ) + details)
    }

    private fun cancelChecks() {
        main.removeCallbacks(afterTwoSeconds)
        main.removeCallbacks(afterTenSeconds)
    }

    companion object {
        fun dart(context: Context, event: String?, timeMs: Long?, frameWaitMs: Long?, sendingFrames: Boolean?) {
            // 只接收固定步骤和数字，不允许把路由参数或书籍资料传进此日志。
            when (event) {
                "start", "startup_ready", "resumed", "hidden", "paused", "detached", "first_frame" ->
                    write(context, "dart.$event", mapOf(
                        "dartTimeMs" to timeMs, "frameWaitMs" to frameWaitMs,
                        "sendingFrames" to sendingFrames,
                    ))
            }
        }

        private fun write(context: Context, event: String, details: Map<String, Any?>) {
            val entry = mapOf(
                "event" to event,
                "timeMs" to System.currentTimeMillis(),
                "elapsedMs" to SystemClock.elapsedRealtime(),
                "pid" to Process.myPid(),
            ) + details
            Log.i("GT_APP_RESUME", JSONObject(entry).toString())
            NativeDiagnosticLog.appResume.append(context, entry)
        }
    }
}
