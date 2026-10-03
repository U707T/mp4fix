import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../platform/android_platform.dart';

/// 修复产物的输出目标。
abstract class OutputTarget {
  /// 界面展示的"保存到哪"说明。
  String get describe;

  /// 把 [source] 保存为 [name]（同名覆盖），返回展示位置。
  Future<String> save(File source, String name);

  /// 修复记录里的位置类型（dir / saf / downloads）。
  String get ledgerKind;

  /// 修复记录里的位置引用（目录路径 / SAF tree URI；其余为空）。
  String get ledgerRef;

  /// 桌面：产物所在目录的本地路径（供"打开所在文件夹"用）；不可用时为 null。
  String? get localDirectory => null;
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
  Future<String> save(File source, String name) async {
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
  Future<String> save(File source, String name) async {
    await AndroidPlatform.writeToTree(
      treeUri: treeUri,
      name: name,
      sourcePath: source.path,
    );
    return name;
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
  Future<String> save(File source, String name) => AndroidPlatform.saveToDownloads(
    name: name,
    sourcePath: source.path,
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
