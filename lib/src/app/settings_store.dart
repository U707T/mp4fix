import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'models.dart';

/// 设置持久化：JSON 文件放在应用支持目录（无需额外权限）。
class SettingsStore {
  static File? _cached;

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

  static Future<void> save(AppSettings settings) async {
    try {
      final file = await _file();
      await file.writeAsString(jsonEncode(settings.toJson()));
    } catch (_) {
      // 忽略：设置保存失败不影响功能
    }
  }
}
