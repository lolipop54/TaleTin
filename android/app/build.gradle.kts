import java.io.FileInputStream
import java.util.Properties
import java.util.zip.ZipFile
import java.util.Base64
import groovy.json.JsonOutput
import groovy.json.JsonSlurper
import com.android.build.api.artifact.SingleArtifact
import org.gradle.api.file.DirectoryProperty
import org.gradle.api.file.FileSystemOperations
import org.gradle.api.provider.Property
import org.gradle.api.tasks.Input
import org.gradle.api.tasks.InputDirectory
import org.gradle.api.tasks.OutputDirectory
import org.gradle.api.tasks.PathSensitive
import org.gradle.api.tasks.PathSensitivity
import org.gradle.api.tasks.TaskAction
import javax.inject.Inject

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 正式签名：android/key.properties（密码与密钥库都不进版本库，见 android/.gitignore）。
// 换机器构建时把 key.properties 与 gtreader-release.jks 带过去即可；两者丢失就再也
// 无法覆盖升级同 applicationId 的应用。
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        FileInputStream(keystorePropertiesFile).use { load(it) }
    }
}

// 临时用调试签名打 release 包（真机试装、给别人试用的包）：打包时加 -P gtDebugSigning=true。
// 默认仍按 key.properties 走正式签名；调试签名包与正式签名包签名不一致，
// 既不能覆盖安装正式包，正式包也不能覆盖它，升级前要先卸载。
val debugSigningRequested = providers.gradleProperty("gtDebugSigning").orNull.toBoolean()
val originalLayoutIncluded = rootProject.extra["gtIncludeOriginalLayout"] as Boolean
val dartDefines = providers.gradleProperty("dart-defines").map { encoded ->
    encoded.split(',').map { String(Base64.getDecoder().decode(it), Charsets.UTF_8) }
}.orElse(emptyList())
fun enabledByDefault(name: String) = dartDefines.map { defines ->
    val value = defines.lastOrNull { it.startsWith("$name=") }?.substringAfter('=') ?: "true"
    require(value == "true" || value == "false") { "$name 只能填写 true 或 false" }
    value == "true"
}
val includeReadingFonts = enabledByDefault("GT_INCLUDE_PRESET_FONTS")
val offlineDictionaryIncluded = enabledByDefault("GT_INCLUDE_OFFLINE_DICTIONARY").get()

android {
    namespace = "com.example.gtreader"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion
    sourceSets.named("main") {
        java.srcDir(if (originalLayoutIncluded) "src/originalLayout/kotlin" else "src/simplifiedLayout/kotlin")
        java.srcDir(if (offlineDictionaryIncluded) "src/offlineDictionary/kotlin" else "src/noOfflineDictionary/kotlin")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.gtreader"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            // 有签名配置就用正式签名；缺 key.properties 时退回调试签名并明确告警，
            // 免得打出一个「能用但不能覆盖升级」的包还以为已经正式签名。
            // 打包时显式加 -P gtDebugSigning=true 则不论有没有 key.properties 都用调试签名。
            signingConfig = when {
                debugSigningRequested -> {
                    logger.warn(
                        "已指定 gtDebugSigning=true：release 包使用调试签名，不能覆盖安装正式签名包"
                    )
                    signingConfigs.getByName("debug")
                }
                keystorePropertiesFile.exists() -> signingConfigs.getByName("release")
                else -> {
                    logger.warn(
                        "未找到 android/key.properties：release 包将使用调试签名，不能覆盖安装正式包"
                    )
                    signingConfigs.getByName("debug")
                }
            }
            // 混淆与资源压缩暂不开启：原书排版用的 WebView 插件带原生代码，
            // 打开 R8 需要额外 keep 规则并做真机回归，等发版前单独验证。
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // 后台执行 WebView 启动中允许离开界面线程的部分，不创建空白页面预热。
    if (originalLayoutIncluded) implementation("androidx.webkit:webkit:1.16.0")
    // pigeon 生成的 Kotlin 代码用 suspend 函数回调 Dart（见 TtsApi.g.kt），
    // 需要协程运行时。这是编译期硬依赖，不是可选项：不加这一行
    // com.example.gtreader.tts.TtsApi.g.kt 根本编译不过。
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
}

flutter {
    source = "../.."
}

// 固定当前引擎的单类补丁；只有原书滚动会显式开启新的绘制调度。
if (originalLayoutIncluded) apply(from = "../texture_draw_patch/patch.gradle")

// 在 Android 合并资产后生成独立副本，不修改 pubspec 或 Flutter 的共享产物。
// 开关是任务输入，连续构建不同配置时会重新生成对应资源。
abstract class FilterReaderAssets : DefaultTask() {
    companion object {
        const val dictionaryDirectory = "flutter_assets/assets/dictionary/"
        val dictionaryLicenses = listOf(
            "flutter_assets/assets/licenses/Offline-dictionary-sources.txt",
            "flutter_assets/assets/licenses/Wiktionary-CC-BY-SA-4.0.txt",
        )
    }

    @get:InputDirectory
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val mergedAssets: DirectoryProperty
    @get:OutputDirectory
    abstract val filteredAssets: DirectoryProperty
    @get:Input
    abstract val includePresetFonts: Property<Boolean>
    @get:Input
    abstract val includeOriginalLayout: Property<Boolean>
    @get:Input
    abstract val includeOfflineDictionary: Property<Boolean>
    @get:Inject
    abstract val fileOperations: FileSystemOperations

    @TaskAction
    fun filter() {
        val include = includePresetFonts.get()
        fileOperations.sync {
            from(mergedAssets)
            into(filteredAssets)
            if (!includeOriginalLayout.get()) exclude("flutter_assets/assets/webview/**")
            if (!includeOfflineDictionary.get()) {
                exclude("$dictionaryDirectory**")
                exclude(dictionaryLicenses)
            }
            if (!include) {
                exclude("flutter_assets/assets/fonts/preset/**")
                exclude("flutter_assets/assets/fonts/preview/**")
            }
        }
        if (!include) {
            val manifest = filteredAssets.file("flutter_assets/FontManifest.json").get().asFile
            val fonts = JsonSlurper().parse(manifest) as List<*>
            val kept = fonts.filter { entry ->
                val family = (entry as Map<*, *>)["family"] as String
                return@filter !family.startsWith("gt-preset-") && !family.startsWith("gt-preview-")
            }
            manifest.writeText(JsonOutput.toJson(kept), Charsets.UTF_8)
        }
    }
}

androidComponents.onVariants { variant ->
    // APK 增量更新会留下被移除模型的空槽，ZIP 清单虽然干净，包体仍然偏大。
    // 禁用这一最终任务的增量输入，重新生成紧凑 APK；前面的编译与资产处理仍复用缓存。
    tasks.matching { it.name == "package${variant.name.replaceFirstChar { it.uppercase() }}" }
        .configureEach { outputs.upToDateWhen { false } }
    val filterTask = tasks.register<FilterReaderAssets>(
        "filter${variant.name.replaceFirstChar { it.uppercase() }}ReaderAssets"
    ) {
        // Flutter 额外向合并资产目录写入文件；必须等它复制完成再过滤。
        dependsOn("copyFlutterAssets${variant.name.replaceFirstChar { it.uppercase() }}")
        includePresetFonts.set(includeReadingFonts)
        includeOriginalLayout.set(originalLayoutIncluded)
        includeOfflineDictionary.set(offlineDictionaryIncluded)
        filteredAssets.set(layout.buildDirectory.dir("filtered_reader_assets/${variant.name}"))
    }
    variant.artifacts.use(filterTask)
        .wiredWithDirectories(FilterReaderAssets::mergedAssets, FilterReaderAssets::filteredAssets)
        .toTransform(SingleArtifact.ASSETS)
}

// 检查最终 APK，而非只看编译是否成功：曾出现 ARM 的启动库未装进包、
// Gradle 却报告成功的情况。这里也覆盖 SQLite 库，避免启动后打不开数据库。
val releaseAbiByPlatform = mapOf(
    "android-arm" to "armeabi-v7a",
    "android-arm64" to "arm64-v8a",
    "android-x64" to "x86_64",
)
val releaseAbis = (findProperty("target-platform") as? String)
    ?.split(",")?.map { releaseAbiByPlatform.getValue(it) }
    ?: releaseAbiByPlatform.values.toList()
// 可单独检查用户拿到的旧包，不触发重新打包。
val apkToVerify = findProperty("verify-release-apk") as? String
val releaseApkDirectory = layout.buildDirectory.dir("outputs/apk/release")
val splitReleaseApks = findProperty("split-per-abi")?.toString() == "true"
val verifyReleaseApk = tasks.register("verifyReleaseApk") {
    if (apkToVerify == null) dependsOn("packageRelease")
    doLast {
        // 只检查本次请求的产物，避免目录里旧的通用包或拆分包干扰检查。
        val apks = if (apkToVerify != null) listOf(file(apkToVerify)) else {
            val names = if (splitReleaseApks) releaseAbis.map { "app-$it-release.apk" }
                else listOf("app-release.apk")
            names.map { releaseApkDirectory.get().file(it).asFile }
        }
        apks.forEach { apk ->
            check(apk.isFile) { "未找到 release APK：${apk.path}" }
            // 按架构拆包时每个 APK 只需包含自身架构；通用包检查全部目标架构。
            val splitAbi = releaseAbis.find { apk.name == "app-$it-release.apk" }
            val abis = splitAbi?.let { listOf(it) } ?: releaseAbis
            ZipFile(apk).use { zip ->
                val missing = abis.flatMap { abi ->
                    listOf("libapp.so", "libflutter.so", "libsqlite3.so", "libgt_reader_native.so", "libtaletin_mobi.so")
                        .map { "lib/$abi/$it" }
                }.filter { path -> (zip.getEntry(path)?.size ?: 0L) <= 0L }
                check(missing.isEmpty()) {
                    "${apk.name} 缺少启动必需文件：${missing.joinToString()}。" +
                        "请确认没有构建期间清理缓存，并重新构建。"
                }
                // 内置端侧 TTS 已退役，最终包不得残留模型或推理库。
                val retiredTts = zip.entries().asSequence().filter {
                    it.name.startsWith("assets/matcha/") || it.name.startsWith("assets/piper/") ||
                        it.name.endsWith(".onnx") || it.name.endsWith("/libonnxruntime.so") ||
                        it.name.endsWith("/libsherpa-onnx-jni.so")
                }.map { it.name }.toList()
                check(retiredTts.isEmpty()) { "${apk.name} 仍包含已移除的内置 TTS 资源：${retiredTts.joinToString()}" }
                val originalAssets = zip.entries().asSequence().any {
                    !it.isDirectory && it.name.startsWith("assets/flutter_assets/assets/webview/")
                }
                val originalShell = zip.getEntry("assets/flutter_assets/assets/webview/paged_host.html")
                check(if (originalLayoutIncluded) (originalShell?.size ?: 0L) > 0L else !originalAssets) {
                    "${apk.name} 的原书排版资源与 GT_INCLUDE_ORIGINAL_LAYOUT 参数不一致"
                }
                val dictionaryFiles = zip.entries().asSequence().filter {
                    !it.isDirectory && it.name.startsWith("assets/${FilterReaderAssets.dictionaryDirectory}")
                }.toList()
                val dictionaryLicenses = FilterReaderAssets.dictionaryLicenses.map { zip.getEntry("assets/$it") }
                check(if (offlineDictionaryIncluded) {
                    dictionaryFiles.size == 2 && listOf("chinese-offline-", "english-offline-").all { prefix ->
                        dictionaryFiles.any {
                            it.name.substringAfterLast('/').startsWith(prefix) &&
                                it.name.endsWith(".sqlite.gz") && it.size > 0L
                        }
                    } && dictionaryLicenses.all { (it?.size ?: 0L) > 0L }
                } else dictionaryFiles.isEmpty() && dictionaryLicenses.all { it == null }) {
                    "${apk.name} 的离线词库或许可与 GT_INCLUDE_OFFLINE_DICTIONARY 参数不一致"
                }
                // 检查实际编入 DEX 的类，而不是 Flutter 自动注册用的空入口。
                val originalClasses = setOf(
                    "Lcom/example/gtreader/OriginalWebViewStartup;",
                    "Lcom/pichillilorenzo/flutter_inappwebview_android/webview/in_app_webview/InAppWebView;",
                )
                val dictionaryClass = "Lcom/example/gtreader/OfflineDictionary;"
                val optionalClasses = originalClasses + dictionaryClass
                val expectedClasses = buildSet {
                    if (originalLayoutIncluded) addAll(originalClasses)
                    if (offlineDictionaryIncluded) add(dictionaryClass)
                }
                val found = mutableSetOf<String>()
                zip.entries().asSequence().filter { it.name.matches(Regex("classes[0-9]*\\.dex")) }
                    .forEach { entry ->
                        val dex = zip.getInputStream(entry).use { String(it.readBytes(), Charsets.ISO_8859_1) }
                        found += optionalClasses.filter { it in dex }
                    }
                check(found == expectedClasses) {
                    "${apk.name} 的原书排版或离线查词 Android 代码与打包参数不一致"
                }
                // 检查真正装进包的文件，避免开关仅隐藏字体列表却没减少包体。
                val presetFiles = zip.entries().asSequence().filter {
                    it.name.startsWith("assets/flutter_assets/assets/fonts/preset/") ||
                        it.name.startsWith("assets/flutter_assets/assets/fonts/preview/")
                }.toList()
                check(if (includeReadingFonts.get()) presetFiles.isNotEmpty() else presetFiles.isEmpty()) {
                    "${apk.name} 的内置字体资源与 GT_INCLUDE_PRESET_FONTS 参数不一致"
                }
                val manifest = zip.getInputStream(zip.getEntry("assets/flutter_assets/FontManifest.json"))
                    .bufferedReader().use { JsonSlurper().parseText(it.readText()) as List<*> }
                val presetEntries = manifest.filter {
                    ((it as Map<*, *>)["family"] as String).let { family ->
                        family.startsWith("gt-preset-") || family.startsWith("gt-preview-")
                    }
                }
                check(if (includeReadingFonts.get()) presetEntries.isNotEmpty() else presetEntries.isEmpty()) {
                    "${apk.name} 的字体注册清单与打包参数不一致"
                }
            }
            logger.lifecycle("release APK 启动文件完整：${apk.name} (${abis.joinToString()})")
        }
    }
}
tasks.matching { it.name == "assembleRelease" }.configureEach {
    dependsOn(verifyReleaseApk)
}
