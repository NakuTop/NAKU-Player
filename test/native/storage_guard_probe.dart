import 'dart:convert';
import 'dart:io';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/services/storage/local_storage_guard.dart';

// Separate OS processes are essential: file locks are process scoped.
Future<void> main(List<String> args) async {
  final guard = LocalStorageGuard(args[1]);
  Hive.init(args[1]);
  try {
    if (args[0] != 'legacy-hold') await guard.acquire();
    if (args[0] == 'future') Hive.registerAdapter(_FutureAdapter());
    final box = args[0] == 'legacy-hold'
        ? await Hive.openBox<dynamic>('downloads')
        : await guard.openBox<dynamic>('downloads');
    if (args[0] == 'future') {
      await box.put('future', _FutureData());
      await box.flush();
    } else if (args[0].endsWith('hold')) {
      await box.put('fixture', {'name': '升级前记录', 'episode': 3});
      await box.flush();
      stdout.writeln(jsonEncode({'ready': true}));
      await stdin.first;
    } else {
      stdout.writeln(
        jsonEncode({'records': box.length, 'value': box.get('fixture')}),
      );
    }
    await Hive.close();
    await guard.release();
  } on LocalStorageException catch (error) {
    stdout.writeln(jsonEncode({'busy': error.busy, 'preserved': true}));
    exitCode = 73;
  }
}

class _FutureData {}

class _FutureAdapter extends TypeAdapter<_FutureData> {
  @override
  int get typeId => 210;
  @override
  _FutureData read(BinaryReader reader) {
    reader.readInt();
    return _FutureData();
  }

  @override
  void write(BinaryWriter writer, _FutureData value) {
    writer.writeInt(42);
  }
}
