import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 测试用迷你 WebDAV 服务器（`dart:io HttpServer`）。
///
/// 支持：PROPFIND(Depth 0/1)、GET（含 Range，可通过 [rangeEnabled] 关闭）、
/// PUT、DELETE、MOVE、可选 Basic 认证。
class TestDavServer {
  TestDavServer._(
    this.root,
    this._server,
    this.user,
    this.pass,
    this.rangeEnabled,
  );

  final Directory root;
  final HttpServer _server;
  final String? user;
  final String? pass;
  final bool rangeEnabled;

  int requestCount = 0;

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  static Future<TestDavServer> start(
    Directory root, {
    String? user,
    String? pass,
    bool rangeEnabled = true,
    int port = 0,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    final dav = TestDavServer._(root, server, user, pass, rangeEnabled);
    server.listen(dav._handle);
    return dav;
  }

  Future<void> close() => _server.close(force: true);

  // ---------------------------------------------------------------- 处理

  Future<void> _handle(HttpRequest req) async {
    try {
      requestCount++;
      if (!await _checkAuth(req)) return;

      final path = _percentDecode(req.uri.path).replaceFirst(RegExp(r'^/+'), '');
      final fsPath = '${root.path}/$path';
      switch (req.method.toUpperCase()) {
        case 'PROPFIND':
          await _handlePropfind(req, fsPath);
        case 'GET':
          await _handleGet(req, File(fsPath));
        case 'PUT':
          await _handlePut(req, File(fsPath));
        case 'DELETE':
          await _handleDelete(req, fsPath);
        case 'MOVE':
          await _handleMove(req, File(fsPath));
        default:
          await _respond(req, 405, utf8.encode('method not allowed'), 'text/plain');
      }
    } catch (e) {
      try {
        await _respond(req, 500, utf8.encode('$e'), 'text/plain');
      } catch (_) {
        // 连接可能已关闭
      }
    }
  }

  Future<bool> _checkAuth(HttpRequest req) async {
    final expectedUser = user;
    if (expectedUser == null) return true;
    final auth = req.headers.value('Authorization');
    final expected =
        'Basic ${base64.encode(utf8.encode('$expectedUser:${pass ?? ''}'))}';
    if (auth != expected) {
      req.response.headers.set('WWW-Authenticate', 'Basic realm="test"');
      await _respond(req, 401, utf8.encode('unauthorized'), 'text/plain');
      return false;
    }
    return true;
  }

  /// 目录优先解析为 [Directory]，否则按 [File] 处理。
  static FileSystemEntity _entityOf(String path) {
    final dir = Directory(path);
    return dir.existsSync() ? dir : File(path);
  }

  Future<void> _handlePropfind(HttpRequest req, String fsPath) async {
    final entity = _entityOf(fsPath);
    if (!entity.existsSync()) {
      await _respond(req, 404, utf8.encode('not found'), 'text/plain');
      return;
    }
    final depth = (req.headers.value('Depth') ?? '1').trim();
    final entries = <FileSystemEntity>[entity];
    if (depth != '0' && entity is Directory) {
      final children = entity.listSync()..sort((a, b) => a.path.compareTo(b.path));
      entries.addAll(children);
    }
    final xml = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="utf-8"?>')
      ..writeln('<D:multistatus xmlns:D="DAV:">');
    for (final e in entries) {
      final isDir = e is Directory;
      final length = e is File ? e.lengthSync() : 0;
      xml
        ..writeln(' <D:response>')
        ..writeln('  <D:href>${_xmlEscape(_hrefOf(e))}</D:href>')
        ..writeln('  <D:propstat>')
        ..writeln('   <D:prop>')
        ..writeln(isDir
            ? '    <D:resourcetype><D:collection/></D:resourcetype>'
            : '    <D:resourcetype/><D:getcontentlength>$length</D:getcontentlength>')
        ..writeln('   </D:prop>')
        ..writeln('   <D:status>HTTP/1.1 200 OK</D:status>')
        ..writeln('  </D:propstat>')
        ..writeln(' </D:response>');
    }
    xml.writeln('</D:multistatus>');
    await _respond(
      req,
      207,
      utf8.encode(xml.toString()),
      'application/xml; charset=utf-8',
    );
  }

  Future<void> _handleGet(HttpRequest req, File file) async {
    if (!file.existsSync()) {
      await _respond(req, 404, utf8.encode('not found'), 'text/plain');
      return;
    }
    final size = file.lengthSync();
    final rangeHeader = req.headers.value('Range')?.trim();
    var start = 0;
    var end = size - 1;
    var useRange = false;
    if (rangeEnabled && rangeHeader != null && rangeHeader.startsWith('bytes=')) {
      final spec = rangeHeader.substring('bytes='.length).split(',').first;
      final parts = spec.split('-');
      if (parts.length == 2) {
        final a = int.tryParse(parts[0]);
        final b = int.tryParse(parts[1]);
        if (a != null) {
          start = a;
          end = b != null ? (b > size - 1 ? size - 1 : b) : size - 1;
          useRange = true;
        } else if (b != null) {
          start = size - b < 0 ? 0 : size - b;
          useRange = true;
        }
      }
      if (useRange && (start > size - 1 || start > end)) {
        await _respond(req, 416, utf8.encode('range not satisfiable'), 'text/plain');
        return;
      }
    }
    final length = end - start + 1;
    final data = _readSlice(file, start, length);
    if (useRange) {
      req.response.headers.set(
        'Content-Range',
        'bytes $start-${start + data.length - 1}/$size',
      );
      await _respond(req, 206, data, 'application/octet-stream');
    } else {
      await _respond(req, 200, data, 'application/octet-stream');
    }
  }

  static List<int> _readSlice(File file, int start, int length) {
    final raf = file.openSync();
    try {
      raf.setPositionSync(start);
      return raf.readSync(length);
    } finally {
      raf.closeSync();
    }
  }

  Future<void> _handlePut(HttpRequest req, File file) async {
    file.parent.createSync(recursive: true);
    final builder = BytesBuilder();
    await for (final chunk in req) {
      builder.add(chunk);
    }
    await file.writeAsBytes(builder.takeBytes());
    await _respond(req, 201, utf8.encode('created'), 'text/plain');
  }

  Future<void> _handleDelete(HttpRequest req, String fsPath) async {
    final entity = _entityOf(fsPath);
    if (!entity.existsSync()) {
      await _respond(req, 404, utf8.encode('not found'), 'text/plain');
      return;
    }
    try {
      if (entity is Directory) {
        await entity.delete(recursive: true);
      } else {
        await entity.delete();
      }
    } catch (e) {
      await _respond(req, 500, utf8.encode('delete failed: $e'), 'text/plain');
      return;
    }
    await _respond(req, 204, const <int>[], 'text/plain');
  }

  Future<void> _handleMove(HttpRequest req, File source) async {
    if (!source.existsSync()) {
      await _respond(req, 404, utf8.encode('not found'), 'text/plain');
      return;
    }
    final destination = req.headers.value('Destination')?.trim();
    if (destination == null || destination.isEmpty) {
      await _respond(req, 400, utf8.encode('missing destination'), 'text/plain');
      return;
    }
    final destPath = _percentDecode(Uri.parse(destination).path);
    final destFile =
        File('${root.path}/${destPath.replaceFirst(RegExp(r'^/+'), '')}');
    final overwrite = (req.headers.value('Overwrite') ?? 'T').trim();
    if (destFile.existsSync() && overwrite == 'F') {
      await _respond(req, 412, utf8.encode('precondition failed'), 'text/plain');
      return;
    }
    if (destFile.existsSync()) destFile.deleteSync();
    destFile.parent.createSync(recursive: true);
    try {
      source.renameSync(destFile.path);
    } catch (e) {
      await _respond(req, 500, utf8.encode('move failed: $e'), 'text/plain');
      return;
    }
    await _respond(req, 201, utf8.encode('moved'), 'text/plain');
  }

  // ---------------------------------------------------------------- 工具

  String _hrefOf(FileSystemEntity entity) {
    var rel = entity.path.substring(root.path.length);
    if (!rel.startsWith('/')) rel = '/$rel';
    if (entity is Directory && !rel.endsWith('/')) rel = '$rel/';
    return _encodePath(rel);
  }

  static String _encodePath(String path) =>
      path.split('/').map(Uri.encodeComponent).join('/');

  static String _percentDecode(String s) {
    final out = BytesBuilder();
    final bytes = utf8.encode(s);
    var i = 0;
    while (i < bytes.length) {
      if (bytes[i] == 0x25 && i + 2 < bytes.length) {
        final hi = int.tryParse(String.fromCharCode(bytes[i + 1]), radix: 16);
        final lo = int.tryParse(String.fromCharCode(bytes[i + 2]), radix: 16);
        if (hi != null && lo != null) {
          out.addByte((hi << 4) | lo);
          i += 3;
          continue;
        }
      }
      out.addByte(bytes[i]);
      i++;
    }
    return utf8.decode(out.takeBytes(), allowMalformed: true);
  }

  static String _xmlEscape(String s) =>
      s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

  Future<void> _respond(
    HttpRequest req,
    int code,
    List<int> body,
    String contentType,
  ) async {
    final response = req.response;
    response.statusCode = code;
    if (contentType.isNotEmpty) {
      response.headers.set('Content-Type', contentType);
    }
    response.headers.contentLength = body.length;
    if (body.isNotEmpty) response.add(body);
    await response.close();
  }
}
