import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

@immutable
class HomePodAudioDevice {
  const HomePodAudioDevice({
    required this.id,
    required this.name,
    required this.address,
    required this.port,
    this.model,
  });

  final String id, name, address;
  final int port;
  final String? model;

  static HomePodAudioDevice? decode(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    final name = value['name'];
    final address = value['address'];
    final port = value['port'];
    if (id is! String ||
        id.isEmpty ||
        name is! String ||
        address is! String ||
        port is! int ||
        port < 1 ||
        port > 65535) {
      return null;
    }
    return HomePodAudioDevice(
      id: id,
      name: name,
      address: address,
      port: port,
      model: value['model'] is String ? value['model'] as String : null,
    );
  }
}

/// Session state only: starting NAKU never discovers devices or enables capture.
/// Closing a settings dialog leaves an explicitly enabled session running.
class HomePodAudioControls extends ChangeNotifier {
  HomePodAudioControls({
    MethodChannel? channel,
    TargetPlatform? platform,
    this.pollInterval = const Duration(seconds: 2),
    this.installationTimeout = const Duration(minutes: 5),
  }) : _channel = channel ?? const MethodChannel('naku/homepod-audio'),
       supported = (platform ?? defaultTargetPlatform) == TargetPlatform.macOS;

  static final instance = HomePodAudioControls();
  final MethodChannel _channel;
  final Duration pollInterval;
  final Duration installationTimeout;
  bool supported;
  bool driverInstalled = false;
  bool needsDriverUpdate = false;
  String? driverName;
  String driverInstallStatus = 'idle';
  bool enabled = false;
  bool _audioRouteActive = false;
  bool get audioRouteActive => _audioRouteActive;
  double receiverVolume = 40;
  bool settingVolume = false;
  String? _volumeError;
  bool discovering = false;
  bool connecting = false;
  bool checkingDriver = false;
  String? driverCheckMessage;
  String status = 'off';
  String? error, deviceName, selectedDeviceId;
  double? latencyMs;
  List<HomePodAudioDevice> devices = const [];

  Future<void>? _initializing;
  Timer? _poller;
  Timer? _installationTimer;
  String? _pendingEnableDeviceId;
  bool _refreshing = false, _disposed = false, _desiredEnabled = false;
  int _generation = 0, _viewers = 0;

  bool get installing => _pendingEnableDeviceId != null;

  Future<void> initialize() => _initializing ??= refresh();

  void beginViewing() {
    if (_disposed) return;
    _viewers++;
    unawaited(initialize());
    _updatePolling();
  }

  void endViewing() {
    if (_viewers > 0) _viewers--;
    _updatePolling();
  }

  void _updatePolling() {
    final needed =
        !_disposed &&
        (audioRouteActive ||
            (supported && (_viewers > 0 || enabled || installing)));
    if (needed) {
      _poller ??= Timer.periodic(pollInterval, (_) => unawaited(refresh()));
    } else {
      _poller?.cancel();
      _poller = null;
    }
  }

  void _notify() {
    if (_disposed) return;
    _updatePolling();
    notifyListeners();
  }

  void _apply(Map? value) {
    if (value == null) return;
    if (value['supported'] is bool) supported = value['supported'] as bool;
    if (value['driverInstalled'] is bool) {
      driverInstalled = value['driverInstalled'] as bool;
    }
    if (value['driverName'] is String) {
      driverName = value['driverName'] as String;
    }
    if (value['driverInstallStatus'] is String) {
      driverInstallStatus = value['driverInstallStatus'] as String;
    }
    if (value['needsDriverUpdate'] is bool) {
      needsDriverUpdate = value['needsDriverUpdate'] as bool;
    }
    if (!driverInstalled || needsDriverUpdate) driverCheckMessage = null;
    enabled = !installing && supported && value['enabled'] == true;
    _desiredEnabled = enabled || installing;
    final reportedStatus = value['status'];
    status = installing
        ? 'installing'
        : reportedStatus is String
        ? reportedStatus
        : (enabled ? 'streaming' : 'off');
    _audioRouteActive = value['routeActive'] is bool
        ? value['routeActive'] as bool
        : enabled && status == 'streaming';
    final reportedVolume = value['receiverVolume'];
    if (reportedVolume is num && reportedVolume.isFinite) {
      receiverVolume = reportedVolume.toDouble().clamp(0, 100);
    }
    connecting = status == 'connecting';
    final reportedError = value['error'];
    if (reportedError is String && reportedError.isNotEmpty) {
      error = reportedError;
    } else if (enabled && _volumeError == null) {
      error = null;
    }
    deviceName = value['deviceName'] is String
        ? value['deviceName'] as String
        : null;
    final latency = value['latencyMs'];
    latencyMs = latency is num && latency.isFinite ? latency.toDouble() : null;
    if (value['devices'] is List) {
      devices = List.unmodifiable(
        (value['devices'] as List)
            .map(HomePodAudioDevice.decode)
            .whereType<HomePodAudioDevice>(),
      );
    }
    final activeId = value['deviceId'];
    if (installing) {
      selectedDeviceId = _pendingEnableDeviceId;
    } else if (activeId is String && activeId.isNotEmpty) {
      selectedDeviceId = activeId;
    } else if (!devices.any((device) => device.id == selectedDeviceId)) {
      selectedDeviceId = devices.length == 1 ? devices.single.id : null;
    }
  }

  Future<void> refresh() async {
    if (_disposed ||
        (!supported && !audioRouteActive) ||
        _refreshing ||
        connecting ||
        discovering ||
        checkingDriver ||
        settingVolume) {
      return;
    }
    _refreshing = true;
    final generation = _generation;
    try {
      final value = await _channel.invokeMapMethod<String, dynamic>('state');
      if (!_disposed && generation == _generation) _apply(value);
    } catch (exception) {
      if (!_disposed && generation == _generation) error = _message(exception);
    } finally {
      _refreshing = false;
      _notify();
    }
    if (!_disposed && generation == _generation) {
      await _resumeAfterInstallation(generation);
    }
  }

  Future<void> discover() async {
    await initialize();
    if (_disposed ||
        !supported ||
        discovering ||
        connecting ||
        installing ||
        checkingDriver) {
      return;
    }
    final generation = _generation;
    discovering = true;
    error = null;
    _notify();
    try {
      final value = await _channel.invokeMapMethod<String, dynamic>('discover');
      if (!_disposed && generation == _generation) _apply(value);
    } catch (exception) {
      if (!_disposed && generation == _generation) error = _message(exception);
    } finally {
      discovering = false;
      _notify();
    }
  }

  void selectDevice(String? id) {
    if (_disposed ||
        enabled ||
        connecting ||
        installing ||
        checkingDriver ||
        !devices.any((device) => device.id == id)) {
      return;
    }
    selectedDeviceId = id;
    error = null;
    _notify();
  }

  Future<bool> enable() async {
    if (_disposed ||
        !supported ||
        connecting ||
        enabled ||
        discovering ||
        installing ||
        checkingDriver) {
      return false;
    }
    final generation = ++_generation;
    await initialize();
    if (_disposed ||
        generation != _generation ||
        !supported ||
        connecting ||
        enabled ||
        discovering ||
        installing ||
        checkingDriver) {
      return false;
    }
    final id = selectedDeviceId;
    if (id == null) {
      error = '请先查找并选择 HomePod。';
      _notify();
      return false;
    }
    if (!driverInstalled || needsDriverUpdate) {
      return _beginInstallation(generation, id);
    }
    return _connect(generation, id);
  }

  Future<bool> _beginInstallation(int generation, String id) async {
    _pendingEnableDeviceId = id;
    _desiredEnabled = true;
    enabled = false;
    connecting = false;
    status = 'installing';
    driverInstallStatus = 'installing';
    error = null;
    _installationTimer?.cancel();
    _installationTimer = Timer(installationTimeout, () {
      if (_disposed || generation != _generation || !installing) return;
      _generation++;
      _clearPendingInstallation();
      _desiredEnabled = false;
      enabled = false;
      status = 'error';
      error = '驱动安装尚未完成，请完成安装后重新开启。';
      _notify();
      unawaited(_releaseNative());
    });
    _notify();
    try {
      final value = await _channel.invokeMapMethod<String, dynamic>(
        'installDriver',
      );
      if (_disposed || generation != _generation) return false;
      _apply(value);
      _notify();
      return await _resumeAfterInstallation(generation);
    } catch (exception) {
      if (!_disposed && generation == _generation) {
        _clearPendingInstallation();
        _desiredEnabled = false;
        enabled = false;
        status = 'error';
        error = _message(exception);
        _notify();
      }
      return false;
    }
  }

  Future<bool> _resumeAfterInstallation(int generation) async {
    final id = _pendingEnableDeviceId;
    if (_disposed ||
        generation != _generation ||
        id == null ||
        !driverInstalled ||
        needsDriverUpdate ||
        driverInstallStatus != 'ready') {
      return false;
    }
    _clearPendingInstallation();
    return _connect(generation, id);
  }

  void _clearPendingInstallation() {
    _pendingEnableDeviceId = null;
    _installationTimer?.cancel();
    _installationTimer = null;
  }

  Future<void> _releaseNative() async {
    final generation = _generation;
    try {
      final value = await _channel.invokeMapMethod<String, dynamic>('disable');
      if (!_disposed && generation == _generation) _apply(value);
    } catch (_) {}
  }

  Future<bool> setReceiverVolume(double value) async {
    if (_disposed ||
        !supported ||
        !enabled ||
        status != 'streaming' ||
        connecting ||
        installing ||
        checkingDriver ||
        discovering ||
        settingVolume) {
      return false;
    }
    if (!value.isFinite) {
      error = 'HomePod 音量无效。';
      _volumeError = error;
      _notify();
      return false;
    }
    final generation = ++_generation;
    final previousVolume = receiverVolume;
    receiverVolume = value.clamp(0, 100);
    settingVolume = true;
    _volumeError = null;
    error = null;
    _notify();
    try {
      final state = await _channel.invokeMapMethod<String, dynamic>(
        'setVolume',
        {'volume': receiverVolume},
      );
      if (_disposed || generation != _generation) return false;
      _apply(state);
      return true;
    } catch (exception) {
      if (!_disposed && generation == _generation) {
        receiverVolume = previousVolume;
        _volumeError = _message(exception);
        error = _volumeError;
      }
      return false;
    } finally {
      if (!_disposed && generation == _generation) settingVolume = false;
      _notify();
    }
  }

  Future<bool> checkDriver() async {
    if (_disposed ||
        !supported ||
        enabled ||
        audioRouteActive ||
        installing ||
        connecting ||
        discovering ||
        checkingDriver) {
      return false;
    }
    final generation = ++_generation;
    await initialize();
    if (_disposed ||
        generation != _generation ||
        !supported ||
        !driverInstalled ||
        needsDriverUpdate ||
        enabled ||
        audioRouteActive ||
        installing ||
        connecting ||
        discovering ||
        checkingDriver) {
      return false;
    }
    checkingDriver = true;
    driverCheckMessage = null;
    error = null;
    _notify();
    try {
      final value = await _channel.invokeMapMethod<String, dynamic>(
        'testDriver',
      );
      if (_disposed || generation != _generation) return false;
      if (value?['success'] != true || value?['restored'] != true) {
        error = '声卡检查未通过，请重试。';
        return false;
      }
      driverCheckMessage = '声卡检查通过';
      return true;
    } catch (exception) {
      if (!_disposed && generation == _generation) {
        error = _message(exception);
        if (exception is PlatformException &&
            exception.code == 'driver_update_required') {
          needsDriverUpdate = true;
        }
      }
      return false;
    } finally {
      if (!_disposed && generation == _generation) checkingDriver = false;
      _notify();
    }
  }

  Future<bool> _connect(int generation, String id) async {
    if (_disposed || generation != _generation) return false;
    _desiredEnabled = true;
    enabled = true;
    connecting = true;
    status = 'connecting';
    error = null;
    _volumeError = null;
    _notify();
    try {
      final value = await _channel.invokeMapMethod<String, dynamic>('enable', {
        'id': id,
        'latencyMs': 120,
      });
      if (_disposed || generation != _generation) {
        // A late successful connection must not undo the user's Stop action.
        if (!_disposed && !_desiredEnabled && value?['enabled'] == true) {
          await _channel.invokeMethod<void>('disable');
        }
        return false;
      }
      _apply(value);
      return enabled;
    } catch (exception) {
      if (!_disposed && generation == _generation) {
        enabled = false;
        _desiredEnabled = false;
        status = 'error';
        error = _message(exception);
        if (exception is PlatformException) {
          if (exception.code == 'driver_required') driverInstalled = false;
          if (exception.code == 'driver_update_required') {
            needsDriverUpdate = true;
          }
        }
        // Restore the prior system output if native setup failed partway.
        await _releaseNative();
      }
      return false;
    } finally {
      if (!_disposed && generation == _generation) connecting = false;
      _notify();
    }
  }

  Future<void> disable() async {
    if (_disposed || !supported) return;
    final generation = ++_generation;
    _clearPendingInstallation();
    checkingDriver = false;
    settingVolume = false;
    driverCheckMessage = null;
    _desiredEnabled = false;
    enabled = false;
    connecting = false;
    status = 'off';
    error = null;
    _volumeError = null;
    latencyMs = null;
    _notify();
    try {
      final value = await _channel.invokeMapMethod<String, dynamic>('disable');
      if (!_disposed && generation == _generation) {
        _apply(value);
        enabled = false;
        _desiredEnabled = false;
        connecting = false;
        status = 'off';
      }
    } catch (exception) {
      if (!_disposed && generation == _generation) error = _message(exception);
    }
    _notify();
  }

  static String _message(Object exception) => switch (exception) {
    PlatformException(:final message) => message ?? 'HomePod 音频连接失败。',
    MissingPluginException() => '此版本尚未提供 HomePod 音频输出。',
    _ => 'HomePod 音频连接失败，请重试。',
  };

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _poller?.cancel();
    _installationTimer?.cancel();
    super.dispose();
  }
}
