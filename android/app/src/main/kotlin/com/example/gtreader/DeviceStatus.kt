package com.example.gtreader

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel

/** 阅读页订阅期间监听系统通知，不用高频轮询电量或重建正文。 */
class DeviceStatus : FlutterPlugin, EventChannel.StreamHandler {
    private lateinit var context: Context
    private var channel: EventChannel? = null
    private var receiver: BroadcastReceiver? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = EventChannel(binding.binaryMessenger, "gtreader/device_status").also {
            it.setStreamHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        onCancel(null)
        channel?.setStreamHandler(null)
        channel = null
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

    companion object {
        fun register(engine: FlutterEngine) {
            // 导航方式切换可重建 Activity，但 audio_service 会保留同一个引擎。
            // 重设 EventChannel 会丢失它内部的活动订阅，旧 Dart 订阅取消时就会报错，
            // 旧广播也无法正常释放。随引擎只注册一次，窗口重建不打断现有通知。
            if (engine.plugins.has(DeviceStatus::class.java)) return
            engine.plugins.add(DeviceStatus())
        }
    }
}
