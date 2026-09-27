# MP4 修复器 · Flutter 版

[![ci](https://github.com/U707T/mp4fix/actions/workflows/ci.yml/badge.svg)](https://github.com/U707T/mp4fix/actions/workflows/ci.yml)
[![release](https://img.shields.io/github/v/release/U707T/mp4fix)](https://github.com/U707T/mp4fix/releases/latest)

针对「部分播放器播放卡顿 / 忽快忽慢」的 MP4 文件的**无损修复工具**。
本仓库是 Kotlin 版 `mp4fix` 的 **Flutter 重写**：引擎改为**纯 Dart**（全平台可用、可 `flutter test`），
UI 按 Material 3 重构，WebDAV / SAF / 权限等平台能力按 **Android 优先**设计、代码保持可移植。

## 下载安装

到 [Releases](https://github.com/U707T/mp4fix/releases/latest) 下载对应 APK：

| 文件 | 说明 |
|---|---|
| `MP4Fix-release-arm64-v8a.apk` | 现代手机（推荐） |
| `MP4Fix-release-armeabi-v7a.apk` | 老设备（32 位） |
| `MP4Fix-release-x86_64.apk` | 模拟器 / x86 设备 |
| `MP4Fix-debug-arm64.apk` | 调试版（带日志，体积大） |

> 覆盖安装旧版 Kotlin 应用前请先卸载（签名不同，无法原地升级）。
> 首次访问局域网 WebDAV 时，系统会请求**「本地网络」权限**（Android 17 起必需），请点「允许」。

## 功能

| 入口 | 能力 |
|---|---|
| **本地文件** | 多选 MP4 / M4V / MOV → 自动检测 → 一键无损修复 → 保存到所选文件夹（原文件不动） |
| **文件夹批量** | 递归扫描整个文件夹（Android 走 SAF），只体检或「扫描并修复」；输出文件夹可选成输入文件夹实现就地覆盖 |
| **WebDAV** | 填主机/端口/路径/账号 → 测试连接 → 扫描（**只读 moov，不整档下载**）→ 「上传副本」或「保存到本地（服务器全程只读）」 |
| **设置** | 判定阈值 1/2/4/8 MB、含「可优化」、输出文件夹、主题、清理缓存、关于 |

检测结果：**正常 / 需重排 / 可优化（缺 moov 前置）/ 损坏 / 不支持（分片）**，阈值可调
（几十~几百 MB 的交错距离才是卡顿元凶）。

## 修复原理（不重新编码、画质无损）

1. 解析 MP4 采样表（stts/stsc/stsz/stco 等），得到每个音/视频样本的偏移、大小、时间戳；
2. 按时间重新切块（目标 ~0.5s 一块、块上限 2MB）并全局合并，把同一时刻的音视频数据写到一起；
3. moov 前置（faststart）、丢弃无用元数据与尾部垃圾；
4. 流式改写 mdat（样本字节原样拷贝，字节级一致）。

**与 Kotlin 旧版逐字节一致**：`test/kotlin_parity_test.dart` 用 Kotlin CLI 的产物做金标准，
Dart 引擎输出必须完全相同，杜绝算法漂移。

## 架构

```
lib/src/engine/     纯 Dart 无损修复引擎（零 Flutter 依赖）
  seekable_input.dart   随机读取抽象：本地文件 / 内存 / 预取
  binary.dart           异常、无符号读写、同步输出汇（SyncSink）
  boxes.dart            MP4 盒子扫描
  mp4_inspect.dart      MP4 健康检测（结构 / 交错距离 / faststart / 分片识别）
  mp4_repair.dart       无损重排修复引擎
lib/src/webdav/     WebDAV 扫描 / 修复流水线（纯 Dart：dart:io HttpClient + xml）
  webdav_client.dart    PROPFIND / GET(+Range) / PUT / DELETE / MOVE、Basic 认证、重定向、完整性校验
  prefetch.dart         只预取「盒头 + moov」→ 同步引擎可直接检测远程文件
  webdav_scanner.dart   递归扫描 + 健康分类（不支持 Range 自动降级整档下载）
  webdav_fixer.dart     下载 → 无损重排 → 上传副本 / 保存本地（含唯一命名与大小校验）
lib/src/app/        Material 3 界面（AppController + InheritedNotifier，无额外状态库）
lib/src/platform/   Android 平台通道（SAF 写入 / content:// 复制到缓存）
android/            MainActivity 里的 MethodChannel（`mp4fix/platform`）
bin/mp4fix_cli.dart 桌面命令行（修复 / 检测 / WebDAV 扫描与修复）
tool/dav_dev_server.dart 本地开发用迷你 WebDAV 服务器
```

### 两个关键设计

- **远程检测不整档下载**：引擎是同步随机读，WebDAV 是异步 IO —— 因此先把「顶层盒头 + 整个 moov」
  预取回内存（`prefetch.dart`），再交给同步引擎。几 GB 的远端文件通常只需几百 KB~几十 MB 流量。
- **SAF 写入的数据安全**：`name.mp4fix-part` → 校验大小 → **同名旧文件改名为 `.mp4fix-bak` 让位**
  （而不是先删）→ 改名转正 → 清理备份；任一步失败都会还原旧文件，消除「旧文件已删、新文件没写成」的窗口。

## 开发

```bash
export PATH=/opt/flutter/bin:$PATH

flutter pub get
dart analyze                     # 静态检查
flutter test                     # 全部测试（25 项：引擎 10 + 金标准对齐 3 + WebDAV 12）

# 命令行（PC）
dart run bin/mp4fix_cli.dart --inspect 文件.mp4
dart run bin/mp4fix_cli.dart 输入.mp4 输出.mp4
dart run bin/mp4fix_cli.dart --dav-scan http://192.168.28.156:5244/dav --user admin --pass 密码
dart run bin/mp4fix_cli.dart --dav-fix  http://192.168.28.156:5244/dav --user admin --pass 密码 --threshold 4

# 本地联调
dart run tool/dav_dev_server.dart /tmp/videos 8080
```

### 发布流程

1. 改 `pubspec.yaml` 的 `version: X.Y.Z+N`；
2. push 到 `main` → CI 自动：`test`（analyze + 25 项测试）→ `build-android`（debug + 3 个 release APK）→
   若 `vX.Y.Z` 尚无 tag，则**自动创建 Release 并上传 4 个 APK**（版本号带 `-rc` 后缀会标记为 prerelease）。

## 限制

- 不支持 fragmented MP4（含 moof/mvex）与加密文件；
- 输出总大小超过 4 GB 的文件暂不支持；
- WebDAV 认证仅支持 HTTP Basic；
- Android 端若输入来源不支持随机读取（少数网盘类 provider），会先复制到应用缓存再处理（需要临时空间）；
- 旧版 Kotlin 项目（`/workspace/mp4fix`）保持原样，仅作参考。

## 许可

沿用原项目的许可与隐私说明（待补）。
