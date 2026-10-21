import 'package:flutter/material.dart';

import '../../platform/default_gateway.dart';
import '../app_controller.dart';
import '../app_scope.dart';
import '../models.dart';
import '../ui.dart';
import '../widgets/job_tile.dart';
import '../widgets/ui_kit.dart';

/// WebDAV 扫描 / 修复（服务器可只读，也可上传按命名规则的副本）。
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
  bool _seeded = false;
  bool _gatewayLoading = false;
  JobFilter _filter = JobFilter.all;
  String _status = '';
  StatusTone _statusTone = StatusTone.neutral;

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
      setState(() {
        _status = describeError(e);
        _statusTone = StatusTone.bad;
      });
    }
  }

  /// 读取默认网关（一般就是路由器 IP）填进主机栏，省得手动去系统设置里查。
  ///
  /// 只填主机、不动端口 / 路径：网关是路由器时用户名密码也未必一样，
  /// 用户点「测试」就知道通不通。
  Future<void> _fillDefaultGateway(AppController controller) async {
    if (_gatewayLoading) return;
    setState(() {
      _gatewayLoading = true;
      _status = '正在读取默认网关…';
      _statusTone = StatusTone.neutral;
    });

    final gateway = await getDefaultGateway();
    if (!mounted) return;

    if (gateway == null) {
      setState(() {
        _gatewayLoading = false;
        _status = '读不到默认网关（可手动填写主机地址）';
        _statusTone = StatusTone.bad;
      });
      return;
    }

    _host.value = TextEditingValue(
      text: gateway,
      selection: TextSelection.collapsed(offset: gateway.length),
    );
    controller.updateSettings((s) => s.webdav.host = gateway);
    setState(() {
      _gatewayLoading = false;
      _status = '已填入默认网关 $gateway'
          '（服务器不是路由器时请改成实际 IP）';
      _statusTone = StatusTone.good;
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final all = controller.jobsOf(JobSource.webdav);
    final jobs =
        all.where((j) => _filter.matches(j.status)).toList(growable: false);
    final busy = controller.runningSource == JobSource.webdav;
    final canRun = !controller.running;

    return Scaffold(
      appBar: AppBar(title: const Text('WebDAV')),
      body: ListView.builder(
        padding: const EdgeInsets.only(top: 4, bottom: 4),
        itemCount: jobs.isEmpty ? 1 : jobs.length + 1,
        itemBuilder: (context, index) {
          if (index > 0) return JobTile(job: jobs[index - 1]);
          return _buildHeader(context, controller, all, jobs, busy, canRun);
        },
      ),
    );
  }

  Widget _buildHeader(
    BuildContext context,
    AppController controller,
    List<FixJob> all,
    /// 已按当前筛选过滤好的列表（外层 build 算过一次，别重复算）。
    List<FixJob> visible,
    bool busy,
    bool canRun,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final cfg = controller.settings.webdav;
    final copyExample = controller.settings.applyOutputName('示例.mp4');
    // 一次算完：按钮计数与「是否显示按钮」共用，别再各扫一遍全表。
    final fixable = controller.fixableCount(JobSource.webdav);

    return Column(
      children: [
        SectionCard(
          title: '服务器',
          icon: Icons.cloud_rounded,
          collapsible: true,
          initiallyExpanded: _pass.text.isEmpty,
          summary: '${cfg.host}:${cfg.port}${cfg.path}'
              ' · ${cfg.user.isEmpty ? '未填用户名' : cfg.user}'
              ' · ${_pass.text.isEmpty ? '未填密码' : '密码已填'}',
          trailing: canRun
              ? TextButton(
                  onPressed: () => _guard(() async {
                        setState(() {
                          _status = '正在测试连接…';
                          _statusTone = StatusTone.neutral;
                        });
                        final msg = await controller.testWebDavConnection();
                        if (mounted) {
                          setState(() {
                            _status = msg;
                            _statusTone = StatusTone.good;
                          });
                        }
                      }),
                  child: const Text('测试'),
                )
              : null,
          children: [
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _host,
                    enabled: canRun,
                    decoration: InputDecoration(
                      labelText: '主机',
                      isDense: true,
                      // 「读取默认网关」小闪电：填路由器地址，省得手动查 IP。
                      // 最小尺寸压到 32，少占一点输入宽度。
                      suffixIconConstraints: const BoxConstraints(
                        minWidth: 32,
                        minHeight: 32,
                      ),
                      suffixIcon: IconButton(
                        tooltip: '读取默认网关，快速填入主机',
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        iconSize: 20,
                        onPressed: _gatewayLoading || !canRun
                            ? null
                            : () => _fillDefaultGateway(controller),
                        icon: _gatewayLoading
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Icon(
                                Icons.bolt_rounded,
                                size: 20,
                                color: scheme.primary,
                              ),
                      ),
                    ),
                    onChanged: (v) =>
                        controller.updateSettings((s) => s.webdav.host = v),
                  ),
                ),
                const SizedBox(width: Insets.gap),
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _port,
                    enabled: canRun,
                    decoration: const InputDecoration(
                      labelText: '端口',
                      isDense: true,
                    ),
                    onChanged: (v) =>
                        controller.updateSettings((s) => s.webdav.port = v),
                  ),
                ),
              ],
            ),
            const SizedBox(height: Insets.gap),
            TextField(
              controller: _path,
              enabled: canRun,
              decoration: const InputDecoration(
                labelText: '路径',
                isDense: true,
              ),
              onChanged: (v) =>
                  controller.updateSettings((s) => s.webdav.path = v),
            ),
            const SizedBox(height: Insets.gap),
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
                const SizedBox(width: Insets.gap),
                Expanded(
                  child: TextField(
                    controller: _pass,
                    enabled: canRun,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: '密码',
                      isDense: true,
                    ),
                    onChanged: controller.updateWebDavPassword,
                  ),
                ),
              ],
            ),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('记住密码'),
              subtitle: const Text('保存在本机设置文件里（明文，不加密；也不会进云备份）'),
              value: controller.settings.rememberWebDavPassword,
              onChanged: controller.setRememberWebDavPassword,
            ),
            Wrap(
              spacing: Insets.gap,
              children: [
                FilterChip(
                  label: const Text('https'),
                  selected: cfg.https,
                  onSelected: canRun
                      ? (v) =>
                          controller.updateSettings((s) => s.webdav.https = v)
                      : null,
                ),
                FilterChip(
                  label: const Text('允许自签名证书'),
                  selected: cfg.insecure,
                  onSelected: canRun
                      ? (v) => controller
                          .updateSettings((s) => s.webdav.insecure = v)
                      : null,
                ),
              ],
            ),
          ],
        ),
        SectionCard(
          title: '操作',
          icon: Icons.play_circle_outline_rounded,
          children: [
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
              selected: {controller.webDavUploadCopies},
              onSelectionChanged: canRun
                  ? (v) => controller.setWebDavUploadCopies(v.first)
                  : null,
            ),
            Text(
              controller.webDavUploadCopies
                  ? (copyExample == '示例.mp4'
                      ? '在服务器生成「原名_fixed.mp4」副本（原文件不动）'
                      : '在服务器生成「$copyExample」这样按命名规则的副本（原文件不动）')
                  : '服务器只读（GET/PROPFIND）· 产物存到 ${controller.outputDescription.replaceFirst('输出：', '')}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: Insets.gap),
            Wrap(
              spacing: Insets.gap,
              runSpacing: Insets.gap,
              children: [
                FilledButton.icon(
                  onPressed: canRun
                      ? () => _guard(() async {
                            setState(() {
                              _status = '扫描并修复中…';
                              _statusTone = StatusTone.neutral;
                            });
                            await controller.scanWebDav(
                              fixAfterScan: true,
                            );
                            if (mounted) {
                              setState(() {
                                _status = '处理完成';
                                _statusTone = StatusTone.good;
                              });
                            }
                          })
                      : null,
                  icon: const Icon(Icons.build_rounded),
                  label: const Text('扫描并修复'),
                ),
                FilledButton.tonalIcon(
                  onPressed: canRun
                      ? () => _guard(() async {
                            setState(() {
                              _status = '扫描中…';
                              _statusTone = StatusTone.neutral;
                            });
                            await controller.scanWebDav(fixAfterScan: false);
                            if (mounted) {
                              setState(() {
                                _status = '扫描完成';
                                _statusTone = StatusTone.good;
                              });
                            }
                          })
                      : null,
                  icon: const Icon(Icons.travel_explore_rounded),
                  label: const Text('仅扫描'),
                ),
                if (!busy && all.isNotEmpty)
                  TextButton(
                    onPressed: () {
                      final messenger = ScaffoldMessenger.of(context);
                      final removed = all.length;
                      controller.clearJobs(JobSource.webdav);
                      messenger.showSnackBar(
                        SnackBar(
                          content: Text('已清空 $removed 项'),
                          action: SnackBarAction(
                            label: '撤销',
                            onPressed: controller.undoClear,
                          ),
                        ),
                      );
                    },
                    child: const Text('清空'),
                  ),
              ],
            ),
            if (_status.isNotEmpty) ...[
              const SizedBox(height: Insets.gap),
              StatusStrip(
                icon: _statusTone == StatusTone.bad
                    ? Icons.error_outline_rounded
                    : Icons.check_circle_outline_rounded,
                text: _status,
                tone: _statusTone,
              ),
            ],
          ],
        ),
        JobFilterBar(
          jobs: all,
          value: _filter,
          onChanged: (f) => setState(() => _filter = f),
        ),
        JobSummaryBar(
          jobs: all,
          active: busy ? controller.batchDone : null,
          total: busy ? controller.batchTotal : null,
          fixableCount: fixable,
          onFixAll: canRun && fixable > 0
              ? () => _guard(() => controller.fixWebDavJobs())
              : null,
          onProcessAll:
              canRun && controller.processAllCount(JobSource.webdav) > 0
                  ? () => runProcessAll(context, controller, JobSource.webdav)
                  : null,
        ),
        if (all.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 32),
            child: EmptyHint(
              icon: Icons.cloud_rounded,
              title: '远程扫描不整档下载',
              subtitle: '只读取文件头与 moov 就能判定交错质量；\n'
                  '几 GB 的文件通常只需几百 KB 流量。',
            ),
          )
        else if (visible.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 32),
            child: EmptyHint(
              icon: Icons.filter_alt_off_rounded,
              title: '这个筛选下没有任务',
              subtitle: '点上方「全部」查看完整列表。',
            ),
          ),
      ],
    );
  }
}
