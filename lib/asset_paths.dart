import 'package:flutter/services.dart';

/// 资源键在「带 lib/ 前缀」和「不带」两种形式间因打包方式而异，
/// 启动时探一次，之后所有图标按探测到的前缀加载（探不到就用默认值，不阻断启动）。
class AssetPaths {
  static String icons = 'lib/assets/lanerc/icons/';

  static Future<void> probe() async {
    const List<String> candidates = <String>[
      'lib/assets/lanerc/icons/',
      'assets/lanerc/icons/',
    ];
    for (final String prefix in candidates) {
      try {
        await rootBundle.load('${prefix}play.svg');
        icons = prefix;
        return;
      } catch (_) {
        // 试下一个前缀
      }
    }
  }
}
