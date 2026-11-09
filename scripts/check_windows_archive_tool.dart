import 'dart:io';

// Exercise the same executable lookup used by media-kit's native build hook.
Future<void> main() async {
  final result = await Process.run('tar', ['--version']);
  stdout.write(result.stdout);
  if (result.exitCode != 0 || !'${result.stdout}'.contains('liblzma')) {
    throw StateError('Dart must resolve tar with LZMA support: ${result.stderr}');
  }
}
