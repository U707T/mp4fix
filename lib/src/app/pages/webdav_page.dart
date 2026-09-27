import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../models.dart';
import '../widgets/job_tile.dart';

/// WebDAV 扫描 / 修复（服务器可只读，也可上传 `原名_fixed.mp4` 副本）。
class WebDavPage extends StatefulWidget {
  const WebDavPage({super.key});

  @override
  State<WebDavPage> createState() => _WebDavPageState();
}

class _WebDavPageState extends State<WebDavPage> {
  late TextEditingController _host;
  late TextEditingController _port;
  late TextEditingController _path;
  late TextEditingController _user;
  late TextEditingController _pass;
  bool _uploadCopies = true;
  String _status = '';
  bool _seeded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_seeded) return;
    _seeded = true;
    final controller = AppScope.of(context);
    final cfg = controller.settings.webdav;
    _host = TextEditingController(text: cfg.host);
    _port = TextEditingController(text: cfg.port);
    _path = TextEditingController(text: cfg.path);
    _user = TextEditingController(text: cfg.user);
    _pass = TextEditingController(text: controller.webDavPassword);
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _path.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = describeError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final jobs = controller.jobsOf(JobSource.webdav);
    final busy = controller.runningSource == JobSource.webdav;
    final canRun = !controller.running;

    return Scaffold(
      appBar: AppBar(title: const Text('WebDAV')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: _host,
                        enabled: canRun,
                        decoration: const InputDecoration(
                          labelText: '主机',
                          hintText: '默认已填，可直接改',
                          isDense: true,
                        ),
                        onChanged: (v) =>
                            controller.updateSettings((s) => s.webdav.host = v),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 2,
                      child: TextField(
                        controller: _port,
                        enabled: canRun,
                        decoration: const InputDecoration(
                          labelText: '端口',
                          hintText: '5244',
                          isDense: true,
                        ),
                        onChanged: (v) =>
                            controller.updateSettings((s) => s.webdav.port = v),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _path,
                  enabled: canRun,
                  decoration: const InputDecoration(
                    labelText: '路径',
                    hintText: '/dav（可指向子目录）',
                    isDense: true,
                  ),
                  onChanged: (v) =>
                      controller.updateSettings((s) => s.webdav.path = v),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _user,
                        enabled: canRun,
                        decoration: const InputDecoration(
                          labelText: '用户名',
                          isDense: true,
                        ),
                        onChanged: (v) =>
                            controller.updateSettings((s) => s.webdav.user = v),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _pass,
                        enabled: canRun,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: '密码（不落盘）',
                          isDense: true,
                        ),
                        onChanged: controller.updateWebDavPassword,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: SwitchListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: const Text('https'),
                        value: controller.settings.webdav.https,
                        onChanged: canRun
                            ? (v) => controller
                                .updateSettings((s) => s.webdav.https = v)
                            : null,
                      ),
                    ),
                    Expanded(
                      child: SwitchListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: const Text('允许自签名证书'),
                        value: controller.settings.webdav.insecure,
                        onChanged: canRun
                            ? (v) => controller
                                .updateSettings((s) => s.webdav.insecure = v)
                            : null,
                      ),
                    ),
                  ],
                ),
                SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('记住密码'),
                  subtitle: const Text('保存在本机设置文件里（明文，不加密）'),
                  value: controller.settings.rememberWebDavPassword,
                  onChanged: controller.setRememberWebDavPassword,
                ),
                SegmentedButton<bool>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                      value: true,
                      icon: Icon(Icons.cloud_upload_rounded, size: 18),
                      label: Text('上传副本'),
                    ),
                    ButtonSegment(
                      value: false,
                      icon: Icon(Icons.download_rounded, size: 18),
                      label: Text('保存到本地'),
                    ),
                  ],
                  selected: {_uploadCopies},
                  onSelectionChanged: canRun
                      ? (v) => setState(() => _uploadCopies = v.first)
                      : null,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: canRun
                          ? () => _guard(() async {
                                setState(() => _status = '正在测试连接…');
                                final msg =
                                    await controller.testWebDavConnection();
                                if (mounted) setState(() => _status = msg);
                              })
                          : null,
                      icon: const Icon(Icons.wifi_tethering_rounded),
                      label: const Text('测试连接'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: canRun
                          ? () => _guard(() async {
                                setState(() => _status = '扫描中…');
                                await controller.scanWebDav(fixAfterScan: false);
                                if (mounted) setState(() => _status = '扫描完成');
                              })
                          : null,
                      icon: const Icon(Icons.travel_explore_rounded),
                      label: const Text('仅扫描'),
                    ),
                    FilledButton.icon(
                      onPressed: canRun
                          ? () => _guard(() async {
                                setState(() => _status = '扫描并修复中…');
                                await controller.scanWebDav(
                                  fixAfterScan: true,
                                  uploadCopies: _uploadCopies,
                                );
                                if (mounted) setState(() => _status = '处理完成');
                              })
                          : null,
                      icon: const Icon(Icons.build_rounded),
                      label: const Text('扫描并修复'),
                    ),
                    if (busy)
                      OutlinedButton.icon(
                        onPressed: controller.requestCancel,
                        icon: const Icon(Icons.stop_rounded),
                        label: const Text('停止'),
                      ),
                    TextButton(
                      onPressed: canRun && jobs.isNotEmpty
                          ? () => controller.clearJobs(JobSource.webdav)
                          : null,
                      child: const Text('清空'),
                    ),
                  ],
                ),
                if (_status.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    _status,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: jobs.isEmpty
                ? const EmptyHint(
                    icon: Icons.cloud_rounded,
                    title: '远程扫描不整档下载',
                    subtitle: '仅读取文件头与 moov 即可判定交错质量；\n「保存到本地」模式服务器全程只读（只有 GET/PROPFIND）',
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 96),
                    itemCount: jobs.length,
                    itemBuilder: (context, i) => JobTile(job: jobs[i]),
                  ),
          ),
        ],
      ),
    );
  }
}
