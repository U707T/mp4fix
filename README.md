# MP4 修复器 · Flutter 版

[![ci](https://github.com/U707T/mp4fix/actions/workflows/ci.yml/badge.svg)](https://github.com/U707T/mp4fix/actions/workflows/ci.yml)
[![release](https://img.shields.io/github/v/release/U707T/mp4fix)](https://github.com/U707T/mp4fix/releases/latest)

针对「部分播放器播放卡顿 / 忽快忽慢」的 MP4 文件的**无损修复工具**。
本仓库是 Kotlin 版 `mp4fix` 的 **Flutter 重写**：引擎改为**纯 Dart**（全平台可用、可 `flutter test`），
UI 按 Material 3 重构，WebDAV / SAF / 权限等平台能力按 **Android 优先**设计、代码保持可移植。

Windows 端支持**把视频 / 文件夹直接拖进窗口**（也可以把文件拖到 `mp4fix.exe` 图标上打开）；
修过的文件会记进「修复记录」，下次扫描直接标「已修复」跳过，不重复干活。
分片（fragmented）MP4（含 `moof/mvex` 的录制文件）也能识别，并可**无损转换为标准 MP4**。

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
| **文件夹批量** | 递归扫描整个文件夹（Android 走 SAF；**只读预取体检，不整份复制**），只体检或「扫描并修复」；输出文件夹可选成输入文件夹实现就地覆盖；已修过的文件会标「已修复」跳过 |
| **WebDAV** | 填主机/端口/路径/账号 → 测试连接 → 扫描（**只读盒头 / moov / moof，不整档下载**）→ 「上传副本」或「保存到本地（服务器全程只读）」 |
| **设置** | 判定阈值 1/2/4/8 MB、含「可优化」、输出文件夹、**文件命名规则**（原名 / 加前缀 / 加后缀）、**修复记录**开关与清空、主题、清理缓存、关于 |

检测结果：**正常 / 需重排 / 可优化（缺 moov 前置 / 分片 MP4）/ 损坏 / 已修复（复用上次结果）**，阈值可调
（几十~几百 MB 的交错距离才是卡顿元凶；分片 MP4 会按同一套规则判定，修复时无损转换为标准 MP4）。

## 修复原理（不重新编码、画质无损）

0. 分片（fragmented）MP4：先解析 `moof/traf/trun` 汇总样本（大小 / 时长 / 时间戳 / 关键帧），
   再按下面步骤无损“扁平化”为标准 MP4（去掉 `mvex` 与分片结构，必要时补全时长 / 用 `elst` 保留同步）；
1. 解析 MP4 采样表（stts/stsc/stsz/stco 等），得到每个音/视频样本的偏移、大小、时间戳；
2. 按时间重新切块（目标 ~0.5s 一块、块上限 2MB）并全局合并，把同一时刻的音视频数据写到一起；
3. moov 前置（faststart）、丢弃无用元数据与尾部垃圾；
4. 流式改写 mdat（样本字节原样拷贝，字节级一致）。

**与 Kotlin 旧版逐字节一致**（非分片路径）：`test/kotlin_parity_test.dart` 用 Kotlin CLI 的产物做金标准，
Dart 引擎输出必须完全相同，杜绝算法漂移；分片转换为新增能力（Kotlin 旧版无对应）。

## 架构

```
lib/src/engine/     纯 Dart 无损修复引擎（零 Flutter 依赖）
  seekable_input.dart   随机读取抽象：本地文件 / 内存 / 预取
  binary.dart           异常、无符号读写、同步输出汇（SyncSink）
  boxes.dart            MP4 盒子扫描
  mp4_inspect.dart      MP4 健康检测（结构 / 交错距离 / faststart / 分片识别）
  mp4_fragments.dart    分片（fragmented）MP4 解析：moof/traf/trun → 样本表
  mp4_repair.dart       无损重排修复引擎（含分片 → 标准 MP4 的扁平化转换）
lib/src/webdav/     WebDAV 扫描 / 修复流水线（纯 Dart：dart:io HttpClient + xml）
  webdav_client.dart    PROPFIND / GET(+Range) / PUT / DELETE / MOVE、Basic 认证、重定向、完整性校验
  prefetch.dart         预取「盒头 + moov + 各 moof」→ 同步引擎可直接检测远程文件
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

## 测试（96 项，`flutter test`）

| 测试文件 | 覆盖 |
|---|---|
| `mp4_inspect_test.dart` | 检测器：正常 / 交错不良 / v1 mdhd / 截断 / 阈值行为 |
| `mp4_repair_test.dart` | 修复：样本数保持 / v1 mdhd 真正重排 / 截断报错 / 取消 |
| `kotlin_parity_test.dart` | **与 Kotlin 旧引擎逐字节对齐**（金标准） |
| `lossless_test.dart` | **无损不变量**：独立实现的解析器逐样本比对 大小 / 时间戳 / 描述 / **载荷字节** |
| `mp4_hardening_test.dart` | 损坏的采样表计数不再触发超大分配（防 OOM 回归） |
| `robustness_fuzz_test.dart` | 模糊测试：普通 + 分片夹具各 210 次随机字节破坏 / 截断 / 随机数据，检测不抛异常、修复只抛可捕获异常 |
| `engine_edge_test.dart` | moov 后置（可优化 → 修复后 faststart）、co64 64 位偏移表 |
| `fragmented_test.dart` | **分片 MP4**：检测分类 / 无损扁平化（逐样本比对，含 moov 表 + 分片混合写法）/ 距离改进 / 取消 / 截断 |
| `android_prefetch_test.dart` | Android 只读预取协议：区间解析后直接检测；`not_seekable` 正确降级 |
| `webdav_test.dart` | WebDAV 端到端 13 项（中文/空格路径、Range 降级、认证、取消、分片 MP4 远程检测与修复、产物字节校验…） |
| `webdav_util_test.dart` | URL 工具 + **服务端提前断开时识别"下载不完整"** |
| `output_target_test.dart` | 落位安全：同名覆盖 / **失败还原旧文件** / 自动建目录 / 记录用位置信息 |
| `name_rule_test.dart` | 命名规则：原名 / 前缀 / 后缀 / 非法字符 / 设置往返 |
| `repair_ledger_test.dart` | 修复记录：指纹 / 存盘载入 / 淘汰 / 坏文件容错 |
| `job_filter_test.dart` | 状态与筛选分组（待处理 / 待优化 / 正常 / 问题 / 已完成） |
| `folder_scan_test.dart` | 目录列举：只挑视频、跳过隐藏目录、容忍无权限子目录 |
| `error_message_test.dart` · `settings_test.dart` | 错误文案映射 · 设置 JSON 往返 |

额外夹具由 `tool/make_extra_fixtures.py` 生成（`moov_last.mp4` / `co64.mp4`）；
分片夹具由 `tool/make_fragmented_fixture.py` 生成（`fragmented.mp4` / `fragmented_hybrid.mp4` / `fragmented_bad.mp4`）。

## 开发

```bash
export PATH=/opt/flutter/bin:$PATH

flutter pub get
dart analyze                     # 静态检查
flutter test                     # 全部测试（96 项：引擎 / 无损 / 金标准 / 分片 / WebDAV …）

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
2. push 到 `main` → CI 自动：`test`（analyze + 96 项测试）→ `build-android`（debug + 3 个 release APK）→
   若 `vX.Y.Z` 尚无 tag，则**自动创建 Release 并上传 4 个 APK**（版本号带 `-rc` 后缀会标记为 prerelease）。

## 本版要点（v2.5.1 · 全面审查：该修的修、该优化的优化）

- **修复**：文件夹「扫描并修复」此前会**连损坏 / 正常 / 失败的文件也一起重试**（把「损坏」覆盖成
  「失败」、白干活）；现在与「修复 N 项」一致 —— 只处理该处理的（需重排；可优化按设置；正常仅「全部处理」）；
- **修复**：设置里的「同时处理『可优化』」此前没有真正生效 —— 批量修复 / 计数 / 「修复 N 项」按钮
  现在都遵循该开关（单条「修复这条」仍可手动修，不受限制）；
- **修复（Android）**：写 SAF 文件夹的两个边界 —— `.part` 写到一半失败会残留垃圾；旧文件改名
  `.mp4fix-bak` 让位后若创建新文件抛错，旧文件会“消失”。现在都会正确清理 / 还原；
- **优化（Android）**：文件夹批量检测不再**把每个视频整份复制到缓存**才体检 —— 新增平台侧
  「只读预取」（文件描述符随机读盒头 / moov / moof，与 WebDAV 同一思路），来源不支持随机读时
  自动退回复制；真正修复时才复制。几百 MB 的文件检测不再产生等量缓存副本；
- **优化（WebDAV）**：预取改为**窗口化顺序读取**（16KB 窗口 + 复用，小盒顺路覆盖）。
  普通文件扫描从 ~3 个请求降到 1 个；分片 MP4 从"每片段 3 个"降到"每片段 1 个"
  （8 分片：24 → 9 个请求；283 分片量级：约 850 → 约 290）；
- **修复**：WebDAV 表单主机栏直接粘贴整串地址（`http://host:port/path`）现在能正确拆开（旧版行为回归）；
- **修复**：引擎错误进入界面时不再带 `RepairException:` 前缀；
- 测试 91 → 96：批量选择规则 / 平台预取协议（含 `not_seekable` 降级）/ URL 拆分 / 错误文案。

## 本版要点（v2.5.0 · 分片（fragmented）MP4 支持）

- **检测：分片 MP4 不再“不支持”** —— 解析 `moof/traf/trun` 得到样本后按同一套规则判定：
  交错距离 ≥ 阈值 →「需重排」，否则 →「可优化」（列表里显示分片数量与距离指标）；
- **修复：无损“扁平化”为标准 MP4** —— 汇总分片样本 → 重建采样表（stts/stsc/stsz/stco/stss/ctts）→
  去掉 `mvex` / 分片结构 → moov 前置 → 按时间重排音视频（样本字节原样拷贝、画质无损；
  补全 mvhd/mdhd/tkhd 时长，tfdt 起点不一致时用 `elst` 空编辑保留同步）；
- **WebDAV 远程扫描**：预取范围加上每个 `moof`（通常仅几 KB），仍不整档下载；
- **测试**：新增 3 个夹具 —— `fragmented.mp4`（ffmpeg empty_moov）、`fragmented_hybrid.mp4`
  （moov 采样表 + 分片混合）、`fragmented_bad.mp4`（视频 / 音频分居两端的“交错极差”重打包版）
  + 9 项新测试；其中逐样本比对（大小 / 时间戳 / 描述索引 / 同步标记 / 载荷字节）保证转换无损。

## 本版要点（v2.4.2 · 全量代码审查 / 平台适配）

- **Android 16+（API 36/37）适配**
  - 预测性返回：声明 `android:enableOnBackInvokedCallback="true"`（Flutter 3.47 引擎内建 `OnBackInvokedCallback`
    支持；Android 16 起系统对 targetSdk 36+ 的应用默认启用预测性返回）；
  - **16KB 页大小**：NDK r28 + AGP 9 默认 16KB 对齐（实测 `libflutter.so` 64KB、`libdartjni.so` 16KB，
    APK 内 `.so` 偏移均为 16384 的倍数）；CI 新增**发布前硬校验**（zipalign -P 16 + ELF LOAD 段检查）防止回归；
  - 长任务**前台服务**（`dataSync` + 低优先级进度通知）：Android 12+ 的缓存冻结不会再把批量修复 /
    WebDAV 传输挂起；系统限制后台启动时安静降级，不影响主流程；
  - 备份规则：`settings.json`（可能含明文 WebDAV 密码）与修复记录**不进云备份 / 设备迁移**；
  - 边到边（Android 15+ 强制）与「大屏忽略方向/尺寸限制」：复查无残余问题（系统栏由 AppBar / NavigationBar 处理）。
- **Windows**
  - 取消修复后不再因为临时文件被占用而把整批任务带崩（删除失败静默忽略，留给「清理临时文件」）；
  - 拖入大量文件时合并界面刷新（避免刷新风暴）。
- **通用修复（审查发现）**
  - 进度条：被跳过的任务也会推进总数（此前会停在 N-1）；
  - 文件夹 / WebDAV 列表改为**惰性构建**（几千个文件不再一次性建出全部界面）；
  - 「清理临时文件」也会清掉**文件选择器的缓存**，且任务运行中禁止清理；
  - 每次启动自动清理上次会话的导入副本（任务列表不跨会话）。

### v2.4.1

- 修复「汇总条」按钮行在窄屏 / 大字号下可能溢出的隐患：一键操作单独一行、右对齐并可自动换行；
- 本地文件页在桌面端会显示完整路径（同名文件在不同文件夹时一眼可分）。

### v2.4.0

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

- 加密（encrypted）MP4 暂不支持；分片（fragmented）MP4 现支持无损转换为标准 MP4；
- 异常 / 截断的分片结构（如 trun 缺时长、样本越界）会判为「损坏」，无法转换；
- 输出总大小超过 4 GB 的文件暂不支持；
- WebDAV 认证仅支持 HTTP Basic；
- Android 端若输入来源不支持随机读取（少数网盘类 provider），会先复制到应用缓存再处理（需要临时空间）；
- 旧版 Kotlin 项目（`/workspace/mp4fix`）保持原样，仅作参考。

## 许可

沿用原项目的许可与隐私说明（待补）。
