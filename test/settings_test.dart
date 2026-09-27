import 'dart:convert';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:mp4fix/src/app/defaults.dart';
import 'package:mp4fix/src/app/models.dart';

/// 设置持久化、出厂默认值（预填的 WebDAV 服务器）与「记住密码」。
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
        host: '10.0.0.9',
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
    expect(back.webdav.host, '10.0.0.9');
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
    expect(back.webdav.port, AppDefaults.webDavPort, reason: '缺省端口回退默认');
    expect(back.outputTreeUri, isNull);
  });

  test('出厂默认：WebDAV 表单已填好默认服务器（不动它就是它）', () {
    final fresh = AppSettings();
    expect(fresh.webdav.host, AppDefaults.webDavHost);
    expect(fresh.webdav.port, AppDefaults.webDavPort);
    expect(fresh.webdav.path, AppDefaults.webDavPath);
    expect(fresh.webdav.user, AppDefaults.webDavUser);
    expect(fresh.webdav.url, AppDefaults.webDavUrl);
    expect(AppDefaults.webDavUrl, 'http://192.168.28.156:5244/dav');

    // 老版本存过空表单 → 升级后自动补上默认服务器
    final legacy = AppSettings.fromJson(const {
      'webdav': {'host': '', 'port': '   ', 'path': '', 'user': ''},
    });
    expect(legacy.webdav.host, AppDefaults.webDavHost);
    expect(legacy.webdav.path, AppDefaults.webDavPath);
    expect(legacy.webdav.user, AppDefaults.webDavUser);

    // 用户改过的值优先，未改的字段仍用默认
    final custom = AppSettings.fromJson(const {
      'webdav': {'host': '10.0.0.2', 'port': '8080'},
    });
    expect(custom.webdav.host, '10.0.0.2');
    expect(custom.webdav.port, '8080');
    expect(custom.webdav.path, AppDefaults.webDavPath);
  });

  test('WebDavConfig.url 拼接（路径清洗 / 端口 / https / 空白主机）', () {
    expect(WebDavConfig(host: 'h', port: '5244', path: 'dav/x').url,
        'http://h:5244/dav/x');
    // 端口留空 → 按协议默认端口
    expect(WebDavConfig(host: 'h', port: '', path: '').url, 'http://h:80');
    expect(WebDavConfig(host: 'h', port: '', path: '', https: true).url,
        'https://h:443');
    // 未指定端口 → 沿用默认端口
    expect(WebDavConfig(host: 'h', path: '').url, 'http://h:5244');
    expect(WebDavConfig(host: 'h', path: '', https: true).url,
        'https://h:5244');
    // 折叠重复斜杠、去掉首尾斜杠
    expect(WebDavConfig(host: 'h', path: '//dav//x//').url, 'http://h:5244/dav/x');
    // 主机首尾空白会被清理
    expect(WebDavConfig(host: ' h ', path: '').url, 'http://h:5244');
  });

  test('记住密码：默认关闭，开启后随设置往返', () {
    expect(AppSettings().rememberWebDavPassword, isFalse, reason: '默认不记住');

    final decoded = jsonDecode(jsonEncode(AppSettings(
      rememberWebDavPassword: true,
      webDavPassword: 'p@ss word',
    ).toJson())) as Map;
    final back = AppSettings.fromJson(decoded.cast<String, Object?>());
    expect(back.rememberWebDavPassword, isTrue);
    expect(back.webDavPassword, 'p@ss word');
  });

  test('默认值', () {
    final s = AppSettings();
    expect(s.thresholdMb, AppDefaults.thresholdMb);
    expect(s.includeOptimizable, isFalse);
    expect(s.themeMode, ThemeMode.system);
    expect(s.webDavPassword, isEmpty);
  });
}
