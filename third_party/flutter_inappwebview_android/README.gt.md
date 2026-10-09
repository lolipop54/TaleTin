# third_party/flutter_inappwebview_android

从 pub.dev 复制进来的 `flutter_inappwebview_android 1.1.3`（Apache-2.0），
只做了一处修改。

## 为什么放在这里

AGP 9 起，`getDefaultProguardFile('proguard-android.txt')` 由警告变成硬失败
（该文件带 `-dontoptimize`，会挡住 R8 优化）。本项目的 AGP 是 9.1.0，
而这个插件 1.1.3 的 `android/build.gradle` 还在用它，构建直接失败。
上游 issue：https://github.com/pichillilorenzo/flutter_inappwebview/issues/2765

改动（`android/build.gradle` 第 44、48 行）：

```
- proguardFiles getDefaultProguardFile('proguard-android.txt'), ...
+ proguardFiles getDefaultProguardFile('proguard-android-optimize.txt'), ...
```

`proguard-android-optimize.txt` 自 AGP 3.4 起就存在，是官方给的替代文件，
对功能没有影响。

绑定方式见根目录 `pubspec.yaml`：

```yaml
dependency_overrides:
  flutter_inappwebview_android:
    path: third_party/flutter_inappwebview_android
```

## 什么时候可以删掉

上游发布修好这个问题的版本后（`flutter_inappwebview_android` 1.2.0 正式版
出现时先核对它用的 proguard 文件名），删掉本目录与 `dependency_overrides`
里的这三行，恢复用 pub.dev 的版本即可。

同步更新 `docs/原书排版模式实现计划.md` 的依赖说明。
