/// WebDAV 扫描 / 修复流水线（纯 Dart，零第三方网络库）。
///
///  - [WebDavClient]：PROPFIND / GET(+Range) / PUT / DELETE / MOVE、Basic 认证、
///    自签名证书；自带重定向与完整性校验；
///  - [prefetchForInspect]：把"检测所需区域"（顶层盒头 + moov）预取回内存，
///    让同步的 MP4 检测器可以直接在远程文件上工作（无需整档下载）；
///  - [WebDavScanner]：递归扫描 + 逐文件健康检测（不支持 Range 时自动降级下载）；
///  - [WebDavFixer]：下载 → 无损重排 → 上传副本 / 保存本地。
library;

export 'prefetch.dart';
export 'webdav_client.dart';
export 'webdav_fixer.dart';
export 'webdav_scanner.dart';
