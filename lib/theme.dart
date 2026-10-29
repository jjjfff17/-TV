import 'package:flutter/material.dart';

/// App 自身版本号（必须与 pubspec.yaml 的 version 保持一致，改版本时两处一起改）。
/// 不做成运行时读取：少一个依赖，也避免构建期读不到而显示空。
/// 作用：装机后能在 App 里直接看到版本，不用再靠猜"装的是哪一版"。
const String kAppVersion = '0.4.3+7';

/// 设计基线（取自验收通过的界面 demo）：浅色详情页 + 圆润卡片 + 蓝色强调
class C {
  static const Color bg = Color(0xFFFFFFFF);
  static const Color text = Color(0xFF111111);
  static const Color sub = Color(0xFF666666);
  static const Color muted = Color(0xFF9AA0AA);
  static const Color accent = Color(0xFF2F6BFF);
  static const Color accentSoft = Color(0xFFF3F7FF);
  static const Color chipBg = Color(0xFFFBFBFD);
  static const Color border = Color(0xFFE8EAEE);
  static const Color soft = Color(0xFFF3F4F6);
  static const Color dark = Color(0xFF14161C);
  static const Color darkBg = Color(0xFF0B0E14);
}

class Metrics {
  static const double card = 14; // 卡片/集数按钮
  static const double tag = 9; // 小标签
  static const double pill = 18; // 胶囊
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
