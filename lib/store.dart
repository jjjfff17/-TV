import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 收藏项（只存展示需要的少量字段，够列表用即可）
class FavItem {
  const FavItem(this.key, this.name, this.pic, this.sourceName, this.ts);
  final String key;
  final String name;
  final String? pic;
  final String sourceName;
  final int ts;
}

/// 收藏持久化（shared_preferences，纯本地）。
/// Key = `sourceKey|vodId`，与搜索去重口径一致。
class FavStore {
  static const String _k = 'favs_v2';
  static final Map<String, FavItem> _map = <String, FavItem>{};
  static bool _loaded = false;

  static String keyOf(String sourceKey, String vodId) => '$sourceKey|$vodId';

  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      final String? s = p.getString(_k);
      if (s == null || s.isEmpty) return;
      final Object? raw = jsonDecode(s);
      if (raw is! List) return;
      for (final Object? e in raw) {
        if (e is Map) {
          final Map<String, dynamic> m = Map<String, dynamic>.from(e);
          final String k = (m['k'] ?? '').toString();
          if (k.isEmpty) continue;
          _map[k] = FavItem(
            k,
            (m['n'] ?? '').toString(),
            m['p']?.toString(),
            (m['s'] ?? '').toString(),
            (m['t'] is int) ? m['t'] as int : 0,
          );
        }
      }
    } catch (_) {
      // 本地数据坏了就当没有，不影响使用
    }
  }

  static bool has(String sourceKey, String vodId) =>
      _map.containsKey(keyOf(sourceKey, vodId));

  static int get count => _map.length;

  /// 全部收藏（按收藏时间倒序），供「我的」页展示
  static List<FavItem> get items {
    final List<FavItem> list = _map.values.toList();
    list.sort((FavItem a, FavItem b) => b.ts.compareTo(a.ts));
    return list;
  }

  /// 返回切换后的状态：true = 已收藏
  static Future<bool> toggle({
    required String sourceKey,
    required String vodId,
    required String name,
    String? pic,
    String sourceName = '',
  }) async {
    final String k = keyOf(sourceKey, vodId);
    final bool now;
    if (_map.remove(k) != null) {
      now = false;
    } else {
      _map[k] = FavItem(
        k,
        name,
        pic,
        sourceName,
        DateTime.now().millisecondsSinceEpoch,
      );
      now = true;
    }
    await _persist();
    return now;
  }

  static Future<void> _persist() async {
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      final List<Map<String, dynamic>> list = _map.values
          .map((FavItem f) => <String, dynamic>{
                'k': f.key,
                'n': f.name,
                'p': f.pic,
                's': f.sourceName,
                't': f.ts,
              })
          .toList();
      await p.setString(_k, jsonEncode(list));
    } catch (_) {
      // 写入失败不阻断交互
    }
  }
}
