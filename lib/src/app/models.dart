import 'package:flutter/material.dart';

import '../engine/engine.dart';

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
      this == JobStatus.uploaded;
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
        r'FileSystemException|PathNotFoundException|MissingPluginException):\s*'),
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

  JobStatus status = JobStatus.pending;
  String message = '';
  double progress = 0;
  InspectReport? report;

  /// 产物位置（本地路径 / 远端文件名）。
  String? outputPath;

  bool get busy => status.busy;
}

/// WebDAV 连接配置（密码不落盘）。
class WebDavConfig {
  WebDavConfig({
    this.host = '',
    this.port = '',
    this.path = '',
    this.user = '',
    this.https = false,
    this.insecure = false,
  });

  String host;
  String port;
  String path;
  String user;
  bool https;
  bool insecure;

  /// 拼出完整 URL（不含尾部斜杠）。
  String get url {
    final scheme = https ? 'https' : 'http';
    final p = port.trim().isEmpty ? (https ? '443' : '80') : port.trim();
    final cleanPath = path.trim().replaceAll(RegExp(r'^/+|/+$'), '');
    return '$scheme://${host.trim()}:$p'
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

  static WebDavConfig fromJson(Map<String, Object?> json) => WebDavConfig(
    host: json['host'] as String? ?? '',
    port: json['port'] as String? ?? '',
    path: json['path'] as String? ?? '',
    user: json['user'] as String? ?? '',
    https: json['https'] as bool? ?? false,
    insecure: json['insecure'] as bool? ?? false,
  );
}

/// 应用设置（可持久化）。
class AppSettings {
  AppSettings({
    this.thresholdMb = 4,
    this.includeOptimizable = false,
    this.themeMode = ThemeMode.system,
    this.outputTreeUri,
    this.outputDirPath,
    this.scanInputTreeUri,
    this.scanInputDirPath,
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

  WebDavConfig webdav;

  int get thresholdBytes => thresholdMb * 1024 * 1024;

  Map<String, Object?> toJson() => {
    'thresholdMb': thresholdMb,
    'includeOptimizable': includeOptimizable,
    'themeMode': themeMode.name,
    'outputTreeUri': outputTreeUri,
    'outputDirPath': outputDirPath,
    'scanInputTreeUri': scanInputTreeUri,
    'scanInputDirPath': scanInputDirPath,
    'webdav': webdav.toJson(),
  };

  static AppSettings fromJson(Map<String, Object?> json) => AppSettings(
    thresholdMb: json['thresholdMb'] as int? ?? 4,
    includeOptimizable: json['includeOptimizable'] as bool? ?? false,
    themeMode: ThemeMode.values.firstWhere(
      (m) => m.name == json['themeMode'],
      orElse: () => ThemeMode.system,
    ),
    outputTreeUri: json['outputTreeUri'] as String?,
    outputDirPath: json['outputDirPath'] as String?,
    scanInputTreeUri: json['scanInputTreeUri'] as String?,
    scanInputDirPath: json['scanInputDirPath'] as String?,
    webdav: WebDavConfig.fromJson(
      (json['webdav'] as Map?)?.cast<String, Object?>() ?? const {},
    ),
  );
}
