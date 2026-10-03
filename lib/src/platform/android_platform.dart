import 'dart:io';

import 'package:flutter/services.dart';

/// Android 平台通道（`mp4fix/platform`）。
///
/// 只补足插件做不到的能力：
///  - 把文件写进用户选择的 SAF 文件夹（saf_util 只读）；
///  - 把 `content://` 输入复制到应用缓存（供纯 Dart 引擎随机读取）。
///
/// 非 Android 平台上的调用会抛出 [UnsupportedError]，调用方需先判断
/// [AndroidPlatform.isSupported]。
class AndroidPlatform {
  static const MethodChannel _channel = MethodChannel('mp4fix/platform');

  /// 当前平台是否支持（仅 Android）。
  static bool get isSupported => Platform.isAndroid;

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
}
