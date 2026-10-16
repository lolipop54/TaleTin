package com.example.gtreader

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.view.KeyEvent
import android.view.MotionEvent
import android.os.SystemClock
import android.util.Log
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.widget.Toast
import com.example.gtreader.tts.TtsPlugin
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * 宿主 Activity：注册文档读取平台通道，并在主线程弹出 SAF 文件选择器。
 *
 * 书籍主入口使用应用内目录和扫描；SAF 保留为文档通道能力。
 * LocalBookFiles 单独处理共享存储授权，不改变备份的系统文档选择流程。
 *
 * 基类用 audio_service 的 AudioServiceActivity（它就是 FlutterActivity 加一句
 * provideFlutterEngine）：听书要能在锁屏和后台继续，媒体服务必须和界面共用同一个
 * FlutterEngine，不能让 Activity 退出时把引擎带走（离线听书实现计划 第 5、9 节）。
 * 原有 configureFlutterEngine / SAF 通道与它不是一回事，全部保留。
 */
class MainActivity : AudioServiceActivity(), DocumentPicker {
    // 诊断包只记触摸边界，对照 Android 收到事件与 Flutter 接到事件的时差。
    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
        if (PageCapture.traceInput && event.actionMasked != MotionEvent.ACTION_MOVE) {
            Log.i("GT_TURN_NATIVE", "wall=${System.currentTimeMillis()} touch=${event.actionMasked} down=${event.downTime} event=${event.eventTime} received=${SystemClock.uptimeMillis()} x=${event.x} y=${event.y} pointers=${event.pointerCount}")
        }
        return super.dispatchTouchEvent(event)
    }
    private var localBookFiles: LocalBookFiles? = null
    private var backupDocuments: BackupDocuments? = null
    override fun dispatchKeyEvent(event: KeyEvent): Boolean =
        if (ReadingWindow.onKey(event)) true else super.dispatchKeyEvent(event)

    override fun onPause() {
        ReadingWindow.pause()
        super.onPause()
    }

    override fun onStart() {
        super.onStart()
        PageCapture.setForeground(true)
    }

    override fun onStop() {
        PageCapture.setForeground(false)
        super.onStop()
    }

    override fun onTrimMemory(level: Int) {
        PageCapture.release()
        super.onTrimMemory(level)
    }

    override fun onDestroy() {
        PageCapture.setForeground(false)
        super.onDestroy()
    }

    /** 等待选择结果的一次性回调；同时只允许一个选择器在弹。 */
    private var pendingPick: ((List<PickedDocumentDto>) -> Unit)? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 进程被回收后重建时，选择器结果已经无法交付，清掉悬挂回调
        pendingPick = null
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        backupDocuments = BackupDocuments(this, flutterEngine)
        localBookFiles = LocalBookFiles(this, flutterEngine)
        PageCapture.register(flutterEngine)
        OriginalWebViewStartup.register(applicationContext, flutterEngine)
        ReadingWindow.register(this, flutterEngine)
        DeviceStatus(applicationContext, flutterEngine)
        SystemToast.register(applicationContext, flutterEngine)
        ReadingFonts.register(applicationContext, flutterEngine)
        TtsSettingsLauncher.register(this, flutterEngine)
        // 听书的原生 TTS：挂在引擎上，不跟 Activity 生命周期走（离线听书实现计划 第 5 节）
        TtsPlugin.register(flutterEngine)
        DocumentHostApi.setUp(
            flutterEngine.dartExecutor.binaryMessenger,
            DocumentHostApiImpl(applicationContext, this),
        )
        // 设备能力（字体名解析；S14 会在这条通道上加窗口亮度）
        DeviceHostApi.setUp(
            flutterEngine.dartExecutor.binaryMessenger,
            DeviceHostApiImpl(this),
        )
    }

    override fun startPick(onResult: (List<PickedDocumentDto>) -> Unit) {
        mainHandler.post {
            if (pendingPick != null) {
                // 上一次选择还没结束，直接把这次当成取消
                onResult(emptyList())
                return@post
            }
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                // 系统选择器按 MIME 类型筛选，返回后再核对文件后缀。
                type = "*/*"
                putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("text/plain", "application/epub+zip"))
                putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            }
            pendingPick = onResult
            try {
                @Suppress("DEPRECATION")
                startActivityForResult(intent, REQUEST_PICK_DOCUMENTS)
            } catch (_: ActivityNotFoundException) {
                pendingPick = null
                onResult(emptyList())
            }
        }
    }

    @Deprecated("SAF 选择结果回调：FlutterActivity 不是 ComponentActivity，沿用旧 API")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (localBookFiles?.onResult(requestCode) == true) return
        if (backupDocuments?.onResult(requestCode, resultCode, data) == true) return
        if (requestCode == REQUEST_PICK_DOCUMENTS) {
            val callback = pendingPick
            pendingPick = null
            callback?.invoke(readPickedDocuments(resultCode, data))
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onRequestPermissionsResult(code: Int, permissions: Array<out String>, results: IntArray) {
        super.onRequestPermissionsResult(code, permissions, results)
        localBookFiles?.onResult(code)
    }

    private fun readPickedDocuments(
        resultCode: Int,
        data: Intent?,
    ): List<PickedDocumentDto> {
        if (resultCode != Activity.RESULT_OK || data == null) return emptyList()
        val uris = mutableListOf<Uri>()
        val clip = data.clipData
        if (clip != null) {
            for (index in 0 until clip.itemCount) {
                clip.getItemAt(index).uri?.let { uris.add(it) }
            }
        } else {
            data.data?.let { uris.add(it) }
        }
        val documents = uris.map { toPickedDocument(it) }
        // text/plain 也可能对应 .log 等文件，只让 TXT、EPUB 进入导入列表。
        val supported = documents.filter {
            it.name.endsWith(".txt", ignoreCase = true) ||
                it.name.endsWith(".epub", ignoreCase = true)
        }
        if (supported.size != documents.size) {
            Toast.makeText(this, "仅支持选择 TXT、EPUB 文件", Toast.LENGTH_SHORT).show()
        }
        return supported
    }

    private fun toPickedDocument(uri: Uri): PickedDocumentDto {
        var name = uri.lastPathSegment ?: "未命名文件"
        var size: Long? = null
        try {
            contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (nameIndex >= 0 && !cursor.isNull(nameIndex)) {
                        name = cursor.getString(nameIndex)
                    }
                    val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) {
                        size = cursor.getLong(sizeIndex)
                    }
                }
            }
        } catch (_: Exception) {
            // 个别提供方不支持查询，退回 URI 末段作为名称
        }
        return PickedDocumentDto(uri.toString(), name, size)
    }

    private companion object {
        const val REQUEST_PICK_DOCUMENTS = 0x6701
    }
}
