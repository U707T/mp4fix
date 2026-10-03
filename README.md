# MP4 修复器 · Flutter 版

[![ci](https://github.com/U707T/mp4fix/actions/workflows/ci.yml/badge.svg)](https://github.com/U707T/mp4fix/actions/workflows/ci.yml)
[![release](https://img.shields.io/github/v/release/U707T/mp4fix)](https://github.com/U707T/mp4fix/releases/latest)

针对「部分播放器播放卡顿 / 忽快忽慢」的 MP4 文件的**无损修复工具**。
本仓库是 Kotlin 版 `mp4fix` 的 **Flutter 重写**：引擎改为**纯 Dart**（全平台可用、可 `flutter test`），
UI 按 Material 3 重构，WebDAV / SAF / 权限等平台能力按 **Android 优先**设计、代码保持可移植。

Windows 端支持**把视频 / 文件夹直接拖进窗口**（也可以把文件拖到 `mp4fix.exe` 图标上打开）；
修过的文件会记进「修复记录」，下次扫描直接标「已修复」跳过，不重复干活。

## 下载安装

到 [Releases](https://github.com/U707T/mp4fix/releases/latest) 下载对应 APK：

| 文件 | 平台 | 说明 |
|---|---|---|
| `MP4Fix-release-arm64-v8a.apk` | Android | 现代手机（推荐） |
| `MP4Fix-release-armeabi-v7a.apk` | Android | 老设备（32 位） |
| `MP4Fix-release-x86_64.apk` | Android | 模拟器 / x86 设备 |
| `MP4Fix-debug-arm64.apk` | Android | 调试版（带日志，体积大） |
| `MP4Fix-windows-x64.zip` | Windows 10/11 x64 | 解压后运行 `mp4fix.exe`（绿色免安装） |

> 覆盖安装旧版 Kotlin 应用前请先卸载（签名不同，无法原地升级）。
> 首次访问局域网 WebDAV 时，系统会请求**「本地网络」权限**（Android 17 起必需），请点「允许」。

## 功能

| 入口 | 能力 |
|---|---|
| **本地文件** | 多选 MP4 / M4V / MOV 或 **拖入窗口**（Windows）→ 自动检测 → 一键修复（原文件不动；**默认存到「下载/MP4Fix」**）；顶部可按 **全部 / 待处理 / 待优化 / 正常 / 问题 / 已完成** 筛选；「全部处理」连正常文件一起重排 |
| **文件夹批量** | 递归扫描整个文件夹（Android 走 SAF），只体检或「扫描并修复」；输出文件夹可选成输入文件夹实现就地覆盖；已修过的文件会标「已修复」跳过 |
| **WebDAV** | 填主机/端口/路径/账号 → 测试连接 → 扫描（**只读 moov，不整档下载**）→ 「上传副本」或「保存到本地（服务器全程只读）」 |
| **设置** | 判定阈值 1/2/4/8 MB、含「可优化」、输出文件夹、**文件命名规则**（原名 / 加前缀 / 加后缀）、**修复记录**开关与清空、主题、清理缓存、关于 |

检测结果：**正常 / 需重排 / 可优化（缺 moov 前置）/ 损坏 / 不支持（分片） / 已修复（复用上次结果）**，阈值可调
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
  repair_ledger.dart    修复记录：文件指纹（名称+大小+修改时间）→ 产物位置，扫描时复用
lib/src/platform/   Android 平台通道（SAF 写入 / content:// 复制到缓存 / 产物存在性查询）
android/            MainActivity 里的 MethodChannel（`mp4fix/platform`）
bin/mp4fix_cli.dart 桌面命令行（修复 / 检测 / WebDAV 扫描与修复）
tool/dav_dev_server.dart 本地开发用迷你 WebDAV 服务器
```

### 两个关键设计

- **远程检测不整档下载**：引擎是同步随机读，WebDAV 是异步 IO —— 因此先把「顶层盒头 + 整个 moov」
  预取回内存（`prefetch.dart`），再交给同步引擎。几 GB 的远端文件通常只需几百 KB~几十 MB 流量。
- **SAF 写入的数据安全**：`name.mp4fix-part` → 校验大小 → **同名旧文件改名为 `.mp4fix-bak` 让位**
  （而不是先删）→ 改名转正 → 清理备份；任一步失败都会还原旧文件，消除「旧文件已删、新文件没写成」的窗口。

## 测试（79 项，`flutter test`）

| 测试文件 | 覆盖 |
|---|---|
| `mp4_inspect_test.dart` | 检测器：正常 / 交错不良 / v1 mdhd / 截断 / 阈值行为 |
| `mp4_repair_test.dart` | 修复：样本数保持 / v1 mdhd 真正重排 / 截断报错 / 取消 |
| `kotlin_parity_test.dart` | **与 Kotlin 旧引擎逐字节对齐**（金标准） |
| `lossless_test.dart` | **无损不变量**：独立实现的解析器逐样本比对 大小 / 时间戳 / 描述 / **载荷字节** |
| `mp4_hardening_test.dart` | 损坏的采样表计数不再触发超大分配（防 OOM 回归） |
| `robustness_fuzz_test.dart` | 模糊测试：210 次随机字节破坏 / 截断 / 纯随机数据，检测不抛异常、修复只抛可捕获异常 |
| `engine_edge_test.dart` | moov 后置（可优化 → 修复后 faststart）、co64 64 位偏移表 |
| `webdav_test.dart` | WebDAV 端到端 12 项（中文/空格路径、Range 降级、认证、取消、产物字节校验…） |
| `webdav_util_test.dart` | URL 工具 + **服务端提前断开时识别"下载不完整"** |
| `output_target_test.dart` | 落位安全：同名覆盖 / **失败还原旧文件** / 自动建目录 / 记录用位置信息 |
| `name_rule_test.dart` | 命名规则：原名 / 前缀 / 后缀 / 非法字符 / 设置往返 |
| `repair_ledger_test.dart` | 修复记录：指纹 / 存盘载入 / 淘汰 / 坏文件容错 |
| `job_filter_test.dart` | 状态与筛选分组（待处理 / 待优化 / 正常 / 问题 / 已完成） |
| `folder_scan_test.dart` | 目录列举：只挑视频、跳过隐藏目录、容忍无权限子目录 |
| `error_message_test.dart` · `settings_test.dart` | 错误文案映射 · 设置 JSON 往返 |

额外夹具由 `tool/make_extra_fixtures.py` 生成（`moov_last.mp4` / `co64.mp4`）。

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
2. push 到 `main` → CI 自动：`test`（analyze + 79 项测试）→ `build-android`（debug + 3 个 release APK）→
   若 `vX.Y.Z` 尚无 tag，则**自动创建 Release 并上传 4 个 APK**（版本号带 `-rc` 后缀会标记为 prerelease）。

## 本版要点（v2.4.0）

- **Windows 拖入**：整个窗口都是拖放区，把视频 / 文件夹拖进来即导入「本地文件」并自动体检；
  也支持把文件拖到 `mp4fix.exe` 上（命令行参数）打开；
- **修复记录（不重复干活）**：修好的文件按「名称 + 大小 + 修改时间」指纹记账，
  重新扫描时直接标「已修复（复用上次结果）」并跳过（Android 上还会确认产物确实还在）；
  单个任务可以「重做」；设置里可关闭或清空记录；
- **全部处理**：一键把「需重排 / 可优化 / 正常」的文件全部重排（正常文件会弹确认，说明代价）；
- **筛选按钮**：列表上方新增 全部 / 待处理 / 待优化 / 正常 / 问题 / 已完成 分组，
  一眼看清哪些是待处理、哪些是待优化；
- **文件命名规则**（设置 → 文件命名）：原名（同名覆盖）/ 加前缀 / 加后缀 / 前缀+后缀，
  对所有输出生效（WebDAV 上传副本没改名时保底 `_fixed`，避免覆盖服务器原文件）；
- Windows 默认输出改到**「下载/MP4Fix」**，页面右上角可**打开输出文件夹**（并定位到最近一次产物）；
- 修复同一文件不再在「下载/MP4Fix」里堆出 `xxx (1).mp4`（Android MediaStore 改为同名覆盖）；
- 文件夹扫描（Android）补上总数进度；新增 `name_rule_test` / `repair_ledger_test` / `job_filter_test`，
  测试总数 79。

### 更早（v2.1.0）

- 修复「本地文件」修复失败的 bug：默认输出目录不存在时没有先创建父目录
  （`PathNotFoundException`），现在写入前会建好目录，并且 IO 错误会显示成可操作的中文提示；
- Android 默认输出改到**公共「下载/MP4Fix」**（MediaStore，无需权限）—— 之前落在应用私有目录，
  文件管理器里找不到；
- 失败 / 取消的任务在列表里可以直接「重试」；
- 引擎加固（RC 复查遗留项）：采样表长度自洽校验（损坏/恶意文件不再可能触发超大分配 → OOM）、
  32 位偏移放不下时**真正启用 co64**（不再是死代码）、切块不跨 sample description；
- 新增 `test/mp4_hardening_test.dart`（3 项），总测试数 28。

## 签名与升级安装

- release / debug APK 均使用**固定的发布密钥**签名（本地由 `android/key.properties` 提供，
  CI 由仓库 Secrets 注入，密钥**不落库**）→ 同一签名的包可以**直接覆盖安装**，
  升级不再需要先卸载；
- 从 v2.1.x 及更早版本（每次构建都用随机 debug 密钥签名）升级到 v2.2.0 需**卸载一次**，
  之后所有版本之间都无需卸载；
- 密钥库与口令保存在工作区 `my-project/mp4fix-release-key/`（`mp4fix-release.jks` +
  `keystore-credentials.txt`），请妥善备份 —— 丢了这个文件就无法再签出可覆盖安装的包。

## Windows 版说明

- 解压 `MP4Fix-windows-x64.zip` 后直接运行 `mp4fix.exe`（不需要安装，也不写注册表）；
- **拖放**：把视频 / 文件夹从资源管理器拖到窗口里即可导入（导入后自动体检）；
- **用 MP4Fix 打开**：把文件拖到 `mp4fix.exe` 图标上，或用「打开方式」选择它；
- 默认输出到**「下载/MP4Fix」**，页面右上角的文件夹按钮会在资源管理器里定位到最近一次产物；
- 输出文件夹用系统目录选择器选；WebDAV 的「本地网络权限」只与 Android 有关，Windows 不需要；
- 引擎与 Android 完全同一套（纯 Dart），修复结果逐字节一致。

## 限制

- 不支持 fragmented MP4（含 moof/mvex）与加密文件；
- 输出总大小超过 4 GB 的文件暂不支持；
- WebDAV 认证仅支持 HTTP Basic；
- Android 端若输入来源不支持随机读取（少数网盘类 provider），会先复制到应用缓存再处理（需要临时空间）；
- 旧版 Kotlin 项目（`/workspace/mp4fix`）保持原样，仅作参考。

## 许可

沿用原项目的许可与隐私说明（待补）。
