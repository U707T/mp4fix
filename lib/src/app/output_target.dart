import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../platform/android_platform.dart';

/// 修复产物的输出目标。
abstract class OutputTarget {
  /// 界面展示的"保存到哪"说明。
  String get describe;

  /// 是否为可直接写入的本地目录（可省掉一次临时文件复制）。
  Directory? get directDirectory => null;

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
  Directory? get directDirectory => dir;

  @override
  Future<String> save(File source, String name) async {
    dir.createSync(recursive: true);
    final target = File('${dir.path}/$name');
    if (target.existsSync()) target.deleteSync();
    source.renameSync(target.path);
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
  Directory? get directDirectory => null;

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
  Directory? get directDirectory => null;

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
