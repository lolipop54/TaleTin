package com.example.gtreader

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel

/** 阅读页订阅期间监听系统通知，不用高频轮询电量或重建正文。 */
class DeviceStatus(context: Context, engine: FlutterEngine) : EventChannel.StreamHandler {
    private val context = context.applicationContext
    private var receiver: BroadcastReceiver? = null

    init {
        EventChannel(engine.dartExecutor.binaryMessenger, "gtreader/device_status")
            .setStreamHandler(this)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        onCancel(null)
        val listener = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                events.success(null)
            }
        }
        receiver = listener
        ContextCompat.registerReceiver(context, listener, IntentFilter().apply {
            addAction(Intent.ACTION_TIME_TICK)
            addAction(Intent.ACTION_TIME_CHANGED)
            addAction(Intent.ACTION_TIMEZONE_CHANGED)
            // 粘性广播同时提供首次通知，之后充电和电量变化都会刷新。
            addAction(Intent.ACTION_BATTERY_CHANGED)
        }, ContextCompat.RECEIVER_NOT_EXPORTED)
    }

    override fun onCancel(arguments: Any?) {
        receiver?.let(context::unregisterReceiver)
        receiver = null
    }
}
