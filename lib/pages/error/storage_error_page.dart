import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:kazumi/services/storage/local_storage_guard.dart';

import 'package:kazumi/bean/widget/error_widget.dart';
import 'package:kazumi/bean/widget/loading_indicator.dart';
import 'package:kazumi/bean/widget/state_presentation.dart';

class StorageErrorPage extends StatelessWidget {
  const StorageErrorPage({super.key, this.error});
  final Object? error;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('内部错误')),
      body: FutureBuilder<Directory>(
        future: getApplicationSupportDirectory(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done) {
            final path = snapshot.data?.path ?? '未知路径';
            return GeneralErrorWidget(
              title: '无法初始化本地存储',
              icon: Icons.storage_rounded,
              errMsg:
                  '${error is LocalStorageException ? error.toString() : '读取本地存储失败，原始数据库和视频已保留。'}\n\n当前存储位置：\n$path\n\n请先退出其他正在运行的 NAKU 或旧版本，再重新打开。若仍无法读取，请保留此目录及 storage-backups 中的备份以便恢复。',
              actions: [
                StateActionButton(
                  onPressed: () {
                    exit(0);
                  },
                  text: '退出程序',
                  icon: Icons.close_rounded,
                ),
              ],
            );
          } else {
            return const Center(child: LoadingIndicator());
          }
        },
      ),
    );
  }
}
