import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/features/cinema/cinema_library_redirect.dart';

final collectModule = createModule(
  path: '/collect',
  register: (c) {
    c.route(
      '/',
      transition: TransitionType.none,
      child: (context, state) => const CinemaLibraryRedirect(),
    );
  },
);
