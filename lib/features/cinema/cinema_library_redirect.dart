import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'cinema_settings_host_binding.dart';

/// Keep saved legacy links useful without mounting a second library UI.
class CinemaLibraryRedirect extends StatefulWidget {
  const CinemaLibraryRedirect({super.key, this.history = false});
  final bool history;
  @override
  State<CinemaLibraryRedirect> createState() => _CinemaLibraryRedirectState();
}

class _CinemaLibraryRedirectState extends State<CinemaLibraryRedirect> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!CinemaSettingsHostBinding.instance.openLibrary(
        history: widget.history,
      )) {
        context.navigate(
          '/cinema?section=${widget.history ? 'history' : 'favorites'}',
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
