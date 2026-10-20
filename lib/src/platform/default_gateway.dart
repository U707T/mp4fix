import 'dart:io';

import 'android_platform.dart';

/// 读取本机默认网关地址（一般就是路由器 IP），失败返回 null。
///
/// WebDAV 主机栏的「读取默认网关」小按钮用它快速取本机所在网段的地址，
/// 省得去系统设置里翻。各平台的数据源：
/// - Android: 平台通道（`ConnectivityManager`，官方接口、无需运行时权限）
///   → `/proc/net/route`（Android 10 起多半已被 SELinux 拦）→ `ip route`
/// - Linux: `ip route show default` → `/proc/net/route`
/// - Windows: `route print -4`（只解析数字行，不受系统语言影响）
/// - macOS: `route -n get default`
///
/// 只做“尽力而为”：拿不到就返回 null，由界面提示手动填写 —— 不猜
/// （按 /24 推 x.x.x.1 在多层路由 / 热点共享下经常是错的）。
Future<String?> getDefaultGateway() async {
  try {
    if (Platform.isAndroid) {
      final fromChannel = await AndroidPlatform.defaultGateway();
      if (fromChannel != null && _isIPv4(fromChannel)) return fromChannel;
      return _readProcNetRoute() ?? await _runIpRoute();
    }
    if (Platform.isLinux) {
      return (await _runIpRoute()) ?? _readProcNetRoute();
    }
    if (Platform.isWindows) {
      return await _run(
        'route',
        const ['print', '-4'],
        parseWindowsRoutePrint,
      );
    }
    if (Platform.isMacOS) {
      return await _run(
        'route',
        const ['-n', 'get', 'default'],
        parseMacOSRouteGetDefault,
      );
    }
  } catch (_) {
    // 读不到就算了：界面会提示手动填写，不影响任何已有功能。
  }
  return null;
}

Future<String?> _runIpRoute() =>
    _run('ip', const ['route', 'show', 'default'], parseIpRouteDefault);

Future<String?> _run(
  String executable,
  List<String> arguments,
  String? Function(String output) parse,
) async {
  try {
    final result = await Process.run(
      executable,
      arguments,
    ).timeout(const Duration(seconds: 3));
    if (result.exitCode != 0) return null;
    return parse(result.stdout.toString());
  } catch (_) {
    return null;
  }
}

String? _readProcNetRoute() {
  try {
    final file = File('/proc/net/route');
    if (!file.existsSync()) return null;
    return parseProcNetRoute(file.readAsStringSync());
  } catch (_) {
    return null;
  }
}

bool _isIPv4(String value) {
  final parts = value.trim().split('.');
  if (parts.length != 4) return false;
  for (final part in parts) {
    final number = int.tryParse(part);
    if (number == null || number < 0 || number > 255) return false;
  }
  return true;
}

/// 解析 `/proc/net/route`：Destination 为 `00000000` 的那行就是默认路由，
/// Gateway 是**小端**十六进制（`0101A8C0` → 192.168.1.1）。
String? parseProcNetRoute(String output) {
  for (final line in output.split('\n')) {
    final fields = line.trim().split(RegExp(r'\s+'));
    if (fields.length < 3) continue;
    if (!RegExp(r'^[0-9A-Fa-f]{8}$').hasMatch(fields[1])) continue;
    if (fields[1] != '00000000') continue;

    final gateway = int.tryParse(fields[2], radix: 16);
    if (gateway == null || gateway == 0) continue;

    final ip =
        '${gateway & 0xFF}.'
        '${(gateway >> 8) & 0xFF}.'
        '${(gateway >> 16) & 0xFF}.'
        '${(gateway >> 24) & 0xFF}';
    if (_isIPv4(ip)) return ip;
  }
  return null;
}

/// 解析 `ip route show default`：`default via 192.168.1.1 dev wlan0 ...`
String? parseIpRouteDefault(String output) {
  final match = RegExp(r'default\s+via\s+(\d{1,3}(?:\.\d{1,3}){3})')
      .firstMatch(output);
  final gateway = match?.group(1);
  return gateway != null && _isIPv4(gateway) ? gateway : null;
}

/// 解析 `route print -4`：只认前两列都是 `0.0.0.0` 的 IPv4 行，
/// `On-link` / `在链路上` 这类非 IP 网关会被过滤掉。
String? parseWindowsRoutePrint(String output) {
  for (final line in output.split('\n')) {
    final fields = line.trim().split(RegExp(r'\s+'));
    if (fields.length < 3) continue;
    if (fields[0] != '0.0.0.0' || fields[1] != '0.0.0.0') continue;
    if (_isIPv4(fields[2])) return fields[2];
  }
  return null;
}

/// 解析 `route -n get default`：`gateway: 192.168.1.1`
String? parseMacOSRouteGetDefault(String output) {
  final match = RegExp(r'gateway:\s*(\d{1,3}(?:\.\d{1,3}){3})')
      .firstMatch(output);
  final gateway = match?.group(1);
  return gateway != null && _isIPv4(gateway) ? gateway : null;
}
