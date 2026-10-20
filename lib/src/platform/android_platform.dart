import 'dart:io';

import 'package:flutter/services.dart';

/// 来源不支持随机读取（如管道类 content provider）：
/// 调用方应退回"复制到缓存再处理"。
class SafNotSeekableException implements Exception {
  const SafNotSeekableException();

  @override
  String toString() => '来源不支持随机读取（已退回复制到缓存）';
}

/// 用户取消了落位（SAF 写入）。
///
/// 取消时原文件没有任何改动，界面应显示「已取消」而不是「失败」。
class SafWriteCancelledException implements Exception {
  const SafWriteCancelledException();

  /// 与 Kotlin 侧 `result.error("cancelled", …)` 约定的错误码。
  static const String code = 'cancelled';

  @override
  String toString() => '已取消（原文件未改动）';
}

/// 一个「只剩 `.mp4fix-bak`」的残留文件（v2.7.0 及以前 SAF 落位缺陷的现场）。
///
/// [originalName] 是它本该叫的名字；[size] 就是原视频的大小 —— 数据没丢，
/// 改回名字即可恢复。
class BackupLeftover {
  const BackupLeftover({
    required this.backupName,
    required this.originalName,
    required this.size,
    required this.parentPath,
    required this.parentUri,
  });

  final String backupName;
  final String originalName;
  final int size;

  /// 相对扫描根目录的展示路径（空字符串表示根目录）。
  final String parentPath;

  /// 所在目录的 document URI —— 恢复时要用它定位（残留文件可能在子目录里）。
  final String parentUri;

  String get displayPath =>
      parentPath.isEmpty ? originalName : '$parentPath/$originalName';
}

/// Android 平台通道（`mp4fix/platform`）。
///
/// 只补足插件做不到的能力：
///  - 把文件写进用户选择的 SAF 文件夹（saf_util 只读）；
///  - 把 `content://` 输入复制到应用缓存（供纯 Dart 引擎随机读取）；
///  - `content://` 输入的「只读预取」：只取盒头 / moov / moof 做体检，
///    不整份复制（与服务端 WebDAV 扫描同一思路）。
///
/// 非 Android 平台上的调用会抛出 [UnsupportedError]，调用方需先判断
/// [AndroidPlatform.isSupported]。
class AndroidPlatform {
  static const MethodChannel _channel = MethodChannel('mp4fix/platform');

  /// 当前平台是否支持（仅 Android）。
  static bool get isSupported => Platform.isAndroid;

  /// 只读预取"检测所需区域"：每个顶层盒的头部 + 整个 moov + 每个 moof。
  ///
  /// 返回（文件大小, 区间列表）；来源不支持随机读取时抛
  /// [SafNotSeekableException]，调用方退回复制到缓存。
  static Future<({int size, List<({int start, Uint8List bytes})> ranges})>
      prefetchForInspect(String uri) async {
    final Map<Object?, Object?>? raw;
    try {
      raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'prefetchForInspect',
        {'uri': uri},
      );
    } on PlatformException catch (e) {
      if (e.code == 'not_seekable') throw const SafNotSeekableException();
      rethrow;
    }
    if (raw == null) throw StateError('预取失败（平台未返回数据）');
    final size = (raw['size'] as num?)?.toInt() ?? -1;
    final ranges = <({int start, Uint8List bytes})>[];
    final rawRanges = raw['ranges'];
    if (rawRanges is List) {
      for (final item in rawRanges) {
        if (item is! Map) continue;
        final start = (item['start'] as num?)?.toInt();
        final bytes = item['bytes'];
        if (start == null || bytes is! Uint8List) continue;
        ranges.add((start: start, bytes: bytes));
      }
    }
    if (size < 0) throw StateError('预取失败（未能获取文件大小）');
    return (size: size, ranges: ranges);
  }

  /// 把 [sourcePath] 写入 SAF 文件夹 [treeUri]，覆盖同名文件。
  /// 返回写入后的文档 URI。
  ///
  /// [relativeDir] 为相对子目录（`sub/dir`，空串 = 根目录）：递归扫描文件夹时
  /// 产物要落回原文件所在的子目录，否则子目录里的同名文件会在根目录互相覆盖。
  /// 目录不存在时平台侧会创建；创建失败会抛错（宁可报错也不静默写错位置）。
  ///
  /// 用户中途取消时抛 [SafWriteCancelledException]（界面显示「已取消」）。
  static Future<String> writeToTree({
    required String treeUri,
    required String name,
    required String sourcePath,
    String relativeDir = '',
  }) async {
    final String? result;
    try {
      result = await _channel.invokeMethod<String>('writeToTree', {
        'treeUri': treeUri,
        'name': name,
        'sourcePath': sourcePath,
        if (relativeDir.isNotEmpty) 'relativeDir': relativeDir,
      });
    } on PlatformException catch (e) {
      if (e.code == SafWriteCancelledException.code) {
        throw const SafWriteCancelledException();
      }
      rethrow;
    }
    if (result == null || result.isEmpty) {
      throw StateError('写入失败（平台未返回文档 URI）');
    }
    return result;
  }

  /// 把 `content://` 输入复制到应用缓存，返回本地文件路径。
  static Future<String> copyToCache({
    required String uri,
    required String name,
  }) async {
    final result = await _channel.invokeMethod<String>('copyToCache', {
      'uri': uri,
      'name': name,
    });
    if (result == null || result.isEmpty) {
      throw StateError('复制失败（平台未返回路径）');
    }
    return result;
  }

  /// 保存到公共「下载/MP4Fix」目录（Android 10+ 无需权限），返回展示路径。
  ///
  /// [relativeDir] 会被镜像到 `下载/MP4Fix/<relativeDir>/` 下。
  static Future<String> saveToDownloads({
    required String name,
    required String sourcePath,
    String relativeDir = '',
  }) async {
    final result = await _channel.invokeMethod<String>('saveToDownloads', {
      'name': name,
      'sourcePath': sourcePath,
      if (relativeDir.isNotEmpty) 'relativeDir': relativeDir,
    });
    if (result == null || result.isEmpty) {
      throw StateError('保存失败（平台未返回路径）');
    }
    return result;
  }

  /// 用户取消时中断平台侧的大文件写入 / 复制（SAF 落位、下载目录落位、复制到缓存）。
  ///
  /// 这些复制在 Kotlin 侧逐块检查取消标记，中断后原文件不会有任何改动
  /// （`.part` 被删除、`.bak` 被还原、缓存里的半成品被清掉）。
  static Future<void> cancelPlatformWrite() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('cancelPlatformWrite');
    } catch (_) {
      // 忽略：取消只是尽力而为，任务本身仍会在下个文件处停下
    }
  }

  /// 删除文档（尽力而为，失败不抛错）。
  static Future<void> deleteDocument(String uri) async {
    try {
      await _channel.invokeMethod<void>('deleteDocument', {'uri': uri});
    } catch (_) {
      // 忽略
    }
  }

  /// 指定 SAF 文件夹里是否已存在 [relativePath]（修复记录校验用）。
  ///
  /// [relativePath] 可以带子目录（`sub/a.mp4`），平台侧按段查找。
  /// 查询失败时返回 true ——"不确定"就当作产物还在，不要平白让复用失效。
  static Future<bool> existsInTree(String treeUri, String relativePath) async {
    try {
      final result = await _channel.invokeMethod<bool>('existsInTree', {
        'treeUri': treeUri,
        'name': relativePath,
      });
      return result ?? true;
    } catch (_) {
      return true;
    }
  }

  /// 扫描 SAF 文件夹，找出「只剩 `.mp4fix-bak`、正式名不见了」的残留文件。
  ///
  /// 这是 v2.7.0 及以前 SAF 落位缺陷的事故现场：原文件被改名让位后新文件没就位，
  /// 原视频只剩一个 `.mp4fix-bak`。**数据没丢**，改回名字即可恢复。
  static Future<List<BackupLeftover>> listBackupLeftovers(String treeUri) async {
    try {
      final raw = await _channel.invokeListMethod<Map<Object?, Object?>>(
        'listBackupLeftovers',
        {'treeUri': treeUri},
      );
      if (raw == null) return const [];
      final out = <BackupLeftover>[];
      for (final item in raw) {
        final backupName = item['backupName'] as String?;
        final originalName = item['originalName'] as String?;
        if (backupName == null || originalName == null) continue;
        out.add(
          BackupLeftover(
            backupName: backupName,
            originalName: originalName,
            size: (item['size'] as num?)?.toInt() ?? -1,
            parentPath: item['parentPath'] as String? ?? '',
            parentUri: item['parentUri'] as String? ?? '',
          ),
        );
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// 把一个 `.mp4fix-bak` 改回正式名。返回是否成功。
  ///
  /// 正式名已存在时不覆盖（返回 false），避免又造出新的数据问题。
  static Future<bool> restoreBackup({
    required String treeUri,
    required String backupName,
    String parentUri = '',
  }) async {
    try {
      final ok = await _channel.invokeMethod<bool>('restoreBackup', {
        'treeUri': treeUri,
        'backupName': backupName,
        'parentUri': parentUri.isEmpty ? null : parentUri,
      });
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 公共「下载/MP4Fix」里是否已存在 [relativePath]（修复记录校验用）。
  ///
  /// [relativePath] 可以带子目录（`sub/a.mp4`）。
  /// 查询失败时返回 true（同上）。
  static Future<bool> existsInDownloads(String relativePath) async {
    try {
      final result = await _channel.invokeMethod<bool>('existsInDownloads', {
        'name': relativePath,
      });
      return result ?? true;
    } catch (_) {
      return true;
    }
  }

  /// 读取默认网关（一般就是路由器 IP）；读不到返回 null。
  ///
  /// 走 `ConnectivityManager.linkProperties` —— Android 10 起普通应用已经读不到
  /// `/proc/net/route`（SELinux 拦截），这是唯一稳的官方接口。只声明
  /// `ACCESS_NETWORK_STATE` 普通权限，不会弹授权框。
  static Future<String?> defaultGateway() async {
    try {
      final value = await _channel.invokeMethod<String>('defaultGateway');
      final trimmed = value?.trim();
      if (trimmed == null || trimmed.isEmpty || trimmed == '0.0.0.0') {
        return null;
      }
      return trimmed;
    } catch (_) {
      return null;
    }
  }

  /// 读取上一次未捕获的 Java/Kotlin 异常（时间戳 + 堆栈）；没有则返回 null。
  ///
  /// "点一下扫描就闪退"这类系统级崩溃完全发生在 Dart 之外 —— 靠这张底牌远程排查。
  static Future<({String text, int time})?> readLastCrash() async {
    try {
      final raw =
          await _channel.invokeMethod<Map<Object?, Object?>>('readLastCrash');
      if (raw == null) return null;
      final text = raw['text'];
      final time = (raw['time'] as num?)?.toInt() ?? 0;
      if (text is! String || text.isEmpty) return null;
      return (text: text, time: time);
    } catch (_) {
      return null;
    }
  }

  /// 开启任务前台服务（Android 12+ 防止批量修复在后台被冻结）。
  ///
  /// 失败时静默忽略 —— 服务只是"加分项"，任务本身照常运行。
  static Future<void> startTaskService({
    required String title,
    required String text,
    int progress = -1,
  }) async {
    try {
      await _channel.invokeMethod<void>('startTaskService', {
        'title': title,
        'text': text,
        'progress': progress,
      });
    } catch (_) {
      // 忽略
    }
  }

  /// 更新通知里的进度文案。
  static Future<void> updateTaskService({
    required String title,
    required String text,
    int progress = -1,
  }) async {
    try {
      await _channel.invokeMethod<void>('updateTaskService', {
        'title': title,
        'text': text,
        'progress': progress,
      });
    } catch (_) {
      // 忽略
    }
  }

  /// 结束后台任务服务。
  static Future<void> stopTaskService() async {
    try {
      await _channel.invokeMethod<void>('stopTaskService');
    } catch (_) {
      // 忽略
    }
  }
}
