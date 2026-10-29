import 'dart:async';

import 'package:media_kit/media_kit.dart';

/// libmpv 调优（详情页内嵌播放器与全屏播放页共用一份，避免两边参数漂移）。
///
/// 为什么需要：libmpv 默认缓冲很小，起播和每次 seek 都要重新连源站 + 重新 probe，
/// 而 Web 端走 hls.js + MSE（buffered 120 秒），所以同一个片源 App 明显更慢。
///
/// 为什么用 dynamic：media_kit 各版本对 NativePlayer 的导出不完全一致，
/// 写死类型会在 CI 上编译失败；这里即便取不到原生对象，也只是少了优化，不影响播放。
void applyMpvTuning(Player player) {
  const Map<String, String> props = <String, String>{
    'cache': 'yes',
    'cache-secs': '60',
    'demuxer-max-bytes': '67108864', // 64 MiB
    'demuxer-max-back-bytes': '33554432', // 32 MiB
    'demuxer-readahead-secs': '30',
    'hwdec': 'auto-safe',
    'network-timeout': '15',
    'force-seekable': 'yes',
  };
  unawaited(() async {
    try {
      final dynamic np = player.platform;
      for (final MapEntry<String, String> e in props.entries) {
        try {
          await np.setProperty(e.key, e.value);
        } catch (_) {
          // 个别属性在当前 libmpv 版本不存在，跳过
        }
      }
    } catch (_) {
      // 拿不到原生播放器，放弃调优
    }
  }());
}

/// 把毫秒格式化成 `mm:ss` / `h:mm:ss`（播放器时间显示用）
String fmtDuration(Duration d) {
  final int total = d.inSeconds < 0 ? 0 : d.inSeconds;
  final int h = total ~/ 3600;
  final int m = (total % 3600) ~/ 60;
  final int s = total % 60;
  final String mm = m.toString().padLeft(h > 0 ? 2 : 1, '0');
  final String ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}
