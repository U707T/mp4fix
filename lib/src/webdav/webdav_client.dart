import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:xml/xml.dart';

/// WebDAV 操作失败（消息面向用户展示, 含状态码等上下文）。
class WebDavException implements Exception {
  WebDavException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

/// 服务器不支持 Range 分段读取。
class RangeNotSupportedException extends WebDavException {
  RangeNotSupportedException(super.message);
}

/// 一个 WebDAV 条目。
class DavEntry {
  const DavEntry({
    required this.url,
    required this.name,
    required this.isDirectory,
    required this.size,
  });

  /// 绝对 URL（保留服务器给出的编码形式）。
  final String url;

  /// 解码后的文件名（展示用）。
  final String name;

  final bool isDirectory;

  /// 字节数；未知为 -1。
  final int size;

  @override
  String toString() => 'DavEntry($url, dir=$isDirectory, size=$size)';
}

/// 极简 WebDAV 客户端（纯 Dart，基于 [HttpClient]，Android / 桌面通用）。
///
/// 支持：PROPFIND（Depth 0/1）、GET（含 Range）、PUT、DELETE、MOVE；
/// 认证：HTTP Basic；可选允许自签名 / 不受信任的 HTTPS 证书。
class WebDavClient {
  WebDavClient(
    String baseUrl, {
    this.username = '',
    this.password = '',
    this.allowInsecureTls = false,
    this.connectTimeout = const Duration(seconds: 15),
    this.readTimeout = const Duration(seconds: 60),
  }) {
    final trimmed = baseUrl.trim();
    if (trimmed.isEmpty) throw ArgumentError('服务器地址不能为空');
    final withScheme = trimmed.contains('://') ? trimmed : 'https://$trimmed';
    root = sanitizeUrl(withScheme).replaceAll(RegExp(r'/+$'), '');
    _http = HttpClient()..connectionTimeout = connectTimeout;
    // 不使用透明解压：Range 读取与字节校验都要求拿到原始字节
    _http.autoUncompress = false;
    if (allowInsecureTls) {
      _http.badCertificateCallback = (cert, host, port) => true;
    }
  }

  final String username;
  final String password;
  final bool allowInsecureTls;

  final Duration connectTimeout;
  final Duration readTimeout;

  /// 规范化后的根地址（无尾部斜杠）。
  late final String root;

  late final HttpClient _http;

  /// 释放连接池（客户端不再使用时调用）。
  void close() => _http.close(force: true);

  static const String _userAgent = 'MP4Fix-WebDAV/2.0 (Flutter)';

  static final Uint8List _propfindBody = Uint8List.fromList(utf8.encode(
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<D:propfind xmlns:D="DAV:"><D:prop>'
    '<D:resourcetype/><D:getcontentlength/>'
    '</D:prop></D:propfind>',
  ));

  // ---------------------------------------------------------------- 目录列表

  /// PROPFIND Depth:1，列出目录下的条目（含自身）。
  Future<List<DavEntry>> list(String dirUrl) async {
    final base = ensureTrailingSlash(dirUrl);
    final r = await _send('PROPFIND', base,
        headers: const {'Depth': '1'}, body: _propfindBody);
    final text = await _readText(r.response, limit: _xmlLimit);
    if (!_isSuccess(r.status) && r.status != 207) {
      throw WebDavException('列表失败 HTTP ${r.status}${_suffix(text)}');
    }
    return _parseMultiStatus(text, base);
  }

  /// 资源信息（Depth:0）。不存在返回 null。
  Future<DavEntry?> stat(String url) async {
    final r = await _send('PROPFIND', url,
        headers: const {'Depth': '0'}, body: _propfindBody);
    if (r.status == 404) {
      await _drain(r.response);
      return null;
    }
    final text = await _readText(r.response, limit: _xmlLimit);
    if (!_isSuccess(r.status) && r.status != 207) {
      throw WebDavException('请求失败 HTTP ${r.status}${_suffix(text)}');
    }
    final entries = _parseMultiStatus(text, url);
    return entries.isEmpty ? null : entries.first;
  }

  Future<bool> exists(String url) async => (await stat(url)) != null;

  // ---------------------------------------------------------------- 读取

  /// 下载整个文件到 [dest]（覆盖写入）。返回实际字节数。
  Future<int> download(
    String url,
    File dest, {
    void Function(int done, int total)? onProgress,
  }) async {
    final r = await _send('GET', url);
    if (!_isSuccess(r.status)) {
      final text = await _readText(r.response, limit: 512);
      throw WebDavException('下载失败 HTTP ${r.status}${_suffix(text)}');
    }
    final total = r.response.contentLength;
    dest.parent.createSync(recursive: true);
    final sink = dest.openSync(mode: FileMode.write);
    var done = 0;
    try {
      await for (final chunk in r.response.timeout(readTimeout)) {
        sink.writeFromSync(chunk);
        done += chunk.length;
        onProgress?.call(done, total);
      }
    } on TimeoutException {
      throw WebDavException('下载超时（已接收 $done 字节）');
    } finally {
      sink.closeSync();
    }
    onProgress?.call(done, done);
    if (total >= 0 && done != total) {
      throw WebDavException('下载不完整：$done/$total 字节');
    }
    return done;
  }

  /// Range 读取 `[start]..[endInclusive]`（含两端）的全部字节。
  Future<Uint8List> getRange(String url, int start, int endInclusive) async {
    final length = endInclusive - start + 1;
    if (length <= 0) return Uint8List(0);
    final r = await _send('GET', url,
        headers: {'Range': 'bytes=$start-$endInclusive'});
    if (r.status == 206) {
      final bytes = await _readLimited(r.response, length + 1);
      if (bytes.length != length) {
        throw WebDavException('分段读取不完整：${bytes.length}/$length 字节');
      }
      return bytes;
    }
    if (r.status == 200) {
      await _drain(r.response);
      throw RangeNotSupportedException('服务器不支持分段读取（Range）');
    }
    final text = await _readText(r.response, limit: 512);
    throw WebDavException('分段读取失败 HTTP ${r.status}${_suffix(text)}');
  }

  /// 探测是否支持 Range（不支持时返回 false）。
  Future<bool> supportsRange(String url) async {
    try {
      await getRange(url, 0, 0);
      return true;
    } on RangeNotSupportedException {
      return false;
    }
  }

  // ---------------------------------------------------------------- 写入

  Future<void> upload(
    String url,
    File file, {
    void Function(int sent, int total)? onProgress,
  }) async {
    final r = await _send('PUT', url,
        headers: const {'Content-Type': 'application/octet-stream'},
        bodyFile: file,
        onUpload: onProgress);
    final text = await _readText(r.response, limit: 512);
    if (!_isSuccess(r.status)) {
      throw WebDavException('上传失败 HTTP ${r.status}${_suffix(text)}');
    }
  }

  Future<void> delete(String url) async {
    final r = await _send('DELETE', url);
    final text = await _readText(r.response, limit: 512);
    if (!_isSuccess(r.status)) {
      throw WebDavException('删除失败 HTTP ${r.status}${_suffix(text)}');
    }
  }

  Future<void> move(String fromUrl, String toUrl, {bool overwrite = true}) async {
    final r = await _send('MOVE', fromUrl, headers: {
      'Destination': toUrl,
      'Overwrite': overwrite ? 'T' : 'F',
    });
    final text = await _readText(r.response, limit: 512);
    if (!_isSuccess(r.status)) {
      throw WebDavException('移动失败 HTTP ${r.status}${_suffix(text)}');
    }
  }

  // ---------------------------------------------------------------- URL 工具

  /// 相对 href 解析为绝对 URL 并做安全百分号编码。
  String resolve(String hrefRaw, String against) {
    final href = hrefRaw.trim();
    if (href.isEmpty) return against;
    try {
      return Uri.parse(against).resolve(sanitizeUrl(href)).toString();
    } catch (e) {
      throw WebDavException('无法解析服务器返回的路径: $hrefRaw');
    }
  }

  /// 目录 URL 末尾补斜杠。
  String ensureTrailingSlash(String url) => url.endsWith('/') ? url : '$url/';

  /// 在 [url] 所在目录下生成同级的资源 URL。
  String sibling(String url, String newName) {
    final idx = url.lastIndexOf('/');
    final parent = idx >= 0 ? url.substring(0, idx) : '';
    return '$parent/${encodeSegment(newName)}';
  }

  /// 从 URL 提取解码后的文件名。
  String fileNameOf(String url) {
    final trimmed = url.replaceAll(RegExp(r'/+$'), '');
    final idx = trimmed.lastIndexOf('/');
    final seg = idx >= 0 ? trimmed.substring(idx + 1) : trimmed;
    return percentDecode(seg);
  }

  // ---------------------------------------------------------------- 请求底层

  static const int _xmlLimit = 32 << 20; // 目录列表 / PROPFIND 响应上限 32MB

  bool _isSuccess(int status) => status >= 200 && status <= 299;

  String _suffix(String body) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return '';
    final cut = trimmed.length > 200 ? trimmed.substring(0, 200) : trimmed;
    return ': $cut';
  }

  Future<void> _drain(HttpClientResponse response) async {
    try {
      await response.drain<void>().timeout(const Duration(seconds: 5));
    } catch (_) {
      // 忽略：连接会被 close(force) 或超时回收
    }
  }

  Future<Uint8List> _readLimited(HttpClientResponse response, int limit) async {
    final builder = BytesBuilder();
    try {
      await for (final chunk in response.timeout(readTimeout)) {
        builder.add(chunk);
        if (builder.length >= limit) break;
      }
    } on TimeoutException {
      throw WebDavException('读取响应超时');
    }
    final bytes = builder.takeBytes();
    return bytes.length <= limit ? bytes : Uint8List.sublistView(bytes, 0, limit);
  }

  Future<String> _readText(HttpClientResponse response, {required int limit}) async {
    final bytes = await _readLimited(response, limit);
    return utf8.decode(bytes, allowMalformed: true);
  }

  Future<_DavResponse> _send(
    String method,
    String url, {
    Map<String, String> headers = const {},
    List<int>? body,
    File? bodyFile,
    void Function(int sent, int total)? onUpload,
  }) async {
    var current = url;
    var redirects = 0;
    while (true) {
      final uri = Uri.tryParse(current);
      if (uri == null || !uri.hasScheme) {
        throw WebDavException('URL 无效: $current');
      }
      final scheme = uri.scheme.toLowerCase();
      if (scheme != 'http' && scheme != 'https') {
        throw WebDavException('不支持的协议: $scheme');
      }
      if (uri.host.isEmpty) throw WebDavException('URL 缺少主机名: $current');

      try {
        final request = await _http
            .openUrl(method, uri)
            .timeout(connectTimeout);
        request.followRedirects = false;
        request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
        request.headers.set(HttpHeaders.acceptHeader, '*/*');
        if (username.isNotEmpty || password.isNotEmpty) {
          final token = base64.encode(utf8.encode('$username:$password'));
          request.headers.set(HttpHeaders.authorizationHeader, 'Basic $token');
        }
        headers.forEach((k, v) => request.headers.set(k, v));

        if (body != null) {
          request.headers.contentLength = body.length;
          request.add(body);
        } else if (bodyFile != null) {
          final total = await bodyFile.length();
          request.headers.contentLength = total;
          var sent = 0;
          await for (final chunk in bodyFile.openRead()) {
            request.add(chunk);
            sent += chunk.length;
            onUpload?.call(sent, total);
          }
          onUpload?.call(sent, total);
        } else if (method == 'PUT' || method == 'POST') {
          request.headers.contentLength = 0;
        }

        final response = await request.close().timeout(connectTimeout);
        final status = response.statusCode;

        // 重定向：同方法重发（HttpClient 默认只跟随 GET/HEAD，这里统一处理）
        if (status >= 300 && status <= 399 && status != 304 && redirects < 4) {
          final location =
              response.headers.value(HttpHeaders.locationHeader)?.trim();
          if (location != null && location.isNotEmpty) {
            await _drain(response);
            redirects++;
            current = uri.resolve(sanitizeUrl(location)).toString();
            continue;
          }
        }
        return _DavResponse(status, response.headers, response);
      } on WebDavException {
        rethrow;
      } on TimeoutException {
        throw WebDavException(_timeoutHint(uri), null);
      } on SocketException catch (e) {
        final timedOut = e.osError?.message.toLowerCase().contains('timed out') ??
            false;
        throw WebDavException(
          '连接 ${uri.host}:${uri.port} 失败${timedOut ? _lanHint : ''}：${e.message}',
          e,
        );
      } on HandshakeException catch (e) {
        throw WebDavException('TLS 握手失败：${e.message}', e);
      } catch (e) {
        throw WebDavException(
          '网络请求失败（$method ${e.runtimeType}: $e）',
          e,
        );
      }
    }
  }

  /// Android 17 局域网权限提示（与 Kotlin 版一致）。
  static const String _lanHint =
      '（连接超时：服务器不可达，或被网络/系统策略拦截 —— '
      'Android 17 访问局域网需授予「本地网络」权限；也可能是防火墙/服务器未启动）';

  String _timeoutHint(Uri uri) => '连接 ${uri.host}:${uri.port} 超时$_lanHint';

  // ---------------------------------------------------------------- 解析

  List<DavEntry> _parseMultiStatus(String xmlText, String requestUrl) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(xmlText);
    } catch (e) {
      throw WebDavException('解析目录列表失败: $e', e);
    }
    final out = <DavEntry>[];
    for (final resp in doc.findAllElements('response', namespace: '*')) {
      final hrefEl = _firstOrNull(resp.findAllElements('href', namespace: '*'));
      final href = hrefEl?.innerText.trim();
      if (href == null || href.isEmpty) continue;
      final url = resolve(href, requestUrl);
      final isDir = resp.findAllElements('collection', namespace: '*').isNotEmpty;
      final sizeEl =
          _firstOrNull(resp.findAllElements('getcontentlength', namespace: '*'));
      final size = int.tryParse(sizeEl?.innerText.trim() ?? '') ?? -1;
      final clean = url.replaceAll(RegExp(r'/+$'), '');
      out.add(DavEntry(
        url: isDir ? '$clean/' : clean,
        name: fileNameOf(clean),
        isDirectory: isDir,
        size: size,
      ));
    }
    return out;
  }

  static T? _firstOrNull<T>(Iterable<T> items) => items.isEmpty ? null : items.first;

  // ---------------------------------------------------------------- 静态工具

  static const String _hex = '0123456789ABCDEF';

  static bool _isHexChar(int b) =>
      (b >= 0x30 && b <= 0x39) || (b >= 0x61 && b <= 0x66) || (b >= 0x41 && b <= 0x46);

  /// 对 URL 做安全编码：保留已有 `%XX` 与合法字符，其余按 UTF-8 百分号编码。
  ///
  /// 与 Kotlin 版的差异：`#` 一律编码（文件名里的 `#` 不再被当成 fragment 截断）。
  static String sanitizeUrl(String url) {
    final bytes = utf8.encode(url);
    final sb = StringBuffer();
    var i = 0;
    while (i < bytes.length) {
      final b = bytes[i];
      if (b == 0x25 /* % */ &&
          i + 2 < bytes.length &&
          _isHexChar(bytes[i + 1]) &&
          _isHexChar(bytes[i + 2])) {
        sb
          ..writeCharCode(0x25)
          ..writeCharCode(bytes[i + 1])
          ..writeCharCode(bytes[i + 2]);
        i += 3;
        continue;
      }
      final ok = (b >= 0x61 && b <= 0x7A) || // a-z
          (b >= 0x41 && b <= 0x5A) || // A-Z
          (b >= 0x30 && b <= 0x39) || // 0-9
          b == 0x2D || b == 0x2E || b == 0x5F || b == 0x7E || // - . _ ~
          b == 0x3A || b == 0x2F || b == 0x3F || // : / ?
          b == 0x5B || b == 0x5D || b == 0x40 || // [ ] @
          b == 0x21 || b == 0x24 || b == 0x26 || b == 0x27 || // ! $ & '
          b == 0x28 || b == 0x29 || b == 0x2A || b == 0x2B || // ( ) * +
          b == 0x2C || b == 0x3B || b == 0x3D; // , ; =
      if (ok) {
        sb.writeCharCode(b);
      } else {
        sb
          ..writeCharCode(0x25)
          ..writeCharCode(_hex.codeUnitAt(b >> 4))
          ..writeCharCode(_hex.codeUnitAt(b & 0x0F));
      }
      i++;
    }
    return sb.toString();
  }

  /// 对单个路径段做百分号编码。
  static String encodeSegment(String segment) {
    final bytes = utf8.encode(segment);
    final sb = StringBuffer();
    for (final v in bytes) {
      final ok = (v >= 0x61 && v <= 0x7A) ||
          (v >= 0x41 && v <= 0x5A) ||
          (v >= 0x30 && v <= 0x39) ||
          v == 0x2D ||
          v == 0x2E ||
          v == 0x5F ||
          v == 0x7E;
      if (ok) {
        sb.writeCharCode(v);
      } else {
        sb
          ..writeCharCode(0x25)
          ..writeCharCode(_hex.codeUnitAt(v >> 4))
          ..writeCharCode(_hex.codeUnitAt(v & 0x0F));
      }
    }
    return sb.toString();
  }

  /// 百分号解码（不把 `+` 当空格）。
  static String percentDecode(String s) {
    final out = BytesBuilder();
    final bytes = utf8.encode(s);
    var i = 0;
    while (i < bytes.length) {
      final b = bytes[i];
      if (b == 0x25 && i + 2 < bytes.length && _isHexChar(bytes[i + 1]) && _isHexChar(bytes[i + 2])) {
        final hi = int.parse(String.fromCharCode(bytes[i + 1]), radix: 16);
        final lo = int.parse(String.fromCharCode(bytes[i + 2]), radix: 16);
        out.addByte((hi << 4) | lo);
        i += 3;
      } else {
        out.addByte(b);
        i++;
      }
    }
    return utf8.decode(out.takeBytes(), allowMalformed: true);
  }
}

class _DavResponse {
  const _DavResponse(this.status, this.headers, this.response);

  final int status;
  final HttpHeaders headers;
  final HttpClientResponse response;
}
