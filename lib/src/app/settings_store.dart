import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'models.dart';

/// 设置持久化：JSON 文件放在应用支持目录（无需额外权限）。
class SettingsStore {
  static File? _cached;

  /// 待写入的最新快照（合并高频保存）。
  ///
  /// WebDAV 主机 / 路径 / 用户名是**逐字符**触发保存的，以前每次按键都直接
  /// `writeAsString` —— 多个写操作会互相覆盖同一个文件，进程在写一半时被杀
  /// 就会留下半截 JSON，下次启动 `load()` 解析失败 → 所有设置（含 SAF 文件夹
  /// 授权 URI）静默回到默认值，用户以为「设置自己丢了」。
  /// 现在：串行化 + 只保留最后一份 + 先写临时文件再原子改名。
  static String? _queued;
  static Future<void>? _draining;

  static Future<File> _file() async {
    final cached = _cached;
    if (cached != null) return cached;
    final dir = await getApplicationSupportDirectory();
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final file = File('${dir.path}/settings.json');
    _cached = file;
    return file;
  }

  static Future<AppSettings?> load() async {
    try {
      final file = await _file();
      if (!file.existsSync()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      return AppSettings.fromJson(decoded.cast<String, Object?>());
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(AppSettings settings) {
    // 先序列化出快照：保存期间设置还会被继续修改，不能等到写盘时再读
    String? json;
    try {
      json = jsonEncode(settings.toJson());
    } catch (_) {
      return Future.value();
    }
    _queued = json;
    return _draining ??= _drain();
  }

  static Future<void> _drain() async {
    try {
      while (_queued != null) {
        final json = _queued;
        _queued = null;
        if (json != null) await _write(json);
      }
    } finally {
      _draining = null;
    }
  }

  static Future<void> _write(String json) async {
    try {
      final file = await _file();
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(json, flush: true);
      // 先删再改名：Windows 上 rename 不能覆盖已存在的文件
      if (file.existsSync()) {
        try {
          file.deleteSync();
        } catch (_) {
          // 删不掉就继续尝试改名，失败会被外层吞掉
        }
      }
      tmp.renameSync(file.path);
    } catch (_) {
      // 忽略：设置保存失败不影响功能
    }
  }
}
