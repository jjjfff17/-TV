import 'dart:async';

import 'package:media_kit/media_kit.dart';

/// libmpv 调优（详情页内嵌播放器与全屏播放页共用一份，避免两边参数漂移）。
///
/// 0.5.0 改动的核心：**起播要快**。
/// 0.4.x 把 `cache-secs` 开到 60、readahead 30 秒 —— 等于让播放器等"囤够一分钟"再开演，
/// 表现就是"点了播放，转圈好几秒"。网页端 hls.js 拿到第一个分片就出画，所以显得秒开。
/// 这里改成低延迟档：最多囤 6 秒、预读 4 秒，并且起播时不等缓冲填满。
/// 再配合详情页"预载不播"（点播放键直接 play），基本能做到点开即播。
void applyMpvTuning(Player player) {
  const Map<String, String> props = <String, String>{
    'cache': 'yes',
    'cache-secs': '6', // 最多向前缓存 6 秒（原 60，起播慢的主因）
    'demuxer-readahead-secs': '4', // 预读 4 秒（原 30）
    'demuxer-max-bytes': '33554432', // 32 MiB
    'demuxer-max-back-bytes': '16777216', // 16 MiB
    'cache-pause-initial': 'no', // 起播时不要在缓冲里干等
    'cache-pause-wait': '1',
    'hwdec': 'auto-safe', // 硬件解码，省电且顺
    'network-timeout': '10',
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
