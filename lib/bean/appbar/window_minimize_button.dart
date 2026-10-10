import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// 最小化到任务栏，不退出应用或释放播放会话。
class WindowMinimizeButton extends StatelessWidget {
  const WindowMinimizeButton({super.key, this.color});

  final Color? color;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: '最小化',
    onPressed: () => windowManager.minimize(),
    icon: Icon(Icons.horizontal_rule, color: color),
  );
}
