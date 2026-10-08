import 'package:flutter/material.dart';
import 'package:kazumi/pages/menu/menu.dart';
import 'package:flutter_modular/flutter_modular.dart';

class IndexPage extends StatefulWidget {
  const IndexPage({super.key, required this.location});

  final String location;

  @override
  State<IndexPage> createState() => _IndexPageState();
}

class _IndexPageState extends State<IndexPage> with WidgetsBindingObserver {
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SafeArea(
          bottom: false,
          child: Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => context.navigate('/cinema'),
              icon: const Icon(Icons.waves_rounded, size: 17),
              label: const Text('返回NAKU播放器'),
            ),
          ),
        ),
        Expanded(child: ScaffoldMenu(location: widget.location)),
      ],
    );
  }
}
