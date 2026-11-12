import java.util.Base64

// Flutter 以 Base64 传递每个 dart-define。应用和原书插件共用同一个值，
// 与 Dart 的 bool.fromEnvironment 一致，只有小写 true 才加入原书排版。
extra["gtIncludeOriginalLayout"] = providers.gradleProperty("dart-defines").orNull
    ?.split(',')
    ?.map { String(Base64.getDecoder().decode(it), Charsets.UTF_8) }
    ?.lastOrNull { it.startsWith("GT_INCLUDE_ORIGINAL_LAYOUT=") }
    ?.substringAfter('=') == "true"

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
