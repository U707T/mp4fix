import 'dart:io';

import 'package:flutter/services.dart';

/// 来源不支持随机读取（如管道类 content provider）：
/// 调用方应退回"复制到缓存再处理"。
class SafNotSeekableException implements Exception {
  const SafNotSeekableException();

  @override
  String toString() => '来源不支持随机读取（已退回复制到缓存）';
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
  static Future<String> writeToTree({
    required String treeUri,
    required String name,
    required String sourcePath,
  }) async {
    final result = await _channel.invokeMethod<String>('writeToTree', {
      'treeUri': treeUri,
      'name': name,
      'sourcePath': sourcePath,
    });
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
  static Future<String> saveToDownloads({
    required String name,
    required String sourcePath,
  }) async {
    final result = await _channel.invokeMethod<String>('saveToDownloads', {
      'name': name,
      'sourcePath': sourcePath,
    });
    if (result == null || result.isEmpty) {
      throw StateError('保存失败（平台未返回路径）');
    }
    return result;
  }

  /// 删除文档（尽力而为，失败不抛错）。
  static Future<void> deleteDocument(String uri) async {
    try {
      await _channel.invokeMethod<void>('deleteDocument', {'uri': uri});
    } catch (_) {
      // 忽略
    }
  }

  /// 指定 SAF 文件夹里是否已存在 [name]（修复记录校验用）。
  ///
  /// 查询失败时返回 true —— "不确定"就当作产物还在，不要平白让复用失效。
  static Future<bool> existsInTree(String treeUri, String name) async {
    try {
      final result = await _channel.invokeMethod<bool>('existsInTree', {
        'treeUri': treeUri,
        'name': name,
      });
      return result ?? true;
    } catch (_) {
      return true;
    }
  }

  /// 公共「下载/MP4Fix」里是否已存在 [name]（修复记录校验用）。
  ///
  /// 查询失败时返回 true（同上）。
  static Future<bool> existsInDownloads(String name) async {
    try {
      final result = await _channel.invokeMethod<bool>('existsInDownloads', {
        'name': name,
      });
      return result ?? true;
    } catch (_) {
      return true;
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
