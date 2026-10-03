import 'package:flutter/material.dart';

import '../engine/engine.dart';
import 'defaults.dart';

/// 任务来源（对应三个功能入口）。
enum JobSource { local, folder, webdav }

/// 任务状态。
enum JobStatus {
  pending,
  inspecting,
  needsFix,
  ok,
  optimizable,
  corrupt,
  unsupported,
  error,
  fixing,
  saved,
  uploaded,
  reused,
  failed,
  cancelled,
}

extension JobStatusX on JobStatus {
  String get label => switch (this) {
    JobStatus.pending => '待检测',
    JobStatus.inspecting => '检测中',
    JobStatus.needsFix => '需重排',
    JobStatus.ok => '正常',
    JobStatus.optimizable => '可优化',
    JobStatus.corrupt => '损坏',
    JobStatus.unsupported => '不支持',
    JobStatus.error => '读取失败',
    JobStatus.fixing => '修复中',
    JobStatus.saved => '已保存',
    JobStatus.uploaded => '已上传',
    JobStatus.reused => '已修复',
    JobStatus.failed => '失败',
    JobStatus.cancelled => '已取消',
  };

  bool get busy => this == JobStatus.inspecting || this == JobStatus.fixing;

  /// 可修复（需重排 / 可优化）。
  bool get fixable =>
      this == JobStatus.needsFix || this == JobStatus.optimizable;

  /// 有问题的终态。
  bool get problematic =>
      this == JobStatus.corrupt ||
      this == JobStatus.unsupported ||
      this == JobStatus.error ||
      this == JobStatus.failed;

  /// 正常的终态。
  bool get good =>
      this == JobStatus.ok ||
      this == JobStatus.saved ||
      this == JobStatus.uploaded ||
      this == JobStatus.reused;

  /// 由本工具完成（保存 / 上传 / 复用上次结果）。
  bool get finished =>
      this == JobStatus.saved ||
      this == JobStatus.uploaded ||
      this == JobStatus.reused;
}

/// 任务列表的筛选分组（列表上方的「额外按钮」）。
enum JobFilter { all, todo, optimize, ok, problem, finished }

extension JobFilterX on JobFilter {
  String get label => switch (this) {
    JobFilter.all => '全部',
    JobFilter.todo => '待处理',
    JobFilter.optimize => '待优化',
    JobFilter.ok => '正常',
    JobFilter.problem => '问题',
    JobFilter.finished => '已完成',
  };

  bool matches(JobStatus s) => switch (this) {
    JobFilter.all => true,
    JobFilter.todo =>
      s == JobStatus.pending ||
          s == JobStatus.inspecting ||
          s == JobStatus.fixing ||
          s == JobStatus.needsFix ||
          s == JobStatus.cancelled,
    JobFilter.optimize => s == JobStatus.optimizable,
    JobFilter.ok => s == JobStatus.ok,
    JobFilter.problem => s.problematic,
    JobFilter.finished => s.finished,
  };
}

/// 批量修复时某个状态是否应处理：
///  - 需重排：总是处理；
///  - 可优化（含分片 MP4）：仅当设置里勾选了「同时处理可优化」；
///  - 正常：仅当「全部处理」（processAll）。
bool shouldBatchFix(
  JobStatus status, {
  required bool includeOptimizable,
  bool processAll = false,
}) {
  if (status == JobStatus.needsFix) return true;
  if (status == JobStatus.optimizable) return includeOptimizable;
  if (processAll && status == JobStatus.ok) return true;
  return false;
}

/// 规范化"用户选中的路径"：去掉 `file://` 前缀、包裹引号与首尾空白。
String normalizePickedPath(String raw) {
  var p = raw.trim();
  if (p.length >= 2 && p.startsWith('"') && p.endsWith('"')) {
    p = p.substring(1, p.length - 1).trim();
  }
  if (p.startsWith('file:')) {
    try {
      return Uri.parse(p).toFilePath();
    } catch (_) {
      // 解析失败就按原样使用
    }
  }
  return p;
}

bool _hasErrno(String text, int errno) =>
    RegExp('\\berrno = $errno\\b').hasMatch(text);

/// 统一的错误文案：常见 IO 错误给出可操作的中文提示，其余去掉异常类型前缀。
String describeError(Object e) {
  final raw = e.toString();
  // Windows: 2/3 = 找不到文件/路径；5 = 拒绝访问；32 = 被占用；112 = 磁盘已满
  // 注意用 \b 限定：'errno = 2' 是 'errno = 28' 的子串，直接 contains 会误判
  if (raw.contains('PathNotFoundException') ||
      _hasErrno(raw, 2) ||
      _hasErrno(raw, 3) ||
      raw.contains('cannot find the path')) {
    return '目标目录不存在或不可写（请在设置里重新选择输出文件夹）';
  }
  if (_hasErrno(raw, 5) || raw.contains('Access is denied')) {
    return '没有权限访问该文件夹（换一个目录，或改用有权限的位置）';
  }
  if (_hasErrno(raw, 32) || raw.contains('another process')) {
    return '文件被其他程序占用（关掉播放器 / 资源管理器预览后重试）';
  }
  if (_hasErrno(raw, 13) || raw.contains('Permission denied')) {
    return '没有写入权限（请换一个输出文件夹）';
  }
  if (_hasErrno(raw, 28) ||
      _hasErrno(raw, 112) ||
      raw.contains('ENOSPC') ||
      raw.contains('No space left') ||
      raw.contains('disk is full')) {
    return '存储空间不足';
  }
  return raw.replaceFirst(
    RegExp(r'^(Bad state|Exception|StateError|FormatException|'
        r'FileSystemException|PathNotFoundException|MissingPluginException|'
        r'RepairException|WebDavException):\s*'),
    '',
  );
}

/// 列表里的一条任务（对应一个视频文件）。
class FixJob {
  FixJob({
    required this.id,
    required this.source,
    required this.name,
    required this.displayPath,
    required this.size,
    this.localPath,
    this.webDavUrl,
    this.sourceUri,
    this.modifiedMs = 0,
  });

  final String id;
  final JobSource source;
  final String name;

  /// 展示用路径（相对路径 / 文件名）。
  final String displayPath;
  final int size;

  /// 本地文件路径（本地 / 文件夹任务）。
  String? localPath;

  /// 远端 URL（WebDAV 任务）。
  String? webDavUrl;

  /// Android SAF 文档 URI（文件夹任务；「重做」时用它重新复制到缓存）。
  String? sourceUri;

  /// 文件的最后修改时间（毫秒；0 = 未知）。
  /// 与 [size] 一起构成修复记录的指纹 —— 文件一变，记录自动失效。
  int modifiedMs;

  JobStatus status = JobStatus.pending;
  String message = '';
  double progress = 0;
  InspectReport? report;

  /// 产物位置（本地路径 / 远端文件名）。
  String? outputPath;

  bool get busy => status.busy;
}

/// 尝试把「整串地址」（`http://host:port/path`）拆成表单字段。
///
/// 主机栏允许直接粘贴整串地址（与旧版一致）：能拆出 host/port/path 时返回
/// 拆分结果，否则返回 null（调用方按普通主机名处理）。[extraPath] 为表单
/// 「路径」字段：粘贴串里没带路径时沿用它。
({String scheme, String host, String port, String path})? splitServerUrl(
  String raw, {
  String extraPath = '',
}) {
  final trimmed = raw.trim();
  if (!trimmed.contains('://')) return null;
  final parsed = Uri.tryParse(trimmed);
  if (parsed == null || parsed.host.isEmpty) return null;
  final scheme = parsed.scheme.toLowerCase() == 'https' ? 'https' : 'http';
  final port =
      parsed.hasPort ? '${parsed.port}' : (scheme == 'https' ? '443' : '80');
  // Uri.path 是百分号编码的形态（中文会变 %XX）；拆出来要还原成明文，
  // 由客户端层统一再编码。
  var path = Uri.decodeComponent(parsed.path);
  if (path.isEmpty) path = extraPath.trim();
  return (scheme: scheme, host: parsed.host, port: port, path: path);
}

/// WebDAV 连接配置（密码不落盘）。
///
/// 默认值来自 [AppDefaults]（出厂即指向默认 alist 服务器，表单可直接用）。
class WebDavConfig {
  WebDavConfig({
    this.host = AppDefaults.webDavHost,
    this.port = AppDefaults.webDavPort,
    this.path = AppDefaults.webDavPath,
    this.user = AppDefaults.webDavUser,
    this.https = AppDefaults.webDavHttps,
    this.insecure = AppDefaults.webDavInsecure,
  });

  String host;
  String port;
  String path;
  String user;
  bool https;
  bool insecure;

  /// 拼出完整 URL（不含尾部斜杠）。
  ///
  /// 主机栏被粘贴成整串（`http://host:port/path`）时自动拆开，不该拆不动。
  String get url {
    final split = splitServerUrl(host, extraPath: path);
    final scheme = split?.scheme ?? (https ? 'https' : 'http');
    final hostPart = (split?.host ?? host.trim());
    final rawPort = split?.port ?? port.trim();
    final portPart = rawPort.isEmpty ? (scheme == 'https' ? '443' : '80') : rawPort;
    final rawPath = split?.path ?? path;
    // 折叠重复斜杠并去掉首尾斜杠（用户手输 'dav//x/' 也能拼出正确 URL）
    final cleanPath = rawPath.trim().replaceAll(RegExp(r'/+'), '/').replaceAll(RegExp(r'^/|/$'), '');
    return '$scheme://$hostPart:$portPart'
        '${cleanPath.isEmpty ? '' : '/$cleanPath'}';
  }

  Map<String, Object?> toJson() => {
    'host': host,
    'port': port,
    'path': path,
    'user': user,
    'https': https,
    'insecure': insecure,
  };

  static WebDavConfig fromJson(Map<String, Object?> json) {
    // 空字段回落到出厂默认值：老版本存档里是空串，升级后同样能"不改就直连"
    String pick(String key, String fallback) {
      final value = json[key] as String?;
      return (value == null || value.isEmpty) ? fallback : value;
    }

    return WebDavConfig(
      host: pick('host', AppDefaults.webDavHost),
      port: pick('port', AppDefaults.webDavPort),
      path: pick('path', AppDefaults.webDavPath),
      user: pick('user', AppDefaults.webDavUser),
      https: json['https'] as bool? ?? AppDefaults.webDavHttps,
      insecure: json['insecure'] as bool? ?? AppDefaults.webDavInsecure,
    );
  }
}

/// 输出文件命名规则（在「设置 → 文件命名」里配置，对所有输出生效）。
enum OutputNameMode {
  /// 原样：修好后仍然叫 `原名.mp4`（同名覆盖）。
  original,

  /// 加前缀：`前缀原名.mp4`。
  prefix,

  /// 加后缀：`原名后缀.mp4`（如 `_fixed`）。
  suffix,

  /// 前缀 + 后缀。
  both;

  String get label => switch (this) {
    OutputNameMode.original => '原名',
    OutputNameMode.prefix => '加前缀',
    OutputNameMode.suffix => '加后缀',
    OutputNameMode.both => '前缀+后缀',
  };
}

/// 清洗用户填写的文件名前后缀：去掉非法字符与首尾空白 / 点号。
///
/// Windows 上 `\ / : * ? " < > |` 与首尾空格 / 点号都不允许出现在文件名里；
/// Android 的 SAF 提供方对其中一部分同样敏感 —— 统一在这里清掉。
String sanitizeNamePart(String raw) {
  var s = raw.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '');
  s = s.replaceAll(RegExp(r'^[\s.]+|[\s.]+$'), '');
  return s;
}

/// 按命名规则生成输出文件名（[fileName] 为原文件名，如 `a.m4v`）。
///
/// 规则里的前缀 / 后缀为空时视为不生效（避免生成同名文件）。
/// 结果为空或与原文件同名时，回落到原文件名。
String applyNameRule(
  String fileName, {
  required OutputNameMode mode,
  String prefix = '',
  String suffix = '',
}) {
  if (mode == OutputNameMode.original) return fileName;
  final cleanPrefix = sanitizeNamePart(prefix);
  final cleanSuffix = sanitizeNamePart(suffix);
  final usePrefix =
      (mode == OutputNameMode.prefix || mode == OutputNameMode.both) &&
      cleanPrefix.isNotEmpty;
  final useSuffix =
      (mode == OutputNameMode.suffix || mode == OutputNameMode.both) &&
      cleanSuffix.isNotEmpty;
  if (!usePrefix && !useSuffix) return fileName;

  final dot = fileName.lastIndexOf('.');
  final hasExt = dot > 0 && dot < fileName.length - 1;
  var base = hasExt ? fileName.substring(0, dot) : fileName;
  final ext = hasExt ? fileName.substring(dot) : '';

  if (usePrefix) base = '$cleanPrefix$base';
  if (useSuffix) base = '$base$cleanSuffix';
  base = sanitizeNamePart(base);
  if (base.isEmpty) return fileName;
  return '$base$ext';
}

/// 应用设置（可持久化）。
class AppSettings {
  AppSettings({
    this.thresholdMb = AppDefaults.thresholdMb,
    this.includeOptimizable = false,
    this.themeMode = ThemeMode.system,
    this.outputTreeUri,
    this.outputDirPath,
    this.scanInputTreeUri,
    this.scanInputDirPath,
    this.rememberWebDavPassword = false,
    this.webDavPassword = '',
    this.reuseRepairs = true,
    this.nameMode = OutputNameMode.original,
    this.namePrefix = '',
    this.nameSuffix = '_fixed',
    WebDavConfig? webdav,
  }) : webdav = webdav ?? WebDavConfig();

  /// 判定阈值（MB，最大交错距离）。
  int thresholdMb;
  bool includeOptimizable;
  ThemeMode themeMode;

  /// Android：SAF 输出文件夹（tree URI）。
  String? outputTreeUri;

  /// 桌面 / 回退：普通目录。
  String? outputDirPath;

  /// Android：文件夹批量检测的输入目录（tree URI）。
  String? scanInputTreeUri;

  /// 桌面：文件夹批量检测的输入目录（普通路径）。
  String? scanInputDirPath;

  /// 是否记住修复记录：重新扫描时认出已修复过的文件，跳过（复用上次结果）。
  bool reuseRepairs;

  /// 输出文件命名规则。
  OutputNameMode nameMode;
  String namePrefix;
  String nameSuffix;

  /// 按当前命名规则生成输出文件名。
  String applyOutputName(String fileName) => applyNameRule(
    fileName,
    mode: nameMode,
    prefix: namePrefix,
    suffix: nameSuffix,
  );

  /// 命名规则的指纹：规则一变，旧的修复记录自动失效（重新处理）。
  String get nameRuleId =>
      '${nameMode.name}|${sanitizeNamePart(namePrefix)}|'
      '${sanitizeNamePart(nameSuffix)}';

  /// 命名规则的展示文案（规则不生效时为空）——例如 `命名 原名_fixed`。
  String get nameRuleHint {
    if (applyOutputName('x.mp4') == 'x.mp4') return '';
    return switch (nameMode) {
      OutputNameMode.prefix => '命名 ${sanitizeNamePart(namePrefix)}原名',
      OutputNameMode.suffix => '命名 原名${sanitizeNamePart(nameSuffix)}',
      OutputNameMode.both =>
        '命名 ${sanitizeNamePart(namePrefix)}原名${sanitizeNamePart(nameSuffix)}',
      OutputNameMode.original => '',
    };
  }

  WebDavConfig webdav;

  /// 是否把 WebDAV 密码保存在本机设置文件里（默认关闭）。
  bool rememberWebDavPassword;

  /// 本机保存的 WebDAV 密码（仅当 [rememberWebDavPassword] 为真时使用；
  /// 注意：明文存在应用私有目录，不加密）。
  String webDavPassword;

  int get thresholdBytes => thresholdMb * 1024 * 1024;

  Map<String, Object?> toJson() => {
    'thresholdMb': thresholdMb,
    'includeOptimizable': includeOptimizable,
    'themeMode': themeMode.name,
    'outputTreeUri': outputTreeUri,
    'outputDirPath': outputDirPath,
    'scanInputTreeUri': scanInputTreeUri,
    'scanInputDirPath': scanInputDirPath,
    'rememberWebDavPassword': rememberWebDavPassword,
    'webDavPassword': webDavPassword,
    'reuseRepairs': reuseRepairs,
    'nameMode': nameMode.name,
    'namePrefix': namePrefix,
    'nameSuffix': nameSuffix,
    'webdav': webdav.toJson(),
  };

  static AppSettings fromJson(Map<String, Object?> json) => AppSettings(
    thresholdMb: json['thresholdMb'] as int? ?? AppDefaults.thresholdMb,
    includeOptimizable: json['includeOptimizable'] as bool? ?? false,
    themeMode: ThemeMode.values.firstWhere(
      (m) => m.name == json['themeMode'],
      orElse: () => ThemeMode.system,
    ),
    outputTreeUri: json['outputTreeUri'] as String?,
    outputDirPath: json['outputDirPath'] as String?,
    scanInputTreeUri: json['scanInputTreeUri'] as String?,
    scanInputDirPath: json['scanInputDirPath'] as String?,
    rememberWebDavPassword: json['rememberWebDavPassword'] as bool? ?? false,
    webDavPassword: json['webDavPassword'] as String? ?? '',
    reuseRepairs: json['reuseRepairs'] as bool? ?? true,
    nameMode: OutputNameMode.values.firstWhere(
      (m) => m.name == json['nameMode'],
      orElse: () => OutputNameMode.original,
    ),
    namePrefix: json['namePrefix'] as String? ?? '',
    nameSuffix: json['nameSuffix'] as String? ?? '_fixed',
    webdav: WebDavConfig.fromJson(
      (json['webdav'] as Map?)?.cast<String, Object?>() ?? const {},
    ),
  );
}
