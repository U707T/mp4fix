import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../engine/engine.dart';
import '../platform/android_platform.dart';

/// 修复产物的输出目标。
abstract class OutputTarget {
  /// 界面展示的"保存到哪"说明。
  String get describe;

  /// 把 [source] 保存为 [name]（同名覆盖），返回展示位置。
  ///
  /// [subDir] 是相对目录（`''` = 根）。递归扫描文件夹时必须传它 —— 否则子目录
  /// 里的同名文件会在输出根目录上互相覆盖。
  Future<String> save(File source, String name, {String subDir = ''});

  /// 修复记录里的位置类型（dir / saf / downloads）。
  String get ledgerKind;

  /// 修复记录里的位置引用（目录路径 / SAF tree URI；其余为空）。
  String get ledgerRef;

  /// 桌面：产物所在目录的本地路径（供"打开所在文件夹"用）；不可用时为 null。
  String? get localDirectory => null;
}

/// 落位前的产物校验：**只要不通过就绝不覆盖原文件**。
///
/// 覆盖是不可逆操作 —— 一旦把坏文件写回去，用户的原片就没了。这里做两层检查：
///  1. 大小必须 > 0，且与"预期大小"（引擎报告的输出字节数）一致；
///  2. 结构必须可解析、且不是「损坏」判定（moov 在、样本表自洽）。
///
/// 校验失败抛 [OutputValidationException]，调用方据此保留原文件并报错。
class OutputValidationException implements Exception {
  const OutputValidationException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 校验修复产物是否可安全落位。返回 null 表示通过，否则返回失败原因。
///
/// [expectedBytes] 为引擎报告的预期输出大小（拿不到时传 0 跳过大小比对）。
String? validateRepairOutput(File output, {int expectedBytes = 0}) {
  if (!output.existsSync()) return '产物不存在（修复可能未完成）';
  final size = output.lengthSync();
  if (size <= 0) return '产物为空文件（0 字节）';
  if (expectedBytes > 0 && size != expectedBytes) {
    return '产物大小不符（$size ≠ 预期 $expectedBytes 字节）';
  }
  if (size < 16) return '产物过小，不是有效的 MP4';

  // 结构校验：能被检测器读出 moov 且不判「损坏」才算合格。
  // 注意这里用很宽的阈值 —— 只关心"文件是否完整"，不关心交错质量。
  SeekableInput? input;
  try {
    input = FileSeekableInput(output);
    final report = Mp4Inspect.inspect(
      input,
      interleaveThresholdBytes: 1 << 62,
      interleaveThresholdSeconds: 1e9,
    );
    if (report.health == Mp4Health.corrupt) {
      return '产物结构损坏：${report.detail}';
    }
    if (report.videoSamples == 0 && report.audioSamples == 0) {
      return '产物里没有可读的媒体样本';
    }
    return null;
  } catch (e) {
    return '产物无法解析：${errorMessage(e)}';
  } finally {
    input?.close();
  }
}

/// 普通目录（桌面 / 应用文档目录回退）。
class DirectoryOutputTarget implements OutputTarget {
  DirectoryOutputTarget(this.dir);

  final Directory dir;

  @override
  String get describe => dir.path;

  @override
  String get ledgerKind => 'dir';

  @override
  String get ledgerRef => dir.path;

  @override
  String? get localDirectory => dir.path;

  @override
  Future<String> save(File source, String name, {String subDir = ''}) async {
    // 子目录按需创建（`a/b/c` 也会一次建出来）
    final dir = subDir.isEmpty ? this.dir : Directory('${this.dir.path}/$subDir');
    dir.createSync(recursive: true);
    final target = File('${dir.path}${Platform.pathSeparator}$name');

    // 安全落位（同名覆盖）：旧文件先改名为 .bak → 再把新文件移入 → 成功后删 .bak；
    // 任一步失败都尽量把旧文件还原，避免"旧文件已删、新文件没写成"的窗口。
    File? backup;
    if (target.existsSync()) {
      backup = File('${target.path}.mp4fix-bak');
      if (backup.existsSync()) backup.deleteSync();
      target.renameSync(backup.path);
    }
    try {
      try {
        source.renameSync(target.path);
      } on FileSystemException {
        // 跨卷（例如缓存盘 → 目标盘）rename 会失败：退回复制

        source.copySync(target.path);
        source.deleteSync();
      }
    } catch (e) {
      if (backup != null && backup.existsSync()) {
        try {
          backup.renameSync(target.path);
        } catch (_) {
          // 尽力而为
        }
      }
      rethrow;
    }
    if (backup != null && backup.existsSync()) backup.deleteSync();
    return target.path;
  }
}

/// Android SAF 文件夹（tree URI）。
class SafOutputTarget implements OutputTarget {
  SafOutputTarget(this.treeUri, {required this.displayName});

  final String treeUri;
  final String displayName;

  @override
  String get describe => '已选文件夹（$displayName）';

  @override
  String get ledgerKind => 'saf';

  @override
  String get ledgerRef => treeUri;

  @override
  String? get localDirectory => null;

  @override
  Future<String> save(File source, String name, {String subDir = ''}) async {
    await AndroidPlatform.writeToTree(
      treeUri: treeUri,
      name: name,
      sourcePath: source.path,
      relativeDir: subDir,
    );
    return subDir.isEmpty ? name : '$subDir/$name';
  }
}

/// Android 默认：公共「下载/MP4Fix」（MediaStore，无需权限、文件管理器中可见）。
class DownloadsOutputTarget implements OutputTarget {
  const DownloadsOutputTarget();

  @override
  String get describe => '下载/MP4Fix（默认，可在设置里改）';

  @override
  String get ledgerKind => 'downloads';

  @override
  String get ledgerRef => '';

  @override
  String? get localDirectory => null;

  @override
  Future<String> save(File source, String name, {String subDir = ''}) =>
      AndroidPlatform.saveToDownloads(
        name: name,
        sourcePath: source.path,
        relativeDir: subDir,
      );
}

/// 兜底 / 桌面默认：`下载/MP4Fix`（找不到下载目录时退回应用文档目录）。
Future<OutputTarget> defaultOutputTarget() async {
  Directory? base;
  try {
    base = await getDownloadsDirectory();
  } catch (_) {
    // 某些平台没有下载目录 → 走应用文档目录
  }
  base ??= await getApplicationDocumentsDirectory();
  final out = Directory('${base.path}${Platform.pathSeparator}MP4Fix');
  if (!out.existsSync()) out.createSync(recursive: true);
  return DirectoryOutputTarget(out);
}
