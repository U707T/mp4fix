/// 出厂默认值（**单点维护**）。
///
/// WebDAV 表单默认就填好这台服务器 —— 不改动表单即可直接「测试连接 / 扫描」，
/// 而不是留空只显示灰色示例。用户在应用里编辑后，表单值会覆盖默认值并持久化。
///
/// 想换成自己的服务器：改这里的常量即可（或在应用里直接改表单）。
///
/// 注意：本文件**不依赖 Flutter**，命令行工具同样复用这些默认值。
abstract final class AppDefaults {
  /// 默认 WebDAV 服务器（alist）。
  static const String webDavHost = '192.168.28.156';
  static const String webDavPort = '5244';
  static const String webDavPath = '/dav';
  static const String webDavUser = 'admin';
  static const bool webDavHttps = false;
  static const bool webDavInsecure = false;

  /// 默认判定阈值（MB，最大交错距离）。
  static const int thresholdMb = 4;

  /// 由默认值拼出的完整 WebDAV 地址（命令行工具用）。
  static String get webDavUrl {
    final scheme = webDavHttps ? 'https' : 'http';
    final path = webDavPath.replaceAll(RegExp(r'^/+|/+$'), '');
    return '$scheme://$webDavHost:$webDavPort${path.isEmpty ? '' : '/$path'}';
  }
}
