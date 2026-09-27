# MP4 修复器 · Flutter 版（mp4fix_flutter）

针对"部分播放器播放卡顿 / 忽快忽慢"的 MP4 文件的**无损修复工具**（Flutter 重写版）。

> 本仓库是 Kotlin 版 `mp4fix` 的 Flutter 重写：**引擎改为纯 Dart**（全平台可用、可 `dart test`），
> UI 全面重构，WebDAV / SAF / 权限等平台能力按 Android 优先设计、代码保持可移植。

## 修复原理（不重新编码、画质无损）

1. 解析 MP4 采样表（stts/stsc/stsz/stco 等），得到每个音/视频样本的偏移、大小、时间戳；
2. 按时间重新切块（目标 ~0.5s 一块、块上限 2MB）并全局合并，把同一时刻的音视频数据写到一起；
3. moov 前置（faststart）、丢弃无用元数据与尾部垃圾；
4. 流式改写 mdat（样本字节原样拷贝，字节级一致）。

## 目录结构

```
lib/src/engine/     纯 Dart 无损修复引擎（零 Flutter 依赖）
  seekable_input.dart   随机读取抽象：本地文件 / 内存（WebDAV Range 后续接入）
  binary.dart           异常、无符号读写、同步输出汇（SyncSink）
  boxes.dart            MP4 盒子扫描
  mp4_inspect.dart      MP4 健康检测（结构 / 交错距离 / faststart / 分片识别）
  mp4_repair.dart       无损重排修复引擎
  engine.dart           对外 barrel
bin/mp4fix_cli.dart      桌面命令行工具（修复 / 检测）
test/                    引擎测试 + 与 Kotlin 旧引擎逐字节对齐的金标准测试
```

## 开发命令

```bash
export PATH=/opt/flutter/bin:$PATH

flutter pub get
dart analyze                     # 静态检查
flutter test                     # 全部测试（13 项）
flutter test --no-pub test/kotlin_parity_test.dart   # 只跑与 Kotlin 引擎的对齐测试

# 命令行（PC）
dart run bin/mp4fix_cli.dart --inspect 文件.mp4
dart run bin/mp4fix_cli.dart 输入.mp4 输出.mp4
```

## 进度（分阶段交付）

- [x] **Phase ①：纯 Dart 引擎**（Mp4Inspect + Mp4Repair）+ 单元测试 + **与 Kotlin 引擎 MD5 逐字节对齐**（13 项测试全绿）
- [ ] **Phase ②：WebDAV**（纯 Dart 客户端 / 扫描 / 修复流水线 + 本地迷你 DAV 服务器测试）
- [ ] **Phase ③：UI 重构**（Material 3：任务列表 / 本地导入 / WebDAV / 设置 / 报告）
- [ ] **Phase ④：Android 集成**（SAF 读写、Android 17 本地网络权限、缓存回退、debug 构建验证）+ CI

## 与 Kotlin 版的差异

| 项 | Kotlin 版 | Flutter 版 |
|---|---|---|
| 引擎 | Kotlin（JVM，Android/桌面） | **纯 Dart**（Android / Windows / Linux / macOS） |
| 一致性 | — | 相同输入输出**逐字节一致**（金标准测试保证） |
| 平台范围 | Android | Android 优先（代码可移植） |

## 许可

沿用原项目的许可与隐私说明（待补）。
