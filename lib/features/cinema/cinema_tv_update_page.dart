import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'cinema_tv_update_service.dart';

/// Flat, remote-first TV updater. Nothing opens a browser or silently replaces
/// the app: the user starts the download and Android confirms installation.
class CinemaTVUpdatePage extends StatefulWidget {
  const CinemaTVUpdatePage({super.key, this.service});
  final CinemaTVUpdateService? service;
  @override
  State<CinemaTVUpdatePage> createState() => _CinemaTVUpdatePageState();
}

class _CinemaTVUpdatePageState extends State<CinemaTVUpdatePage>
    with WidgetsBindingObserver {
  late final _service = widget.service ?? CinemaTVUpdateService();
  CinemaTVInstalledVersion? _current;
  CinemaTVUpdateRelease? _release;
  File? _download;
  CancelToken? _cancel;
  bool _busy = false, _waitingPermission = false, _permissionRequired = false;
  double? _progress;
  String _status = '正在检查 TV 更新…';
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cancel?.cancel('页面已关闭');
    if (widget.service == null) _service.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _waitingPermission) {
      _waitingPermission = false;
      _resumePermission();
    }
  }

  Future<void> _resumePermission() async {
    try {
      final current = await _service.installed();
      if (!mounted) return;
      _current = current;
      if (current.canInstall) {
        await _install();
      } else {
        setState(() => _status = '尚未允许安装。允许后可继续，无需重新下载。');
      }
    } catch (error) {
      _showError(error);
    }
  }

  void _showError(Object error) {
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (error is DioException && CancelToken.isCancel(error)) {
        _error = null;
        _status = '下载已取消，可重新下载。';
      } else {
        _error = error is PlatformException
            ? error.message ?? '系统操作未完成，请重试。'
            : error is FormatException
            ? error.message
            : '暂时无法完成更新，请检查网络后重试。';
      }
    });
  }

  Future<void> _check() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _status = '正在检查 TV 更新…';
    });
    try {
      final current = await _service.installed();
      if (!mounted) return;
      setState(() => _current = current);
      final release = await _service.check(current);
      if (!mounted) return;
      setState(() {
        _current = current;
        _release = release;
        _download = null;
        _permissionRequired = false;
        _busy = false;
        _status = release == null
            ? '未发现可安装的 TV 新版本。'
            : '发现 TV 新版本 ${release.version}';
      });
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _downloadUpdate() async {
    final current = _current, release = _release;
    if (_busy || current == null || release == null) return;
    final cancel = CancelToken();
    _cancel = cancel;
    setState(() {
      _busy = true;
      _error = null;
      _progress = 0;
      _status = '正在下载安装包…';
    });
    try {
      final file = await _service.download(
        current,
        release,
        cancel: cancel,
        onProgress: (received, total) {
          if (!mounted || cancel.isCancelled) return;
          setState(() {
            _progress = received / total;
            _status = received == total ? '正在校验安装包…' : '正在下载安装包…';
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _download = file;
        _busy = false;
        _progress = null;
        _status = '下载和验证完成，可以安装。';
      });
      // The initial download button explicitly says 下载并安装. Android still
      // requires the user's own install confirmation in the system installer.
      await _install();
    } catch (error) {
      _showError(error);
    } finally {
      if (identical(_cancel, cancel)) _cancel = null;
    }
  }

  Future<void> _install() async {
    final file = _download, release = _release;
    if (_busy || file == null || release == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _status = '正在打开系统安装器…';
    });
    try {
      final opened = await _service.install(file, release);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _permissionRequired = !opened;
        _status = opened
            ? '请在系统安装器中确认更新。取消后仍可在此继续安装。'
            : '首次更新需要允许 NAKU TV 安装应用。返回后会继续安装。';
      });
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _permission() async {
    _waitingPermission = true;
    try {
      await _service.openInstallPermission();
    } catch (error) {
      _waitingPermission = false;
      _showError(error);
    }
  }

  Widget _button(
    String label,
    VoidCallback? action, {
    bool autofocus = false,
  }) => FilledButton(
    autofocus: autofocus,
    style: ButtonStyle(
      animationDuration: Duration.zero,
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 28, vertical: 18),
      ),
      side: WidgetStateProperty.resolveWith(
        (states) => BorderSide(
          color: states.contains(WidgetState.focused)
              ? Colors.white
              : Colors.transparent,
          width: 3,
        ),
      ),
      textStyle: const WidgetStatePropertyAll(
        TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
      ),
    ),
    onPressed: action,
    child: Text(label),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFF101010),
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: '返回',
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                ),
                const SizedBox(width: 16),
                const Text(
                  '软件更新',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 32,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 28),
            if (_current != null)
              Text(
                'NAKU TV ${_current!.version} · ${_current!.build}',
                style: const TextStyle(fontSize: 18, color: Colors.white60),
              ),
            const SizedBox(height: 18),
            Text(
              _error ?? _status,
              style: TextStyle(
                fontSize: 22,
                color: _error == null ? Colors.white : const Color(0xFFFFC4B8),
              ),
            ),
            const SizedBox(height: 16),
            if (_busy) ...[
              LinearProgressIndicator(value: _progress),
              const SizedBox(height: 12),
              if (_progress != null)
                Text(
                  '${(_progress! * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(color: Colors.white70, fontSize: 18),
                ),
            ],
            Expanded(
              child: _release?.notes.isNotEmpty == true
                  ? SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Text(
                        _release!.notes,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 18,
                          height: 1.5,
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            if (!_busy)
              Wrap(
                spacing: 18,
                runSpacing: 12,
                children: [
                  if (_permissionRequired)
                    _button('允许安装并继续', _permission, autofocus: true)
                  else if (_download != null)
                    _button('继续安装', _install, autofocus: true)
                  else if (_release != null)
                    _button(
                      '下载并安装 ${_release!.version}',
                      _downloadUpdate,
                      autofocus: true,
                    )
                  else
                    _button('重新检查', _check, autofocus: true),
                ],
              )
            else if (_cancel != null)
              _button('取消下载', () => _cancel?.cancel('用户取消下载'), autofocus: true),
            const SizedBox(height: 16),
            const Text(
              '更新会保留登录、收藏和观看记录，安装由 Android 系统确认。',
              style: TextStyle(color: Colors.white54, fontSize: 16),
            ),
          ],
        ),
      ),
    ),
  );
}
