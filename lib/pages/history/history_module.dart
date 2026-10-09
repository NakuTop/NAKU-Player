import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/features/cinema/cinema_library_redirect.dart';

final historyModule = createModule(
  path: '/history',
  register: (c) {
    c.route(
      '/',
      child: (context, state) => const CinemaLibraryRedirect(history: true),
    );
  },
);
