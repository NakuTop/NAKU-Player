import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:kazumi/modules/collect/collect_module.dart';
import 'package:kazumi/modules/history/history_sync.dart';
import 'package:kazumi/services/storage/history_storage_coordinator.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'cinema_models.dart';
import 'cinema_nas_media.dart';
import 'cinema_nas_sync_model.dart';
import 'cinema_store.dart';

/// Owned by the home page, so syncing continues outside the NAS browser.
class CinemaNASSync extends ChangeNotifier with WidgetsBindingObserver {
  CinemaNASSync(this.store, {CinemaNASClient? client, File? file})
    : client = client ?? CinemaNASClient(),
      _file = file;
  final CinemaStore store;
  final CinemaNASClient client;
  File? _file;
  CinemaNASSyncState? _state;
  Map<String, dynamic>? _pending;
  String _published = '';
  int _sequence = 0;
  bool _closed = false, _running = false, _paused = false, _enabled = true;
  bool _observing = false, _flushQueued = false;
  bool _captureNeedsSave = false;
  Timer? _timer, _debounce;
  String? _pullRevision;
  List<String> _pullSnapshots = const [];
  DateTime? _retryPollAfter;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  String status = '登录 NAS 后可同步全部历史与收藏';
  String? path;
  DateTime? lastSuccess;
  bool get busy => _running;
  bool get paused => _paused;
  bool get enabled => _enabled;
  String? get account => _state?.account;
  final _equal = const DeepCollectionEqualityForSync();
  Future<void>? _starting;
  Future<void> _saveTail = Future.value();

  static List<String>? _snapshotTokens(Object? value) {
    if (value is! List ||
        value.length > 100 ||
        value.toSet().length != value.length ||
        !value.every(
          (token) =>
              token is String && RegExp(r'^[a-f0-9]{32}$').hasMatch(token),
        )) {
      return null;
    }
    return List<String>.from(value);
  }

  Future<void> start() => _starting ??= _start();
  Future<void> _start() async {
    try {
      await store.load();
      _file ??= File(
        '${(await getApplicationSupportDirectory()).path}/cinema/nas-sync-v1.json',
      );
      if (await _file!.exists()) {
        final raw =
            jsonDecode(await _file!.readAsString()) as Map<String, dynamic>;
        if (raw['version'] != 1 ||
            raw['account'] is! String ||
            raw['device'] is! String) {
          throw const FormatException('本地同步状态无效');
        }
        _state = CinemaNASSyncState(raw['account'], raw['device']);
        _state!.merge(_state!.decode(raw['document'] as String));
        _state!.baseline = Map<String, dynamic>.from(raw['baseline'] as Map);
        _state!.initialized = raw['initialized'] != false;
        _pending = raw['pending'] == null
            ? null
            : Map<String, dynamic>.from(raw['pending']);
        _sequence = raw['sequence'] as int;
        _published = raw['published'] as String? ?? '';
        _enabled = raw['enabled'] != false;
        final revision = raw['pullRevision'];
        final snapshots = _snapshotTokens(raw['pullSnapshots']);
        if (revision is String && revision.length <= 128 && snapshots != null) {
          _pullRevision = revision;
          _pullSnapshots = snapshots;
        }
        if (raw['lastSuccess'] is String) {
          lastSuccess = DateTime.tryParse(raw['lastSuccess']);
        }
      }
      if (_closed) return;
      store.addListener(_changed);
      try {
        _subscriptions.add(
          GStorage.histories.watch().listen((_) => _changed()),
        );
        _subscriptions.add(
          GStorage.collectibles.watch().listen((_) => _changed()),
        );
      } catch (_) {
        /* Standalone cinema builds may not initialize anime boxes. */
      }
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
      _schedulePoll(WidgetsBinding.instance.lifecycleState);
      if (_state != null) unawaited(sync());
    } catch (_) {
      _paused = true;
      status = '同步状态读取失败，已保留本地资料，请检查后重试';
      _notify();
    }
  }

  void _schedulePoll(AppLifecycleState? lifecycle) {
    _timer?.cancel();
    final visible =
        lifecycle == null ||
        lifecycle == AppLifecycleState.resumed ||
        lifecycle == AppLifecycleState.inactive;
    _timer = Timer.periodic(
      Duration(seconds: Platform.isMacOS && visible ? 12 : 60),
      (_) {
        if (_retryPollAfter?.isAfter(DateTime.now()) != true) unawaited(sync());
      },
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _schedulePoll(state);
    if (state == AppLifecycleState.resumed) unawaited(refresh());
  }

  Future<void> refresh() async {
    final recent = lastSuccess;
    if (recent != null &&
        DateTime.now().difference(recent) < const Duration(seconds: 3)) {
      return;
    }
    await sync();
  }

  Future<void> bind(String namespace) async {
    await start();
    if (_closed || !RegExp(r'^[a-f0-9]{64}$').hasMatch(namespace)) return;
    if (_state != null && _state!.account != namespace) {
      _paused = true;
      status = '当前片库已绑定另一个 NAS 账号，已暂停同步以避免混入数据';
      _notify();
      return;
    }
    if (_paused && _state == null) {
      return; // Corrupt state is never overwritten.
    }
    _state ??= CinemaNASSyncState(
      namespace,
      HistorySyncDevice.generateDeviceId(),
    );
    _paused = false;
    await _save();
    unawaited(sync());
  }

  void pause() {
    _paused = true;
    status = '已退出 NAS，自动同步暂停；本地资料已保留';
    _debounce?.cancel();
    _notify();
  }

  Future<void> setEnabled(bool value) async {
    _enabled = value;
    await _save();
    if (value) {
      await sync();
    } else {
      status = '自动同步已关闭，本地资料已保留';
      _notify();
    }
  }

  void _changed() {
    if (_closed ||
        !_enabled ||
        _paused ||
        _state == null ||
        _debounce?.isActive == true) {
      return;
    }
    _debounce = Timer(const Duration(seconds: 1), () {
      _debounce = null;
      if (_running) {
        _flushQueued = true;
      } else {
        unawaited(sync());
      }
    });
  }

  Future<Map<String, dynamic>> _capture() async {
    final cinema = await store.exportLibrary();
    final result = <String, dynamic>{
      for (final m
          in (cinema['favorites'] as List).cast<Map<String, dynamic>>())
        'cf:${CinemaTitle.fromJson(m).key}': m,
      for (final m in (cinema['history'] as List).cast<Map<String, dynamic>>())
        'ch:${CinemaHistory.fromJson(m).title.key}': m,
    };
    // Initialization is all-or-nothing for the app's anime storage.
    for (final h in GStorage.histories.values) {
      result['ah:${h.key}'] = HistorySyncCodec.historyToJson(h);
    }
    for (final f in GStorage.collectibles.values) {
      result['af:${f.key}'] = _favorite(f);
    }
    return result;
  }

  Map<String, dynamic>? _favorite(CollectedBangumi? f) => f == null
      ? null
      : {
          'subject': HistorySyncCodec.bangumiItemToJson(f.bangumiItem),
          'time': f.time.millisecondsSinceEpoch,
          'type': f.type,
        };

  Future<Set<String>> _apply(
    Map<String, dynamic> expected,
    Map<String, dynamic> desired,
  ) async {
    final skipped = await store.applyAccountSync(expected, desired);
    await HistoryStorageCoordinator().run(() async {
      for (final k in {
        ...expected.keys,
        ...desired.keys,
      }.where((k) => k.startsWith('ah:'))) {
        if (_equal.equals(expected[k], desired[k])) continue;
        final key = k.substring(3), old = GStorage.histories.get(key);
        if (!_equal.equals(
          old == null ? null : HistorySyncCodec.historyToJson(old),
          expected[k],
        )) {
          skipped.add(k);
          continue;
        }
        final v = desired[k];
        if (v == null) {
          await GStorage.histories.delete(key);
        } else {
          await GStorage.histories.put(
            key,
            HistorySyncCodec.historyFromJson(Map<String, dynamic>.from(v)),
          );
        }
      }
      await GStorage.histories.flush();
    });
    for (final k in {
      ...expected.keys,
      ...desired.keys,
    }.where((k) => k.startsWith('af:'))) {
      if (_equal.equals(expected[k], desired[k])) continue;
      final id = int.parse(k.substring(3)), v = desired[k];
      final f = v == null
          ? null
          : CollectedBangumi(
              HistorySyncCodec.bangumiItemFromJson(
                Map<String, dynamic>.from(v['subject']),
              ),
              DateTime.fromMillisecondsSinceEpoch(v['time'] as int),
              v['type'] as int,
            );
      final applied = await GStorage.applyCollectibleIfUnchanged(
        id: id,
        matches: (old) => _equal.equals(_favorite(old), expected[k]),
        value: f,
      );
      if (!applied) skipped.add(k);
    }
    return skipped;
  }

  Future<void> sync() async {
    if (_closed || _running || _paused || !_enabled || _state == null) return;
    _running = true;
    status = '正在同步全部历史和收藏…';
    _notify();
    final state = _state!;
    bool active() =>
        !_closed && !_paused && _enabled && identical(state, _state);
    var succeeded = false;
    try {
      final initialized = state.initialized;
      final localChanged = state.observe(await _capture());
      _captureNeedsSave |= localChanged || !initialized;
      if (_captureNeedsSave || _pending != null) {
        await _save(); // Durable local mutations precede any network request.
        _captureNeedsSave = false;
      }
      if (!active()) return;
      if (_pending != null) await _pushPending(state);
      if (!active()) return;
      var needsPublication =
          state.entries.isNotEmpty && state.encode() != _published;
      final remote = await client.call('syncPull', {
        'namespace': state.account,
        if (_pullRevision != null) 'revision': _pullRevision,
        'snapshots': _pullSnapshots,
      });
      if (!active()) return;
      final revision = remote['revision'];
      final unchanged = remote['notModified'] == true;
      var snapshots = _pullSnapshots;
      if (unchanged) {
        if (_pullRevision == null || revision != _pullRevision) {
          throw const FormatException('NAS 同步版本无效');
        }
      } else {
        final documents = remote['documents'];
        if (documents is! List || documents.any((v) => v is! String)) {
          throw const FormatException('NAS 同步响应无效');
        }
        final tokens = remote['snapshots'];
        if (tokens == null) {
          snapshots = const [];
        } else {
          final checked = _snapshotTokens(tokens);
          if (checked == null ||
              checked
                      .where((token) => !_pullSnapshots.contains(token))
                      .length !=
                  documents.length) {
            throw const FormatException('NAS 同步文件版本不完整');
          }
          snapshots = checked;
        }
        // Validate all documents before applying any remote values, and
        // version edits that arrived while the NAS request was in flight.
        final incoming = documents
            .map((v) => state.decode(v as String))
            .toList();
        needsPublication = state.observe(await _capture()) || needsPublication;
        for (final document in incoming) {
          state.merge(document);
        }
        if (!active()) return;
        final expected = Map<String, dynamic>.from(state.baseline);
        final desired = state.visible;
        if (!_equal.equals(expected, desired)) {
          final skipped = await _apply(expected, desired);
          state.baseline = {
            for (final item in desired.entries)
              if (!skipped.contains(item.key)) item.key: item.value,
            for (final k in skipped)
              if (expected.containsKey(k)) k: expected[k],
          };
          needsPublication =
              state.observe(await _capture()) || needsPublication;
        }
        // Data pulled from another writer is already on the NAS. Do not
        // upload it back unless this client also has an unpublished edit.
        if (!needsPublication) _published = state.encode();
        await _save();
      }
      if (!active()) return;
      final document = state.encode();
      final needsPush = document != _published;
      if (needsPush) {
        _sequence++;
        _pending = {'sequence': _sequence, 'document': document};
        await _save();
        await _pushPending(state);
      }
      if (!active()) return;
      path = remote['path'] as String?;
      lastSuccess = DateTime.now();
      status = '全部历史和收藏已同步至 NAS';
      final previousRevision = _pullRevision;
      final previousSnapshots = _pullSnapshots;
      _pullRevision = revision is String && revision.length <= 128
          ? revision
          : null;
      _pullSnapshots = snapshots;
      try {
        if (!unchanged || localChanged || needsPush) await _save();
      } catch (_) {
        _pullRevision = previousRevision;
        _pullSnapshots = previousSnapshots;
        rethrow;
      }
      _retryPollAfter = null;
      succeeded = true;
    } catch (error) {
      if (active()) {
        _retryPollAfter = DateTime.now().add(const Duration(seconds: 30));
        status = error is FormatException
            ? '同步数据校验失败，本地资料已保留'
            : error is PlatformException
            ? '待同步：${error.message ?? '请检查 NAS 连接或文件权限'}'
            : '待同步：请检查 NAS 连接，本地资料已保留';
      }
    } finally {
      final again = _flushQueued;
      _flushQueued = false;
      _running = false;
      _notify();
      if (succeeded && again) _changed();
    }
  }

  Future<void> _pushPending(CinemaNASSyncState state) async {
    final pending = _pending!;
    await client.call('syncPush', {
      'namespace': state.account,
      'device': state.device,
      'sequence': pending['sequence'],
      'document': pending['document'],
    });
    _published = pending['document'] as String;
    _pending = null;
    await _save();
  }

  Future<void> _save() async {
    if (_state == null || _file == null) return;
    final encoded = jsonEncode({
      'version': 1,
      'account': _state!.account,
      'device': _state!.device,
      'document': _state!.encode(),
      'baseline': _state!.baseline,
      'initialized': _state!.initialized,
      'pending': _pending,
      'sequence': _sequence,
      'published': _published,
      'pullRevision': _pullRevision,
      'pullSnapshots': _pullSnapshots,
      'enabled': _enabled,
      'lastSuccess': lastSuccess?.toIso8601String(),
    });
    final next = _saveTail.catchError((Object _) {}).then((_) async {
      await _file!.parent.create(recursive: true);
      final temp = File('${_file!.path}.tmp');
      await temp.writeAsString(encoded, flush: true);
      await temp.rename(_file!.path);
    });
    _saveTail = next;
    await next;
  }

  void _notify() {
    if (!_closed) notifyListeners();
  }

  @override
  void dispose() {
    _closed = true;
    if (_observing) WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _debounce?.cancel();
    store.removeListener(_changed);
    for (final sub in _subscriptions) {
      unawaited(sub.cancel());
    }
    super.dispose();
  }
}
