import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'screens/player_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // media_kit 必须在 runApp 之前初始化，否则创建 Player 时崩溃（CL-NAT-03）
  MediaKit.ensureInitialized();
  runApp(const LibreTvApp());
}

class LibreTvApp extends StatelessWidget {
  const LibreTvApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LibreTV',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF2563EB),
      ),
      home: const PlayerScreen(
        // M0 只验证链路：用一条公开 HLS 测试流，M1 起替换为真实片源
        url: 'https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_4x3/bipbop_4x3_variant.m3u8',
        title: 'M0 · 播放链路测试',
      ),
    );
  }
}
