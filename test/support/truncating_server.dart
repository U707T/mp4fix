import 'dart:io';

/// 裸 socket 的"坏服务器"：**声明的 Content-Length 大于实际发送**，用于验证客户端
/// 能识别"下载被截断"，而不是静默产出一个半截文件。
///
/// （`HttpServer` + `detachSocket()` 在这个场景下客户端会挂起，
///   裸 socket 才能精确模拟"连接被提前关闭"。）
class TruncatingServer {
  TruncatingServer._(this._server);

  final ServerSocket _server;

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  /// 只发送 [sentRatio] 比例的字节，但声明完整的 Content-Length。
  static Future<TruncatingServer> start({
    required File file,
    double sentRatio = 0.5,
  }) async {
    final payload = file.readAsBytesSync();
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final instance = TruncatingServer._(server);
    server.listen((socket) async {
      try {
        // 读掉请求头
        final buf = <int>[];
        await for (final chunk in socket) {
          buf.addAll(chunk);
          if (String.fromCharCodes(buf).contains('\r\n\r\n')) break;
        }
        socket.add(
          ('HTTP/1.1 200 OK\r\n'
                  'Content-Length: ${payload.length}\r\n'
                  'Content-Type: application/octet-stream\r\n'
                  'Connection: close\r\n\r\n')
              .codeUnits,
        );
        socket.add(payload.sublist(0, (payload.length * sentRatio).floor()));
        await socket.flush();
      } catch (_) {
        // 忽略：测试场景
      } finally {
        await socket.close();
      }
    });
    return instance;
  }

  Future<void> close() => _server.close();
}
