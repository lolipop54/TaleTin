# 阅读器 Rust 正文库

本目录是正式应用依赖，处理 TXT 分块扫描及 EPUB HTML5 正文转换。TXT UTF-8/UTF-16 不先转码全文；GB18030、GBK 等旧编码由 encoding_rs 解码，直接扫描原字节，不生成临时全文。EPUB 源文档的 UTF-8／UTF-16 也由 Rust 解码。EPUB 的图片、脚注路径由 Dart 按既有规则解析，Rust 生成正文、表格、精确统计和 DOM 来源。Rayon 最多四个线程，小批转换按输入顺序返回。

源文件 SHA-256 使用 sha2，TXT 在同一扫描输入上计算，其他文件按块计算；保留原始字节摘要，不改为解码后的正文摘要。EPUB 统计通过有长度的原字节小批直接在 Rust 解码、建树，避免全章字符串 JSON 往返。属性名比较和统计 run 缓冲区减少分配，保持原有脚注、样式边界和 UTF-16 规则。DEFLATE 使用 flate2，限制实际输出并要求完整压缩流；ZIP 索引、其他压缩方式、路径规则和总量限制仍由 Dart 管理。

普通构建始终启用上述四项。只有 `GT_PROCESSING_EXPERIMENT=true` 构建允许设置 `ProcessingFeatures`，位值 1/2/4/8 分别对应 SHA、原字节、HTML 分配和 DEFLATE。开新 isolate 必须显式传递位值，指针不能跨 isolate。完整实验见 `tools/book_perf/README.md` 和当天消融报告。

原书网页在同一个后台会话中使用 `NativeOriginalHtml`：原始章节字节一次建树，完成净化、英文显示断字并返回自有 HTML 字节。沿用应用已有的 en_US 词典及左右最短长度2／3，保存 UTF-16 新增软连字符位置；标题、代码和样式等仍跳过断字。词典与小量单词结果随会话释放。序列化兼容旧 Dart 两次解析对文档类型的处理，浏览器排版模式也属于结果核对范围。普通构建使用 Rust；仅 `GT_ORIGINAL_EXPERIMENT=true` 允许同包切换旧 Dart 对照。简化模式的 Dart 显示断字继续沿用，不把每个短段落分别送过 FFI。


原生指针不跨 isolate；每个句柄只保留最近一次结果，后续调用或关闭即回收。Dart 在调用期间解码并取得独立字符串，不保存原生字节视图。正常流程 finally 关闭；NativeFinalizer 补充处理 isolate 被终止、finally 未执行的情况，输入和结果结构同样注册回收。Dart 映射回既有 UTF-16 位置口径，自定义章题正则仍由 Dart 判断。正式正文不再绕回平台解码；Android 旧通道仅用于同机对照。旧书修复仍需要的转码文件在后台通过 Rust 生成。FFI 结果转为 Dart 自有字符串仍有传输和转换成本，不能仅以 Rust 内部速度推断整本开书收益。

## 构建

安装 Rust 1.98.1 或兼容工具链，并安装目标 aarch64-linux-android、armv7-linux-androideabi、x86_64-linux-android；Windows x64 使用 MSVC。首次执行 `cargo fetch --locked --manifest-path tools/direct_read_rust/Cargo.toml`。随后正常 Flutter 构建或测试会运行 hook/build.dart；不手工复制 so 文件，运行时不下载依赖。

修改 src/scan.h 后在本包执行 `dart run tool/ffigen.dart <libclang 动态库路径>`，生成文件不直接编辑。Cargo.lock 锁定 Rust 依赖；LICENSE 收录本项目、各 crate 及 Rust 标准库声明，随 Flutter 许可清单分发。旧 Dart 对照位于 test/support，真实手机结果见 docs/TXT与EPUB_Rust实现与验证261014.md。

参考：[html5ever](https://docs.rs/html5ever/0.40.1/html5ever/)、[Rust Android 目标](https://doc.rust-lang.org/rustc/platform-support/android.html)、[Dart C 互操作](https://dart.dev/interop/c-interop)、[Code Assets](https://pub.dev/packages/code_assets)。
