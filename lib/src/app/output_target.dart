import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../platform/android_platform.dart';

/// 修复产物的输出目标。
abstract class OutputTarget {
  /// 界面展示的"保存到哪"说明。
  String get describe;

  /// 把 [source] 保存为 [name]（同名覆盖），返回展示位置。
  Future<String> save(File source, String name);
}

/// 普通目录（桌面 / 应用文档目录回退）。
class DirectoryOutputTarget implements OutputTarget {
  DirectoryOutputTarget(this.dir);

  final Directory dir;

  @override
  String get describe => dir.path;

  @override
  Future<String> save(File source, String name) async {
    dir.createSync(recursive: true);
    final target = File('${dir.path}/$name');

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
    return name;
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
  Future<String> save(File source, String name) => AndroidPlatform.saveToDownloads(
    name: name,
    sourcePath: source.path,
  );
}

/// 兜底：应用文档目录下的 `MP4Fix/`（无需任何权限）。
Future<OutputTarget> defaultOutputTarget() async {
  final dir = await getApplicationDocumentsDirectory();
  final out = Directory('${dir.path}/MP4Fix');
  if (!out.existsSync()) out.createSync(recursive: true);
  return DirectoryOutputTarget(out);
}
