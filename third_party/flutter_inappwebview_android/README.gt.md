# third_party/flutter_inappwebview_android

从 pub.dev 复制进来的 `flutter_inappwebview_android 1.1.3`（Apache-2.0），
保留项目需要的兼容修复和可选本地资源接口。

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

## 预创建 WebView 的交接

启动时创建的 headless WebView 接入阅读界面后，插件仍需沿用原来的字符串通道编号。
Flutter 分配给实际界面的平台视图编号则是整数；本项目的 Android 绘制确认、截图和停止滚动接口需要这个整数。

`in_app_webview.dart` 在接手时登记实际平台视图编号，controller 的 `getViewId()` 优先返回这个编号。
原来的 `id` 和 MethodChannel 保持不变，网页指令仍能送达；未接入界面的 headless controller 仍返回原编号。
回归测试见项目根目录 `test/platform/android_webview_transfer_test.dart`。

## 原书资源直接读取

`LocalResourceInterceptor` 是可选回调；`InAppWebViewClient` 和
`InAppWebViewClientCompat` 都在原有资源流程前调用它。应用没有登记处理器、
没有绑定当前会话或处理器返回 null 时，继续插件原来的处理。
必须同时保留两个 client 的接入，AndroidX 兼容路径也会实际用于阅读。

资源路径、来源检查和字节读取由应用的 `OriginalBookResources.kt` 负责，
插件不保存书籍、不建立图片缓存，也不允许网页读取任意本地文件。
应用仅绑定已核验的原书目录；未准备的资源仍交回既有 Dart 读取流程。

## 什么时候可以删掉

上游发布修好这个问题的版本后（`flutter_inappwebview_android` 1.2.0 正式版
出现时先核对它用的 proguard 文件名），还需核对 headless 交接后的平台视图编号。
上述兼容问题均被上游修复，并有等价的可选资源接口替代、通过本项目阅读、绘制与翻页检查后，再删掉本目录、
`dependency_overrides` 及仅用于该插件回归测试的 dev_dependency，恢复用 pub.dev 的版本。

同步更新 `docs/原书排版模式实现计划.md` 的依赖说明。
