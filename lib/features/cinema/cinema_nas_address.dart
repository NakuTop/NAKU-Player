/// Normalize user-facing UGlink shares without following arbitrary redirects.
String normalizeNASConnectionInput(String raw) {
  var value = raw.trim();
  const message = '请填写 UGlink 别名、https://ug.link/别名 或局域网地址。';
  if (value.isEmpty) throw const FormatException(message);
  if (RegExp(r'^[a-zA-Z0-9-]{1,63}$').hasMatch(value)) return value;
  if (!value.contains('://')) {
    if (value.startsWith('ug.link/') ||
        RegExp(r'^[a-zA-Z0-9.-]+\.ug\.link/?$').hasMatch(value)) {
      value = 'https://$value';
    } else {
      final uri = Uri.tryParse('http://$value');
      final parts = uri?.host.split('.') ?? <String>[];
      final numbers = parts.map(int.tryParse).toList();
      if (parts.length != 4 ||
          numbers.any((n) => n == null || n < 0 || n > 255) ||
          !(numbers[0] == 10 ||
              numbers[0] == 192 && numbers[1] == 168 ||
              numbers[0] == 172 && numbers[1]! >= 16 && numbers[1]! <= 31)) {
        throw const FormatException(message);
      }
      value = 'http://$value';
    }
  }
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      uri.port < 1 ||
      uri.port > 65535) {
    throw const FormatException(message);
  }
  if (uri.host == 'ug.link') {
    if (uri.hasPort ||
        uri.pathSegments.where((s) => s.isNotEmpty).length != 1) {
      throw const FormatException(message);
    }
    final alias = uri.pathSegments.firstWhere((s) => s.isNotEmpty);
    if (!RegExp(r'^[a-zA-Z0-9-]{1,63}$').hasMatch(alias)) {
      throw const FormatException(message);
    }
    return alias;
  }
  if (!['', '/'].contains(uri.path)) throw const FormatException(message);
  return uri.replace(path: '').toString();
}
