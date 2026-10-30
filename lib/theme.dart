import 'package:flutter/material.dart';

/// App 自身版本号（必须与 pubspec.yaml 的 version 保持一致，改版本时两处一起改）。
/// 不做成运行时读取：少一个依赖，也避免构建期读不到而显示空。
const String kAppVersion = '0.5.0+8';

/// 设计基线：Lanerc 风格 —— 浅色底 + 青色强调 + 圆润卡片 + 轻描边。
/// 与 0.4.x 的变化：主色由蓝(#2F6BFF)改为青(#13BFD2)，整体更干净。
class C {
  static const Color bg = Color(0xFFFFFFFF);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color text = Color(0xFF0E1116);
  static const Color sub = Color(0xFF5B6472);
  static const Color muted = Color(0xFF98A1AE);

  /// 青色强调（Lanerc 主色）
  static const Color accent = Color(0xFF13BFD2);
  static const Color accentDeep = Color(0xFF0FA9BA);
  static const Color accentSoft = Color(0xFFE6FAFD);

  static const Color chipBg = Color(0xFFF8FAFB);
  static const Color border = Color(0xFFE9EDF0);
  static const Color soft = Color(0xFFF2F5F7);

  /// 播放器 / 悬浮栏用的深色
  static const Color dark = Color(0xFF14171C);
  static const Color darkBg = Color(0xFF0A0D11);
  static const Color shadow = Color(0x14000000);
}

class Metrics {
  static const double card = 14; // 卡片 / 集数按钮
  static const double tag = 9; // 小标签
  static const double pill = 18; // 胶囊
  static const double page = 16; // 页面左右留白
}

/// 圆角 + 轻描边的容器（卡片/按钮通用）
BoxDecoration softBox({
  Color color = C.chipBg,
  Color border = C.border,
  double radius = Metrics.card,
  double borderWidth = 1,
}) {
  return BoxDecoration(
    color: color,
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(color: border, width: borderWidth),
  );
}
