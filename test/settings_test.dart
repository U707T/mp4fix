import 'dart:convert';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:mp4fix/src/app/models.dart';

/// 设置持久化与 WebDAV 配置拼接。
void main() {
  test('AppSettings 经真实 JSON 编解码往返', () {
    final settings = AppSettings(
      thresholdMb: 8,
      includeOptimizable: true,
      themeMode: ThemeMode.dark,
      outputTreeUri: 'content://tree/x',
      outputDirPath: r'D:\Videos',
      scanInputTreeUri: 'content://tree/y',
      scanInputDirPath: r'D:\In',
      webdav: WebDavConfig(
        host: '192.168.28.156',
        port: '5244',
        path: '/dav/本地存储/Vedios',
        user: 'admin',
        https: false,
        insecure: true,
      ),
    );

    final decoded = jsonDecode(jsonEncode(settings.toJson())) as Map;
    final back = AppSettings.fromJson(decoded.cast<String, Object?>());

    expect(back.thresholdMb, 8);
    expect(back.includeOptimizable, isTrue);
    expect(back.themeMode, ThemeMode.dark);
    expect(back.outputTreeUri, 'content://tree/x');
    expect(back.outputDirPath, r'D:\Videos');
    expect(back.scanInputTreeUri, 'content://tree/y');
    expect(back.scanInputDirPath, r'D:\In');
    expect(back.webdav.host, '192.168.28.156');
    expect(back.webdav.port, '5244');
    expect(back.webdav.path, '/dav/本地存储/Vedios');
    expect(back.webdav.user, 'admin');
    expect(back.webdav.https, isFalse);
    expect(back.webdav.insecure, isTrue);
    expect(back.thresholdBytes, 8 * 1024 * 1024);
  });

  test('缺字段 / 脏数据不会抛异常（向后兼容）', () {
    final back = AppSettings.fromJson(const {
      'thresholdMb': 2,
      'themeMode': '不存在的模式',
      'webdav': {'host': 'h'},
    });
    expect(back.thresholdMb, 2);
    expect(back.themeMode, ThemeMode.system, reason: '未知主题应回退 system');
    expect(back.webdav.host, 'h');
    expect(back.webdav.port, '');
    expect(back.outputTreeUri, isNull);
  });

  test('WebDavConfig.url 拼接（含路径清洗 / 默认端口 / https）', () {
    expect(
      WebDavConfig(host: '1.2.3.4', port: '5244', path: 'dav/x').url,
      'http://1.2.3.4:5244/dav/x',
    );
    expect(WebDavConfig(host: '1.2.3.4', https: true).url,
        'https://1.2.3.4:443');
    expect(
      WebDavConfig(host: 'h', path: '//dav//x//').url,
      'http://h:80/dav/x',
    );
    expect(WebDavConfig(host: ' h ').url, 'http://h:80');
  });

  test('默认值', () {
    final s = AppSettings();
    expect(s.thresholdMb, 4);
    expect(s.includeOptimizable, isFalse);
    expect(s.themeMode, ThemeMode.system);
    expect(s.webdav.host, '');
  });
}
