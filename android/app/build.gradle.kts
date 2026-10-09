import java.io.FileInputStream
import java.util.Properties
import java.util.zip.ZipFile

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

android {
    namespace = "com.example.gtreader"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

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
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                logger.warn(
                    "未找到 android/key.properties：release 包将使用调试签名，不能覆盖安装正式包"
                )
                signingConfigs.getByName("debug")
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
    // pigeon 生成的 Kotlin 代码用 suspend 函数回调 Dart（见 TtsApi.g.kt），
    // 需要协程运行时。这是编译期硬依赖，不是可选项：不加这一行
    // com.example.gtreader.tts.TtsApi.g.kt 根本编译不过。
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
}

flutter {
    source = "../.."
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
                    listOf("libapp.so", "libflutter.so", "libsqlite3.so")
                        .map { "lib/$abi/$it" }
                }.filter { path -> (zip.getEntry(path)?.size ?: 0L) <= 0L }
                check(missing.isEmpty()) {
                    "${apk.name} 缺少启动必需文件：${missing.joinToString()}。" +
                        "请确认没有构建期间清理缓存，并重新构建。"
                }
            }
            logger.lifecycle("release APK 启动文件完整：${apk.name} (${abis.joinToString()})")
        }
    }
}
tasks.matching { it.name == "assembleRelease" }.configureEach {
    dependsOn(verifyReleaseApk)
}
