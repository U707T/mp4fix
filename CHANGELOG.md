# Changelog

本文件记录各版本的用户可见变更。完整技术细节见 README 的「本版要点」段落。

## [2.6.0] - 2026-10-19

### 改进

- **判定改为「时间 + 字节」双阈值**
  - 此前只按「最大交错距离（字节）」判定（阈值 4MB）。字节距离随码率变化：
    低码率长视频即使音视频相隔几十秒，绝对字节数也可能只有几 MB，永远够不到
    阈值 → **漏判**；高码率文件则相反，稍一错开就超过 4MB。
  - 新增**时间错位**指标（同刻音视频在时间轴上的偏差，与码率无关）。
  - 现在「距离 ≥ 4MB」**或**「时间错位 ≥ 2 秒」任一满足即判「需重排」。
  - 两个阈值都可在设置 / 文件夹页调整（距离 1/2/4/8M，时间 0.5/1/2/5s）；
    CLI 新增 `--threshold-seconds`。

### 兼容性

- 默认时间阈值 2 秒不改变原有判定结果（既有夹具判定全部不变）。
- 老版本设置文件没有 `thresholdSeconds` 字段时自动回落默认值，不会报错。

### 测试

- 107 → 114 项。新增 `test/dual_threshold_test.dart`，覆盖时间维度测量、
  「仅时间阈值触发」、「两阈值都宽松时不误报」、「字节触发时向后兼容」、
  设置项持久化与缺字段回落。已做反向验证（改回只看字节则测试必失败）。

## [2.5.3] - 2026-10-19

### 修复

- **Android「选择本地文件夹后直接白屏」**（本次主要修复）
  - 根因：SAF tree URI 被**重复百分号解码**。`Uri.pathSegments` 已解码一次，
    再调 `Uri.decodeComponent` 时，文件夹名含中文 / 空格 / `%` 会抛
    `Illegal percent encoding in URI`。
  - 该函数在 `build()` 中被调用 → 整页被替换为 `ErrorWidget` → release 下
    **一片白屏**（debug 才显示红底报错）。
  - 坏 URI 已写入 `settings.json`，因此重启后仍然白屏、连设置页都进不去。
  - 修复：新增纯函数 `treeUriDisplayName()`，只解码一次 + 非法百分号兜底 +
    剥掉 `primary:` 卷前缀只显示目录名。

- **「停止」按钮形同虚设**：`_setRunning()` 在任务收尾时也会清掉取消标记，
  导致「扫描并修复」在扫描阶段被取消后，仍会自动接着批量修复。
  现在只在开始新任务时清标记。

- **输入文件夹缺少写权限与持久化权限**：`pickDirectory()` 未传
  `writePermission` / `persistablePermission`。前者导致默认的「就地覆盖输入
  文件夹」全部失败；后者导致重启后 URI 权限失效、扫描直接抛 `SecurityException`。

- **`running` 状态可能永久卡死**：`outputTarget()` / `_cache()` 位于 `try` 之外，
  抛异常时运行状态不会复位，界面上所有操作按钮永久禁用，只能杀进程。

### 清理

- 删除死代码 `if_<T>`（全项目零调用）。
- `_isVideoName` 与 `engine_tasks.dart` 的 `isVideoFileName` 重复实现，统一为一处。

### 测试

- 98 → 107 项。新增 `test/tree_name_test.dart`（SAF URI 展示名，覆盖中文 /
  空格 / `100%Videos` / 卷根 / 残缺 URI / 非 URI）与 `test/cancel_test.dart`
  （取消语义）。两者均做了「把实现改回旧代码则测试必须失败」的反向验证。

## [2.5.2] - 2026-09-26

### 修复

- **Android「一按扫描就闪退」**：批量任务用 `startForegroundService()` 拉保活服务，
  服务因厂商 ROM 限制未能及时 `startForeground()` 时，Android 会直接杀掉整个应用
  （`Bringing down service while still waiting for start foreground: That is not allowed.`）。
  改为 `startService()` + 服务内尽力升前台，失败则安静降级为普通后台服务。

### 新增

- 未捕获的 Java/Kotlin 异常写入 `crash_last.txt`，下次启动提示，并附在
  「设置 → 复制诊断信息」中（这类崩溃完全发生在 Dart 之外，此前无从排查）。

## [2.5.1] - 2026-09-26

### 修复

- 文件夹「扫描并修复」此前会连损坏 / 正常 / 失败的文件也一起重试。
- 设置里的「同时处理『可优化』」此前未真正生效。
- 写 SAF 文件夹的两个边界：`.part` 写一半失败残留垃圾；旧文件改名 `.mp4fix-bak`
  让位后若创建新文件抛错，旧文件会「消失」。
- WebDAV 表单主机栏粘贴整串地址（`http://host:port/path`）现在能正确拆开。
- 引擎错误进入界面时不再带 `RepairException:` 前缀。

### 优化

- Android 文件夹批量检测不再把每个视频整份复制到缓存，新增平台侧「只读预取」
  （文件描述符随机读盒头 / moov / moof），不支持随机读时自动退回复制。
- WebDAV 预取改为窗口化顺序读取（16KB 窗口 + 复用），请求数大幅下降。

## [2.5.0] - 2026-09-27

### 新增

- 分片（fragmented）MP4 支持：解析 `moof/traf/trun` 汇总样本后按同一套规则判定，
  修复时无损「扁平化」为标准 MP4（去掉 `mvex` 与分片结构，必要时补全时长 /
  用 `elst` 保留同步）。
- WebDAV 远程扫描预取范围加上每个 `moof`，仍不整档下载。

## [2.4.2] - 2026-09-27

### 修复 / 优化

- Windows + Android 16+ 适配全量审查。
