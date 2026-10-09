package com.example.gtreader

import android.app.Activity
import android.content.Context
import android.graphics.Typeface
import android.os.BatteryManager
import android.os.Build
import android.provider.Settings
import android.view.WindowManager

/**
 * 设备能力的平台实现（pigeons/document_host_api.dart）。
 *
 * - 字体名解析：Android 10（API 29）起 [Typeface.getSystemFontFamilyName] 能给出
 *   系统实际使用的字体族名，因此「楷体没装、回退到默认字体」在界面上能看出来；
 * - 窗口亮度：只改本应用的窗口属性（`screenBrightness`），不动系统设置，
 *   离开阅读页把属性设回 `BRIGHTNESS_OVERRIDE_NONE` 即恢复原亮度；
 * - 电量：读一次 [BatteryManager] 的百分比。
 *
 * 全部在后台线程调用，失败一律返回 null，不在 Dart 侧猜值。
 */
class DeviceHostApiImpl(private val activity: Activity) : DeviceHostApi {

    override fun resolveFontFamilies(families: List<String>): List<FontFamilyDto> =
        families.map { family ->
            val requested = family
            val resolved = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                try {
                    val typeface = if (family.isEmpty()) {
                        Typeface.DEFAULT
                    } else {
                        Typeface.create(family, Typeface.NORMAL)
                    }
                    // 请求的族不在系统字体表里时，这里拿到的是回退后的族名
                    typeface.systemFontFamilyName
                } catch (_: Exception) {
                    null
                }
            } else {
                null
            }
            FontFamilyDto(requested, resolved)
        }

    override fun setWindowBrightness(value: Double?) {
        // 界面线程改窗口属性
        activity.runOnUiThread {
            val attributes = activity.window.attributes
            attributes.screenBrightness = value
                ?.coerceIn(0.0, 1.0)
                ?.toFloat()
                ?: WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
            activity.window.attributes = attributes
        }
    }

    override fun systemBrightness(): Double? = try {
        val raw = Settings.System.getInt(
            activity.contentResolver,
            Settings.System.SCREEN_BRIGHTNESS,
        )
        (raw / 255.0).coerceIn(0.0, 1.0)
    } catch (_: Exception) {
        // 个别定制系统读不到，界面按「拿不到」处理
        null
    }

    override fun batteryLevel(): Long? = try {
        val manager = activity.getSystemService(Context.BATTERY_SERVICE) as BatteryManager
        // Dart 侧 int 对应 Kotlin Long
        manager.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
            .takeIf { it in 0..100 }
            ?.toLong()
    } catch (_: Exception) {
        null
    }
}
