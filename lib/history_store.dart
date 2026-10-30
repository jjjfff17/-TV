import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 观看记录项：只存列表展示 + 续播需要的字段。
class HistoryItem {
  const HistoryItem({
    required this.key,
    required this.sourceKey,
    required this.vodId,
    required this.name,
    required this.pic,
    required this.sourceName,
    required this.index,
    required this.posMs,
    required this.durMs,
    required this.ts,
  });

  final String key;
  final String sourceKey;
  final String vodId;
  final String name;
  final String? pic;
  final String sourceName;
  final int index; // 第几集（0 基）
  final int posMs; // 已看毫秒
  final int durMs; // 总时长毫秒（0 = 未知）
  final int ts; // 最近观看时间戳

  /// 进度比例 0..1（未知时长为 0）
  double get ratio {
    if (durMs <= 0) return 0;
    final double r = posMs / durMs;
    return r.clamp(0.0, 1.0).toDouble();
  }
}

/// 观看记录持久化（shared_preferences，纯本地，不需要登录）。
/// Key = `sourceKey|vodId`，同一部片只保留最近一条（更新集数与进度）。
class HistoryStore {
  static const String _k = 'history_v1';
  static final List<HistoryItem> _list = <HistoryItem>[];
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
          _list.add(HistoryItem(
            key: k,
            sourceKey: (m['sk'] ?? '').toString(),
            vodId: (m['vid'] ?? '').toString(),
            name: (m['n'] ?? '').toString(),
            pic: m['p']?.toString(),
            sourceName: (m['s'] ?? '').toString(),
            index: (m['i'] is int) ? m['i'] as int : 0,
            posMs: (m['pos'] is int) ? m['pos'] as int : 0,
            durMs: (m['dur'] is int) ? m['dur'] as int : 0,
            ts: (m['t'] is int) ? m['t'] as int : 0,
          ));
        }
      }
      _list.sort((HistoryItem a, HistoryItem b) => b.ts.compareTo(a.ts));
    } catch (_) {
      // 本地数据坏了就当没有，不影响使用
    }
  }

  /// 记录 / 更新一条观看进度（按 sourceKey|vodId 去重，保留最新）。
  static Future<void> record({
    required String sourceKey,
    required String vodId,
    required String name,
    String? pic,
    String sourceName = '',
    int index = 0,
    int posMs = 0,
    int durMs = 0,
  }) async {
    await load();
    final String k = keyOf(sourceKey, vodId);
    _list.removeWhere((HistoryItem e) => e.key == k);
    _list.add(HistoryItem(
      key: k,
      sourceKey: sourceKey,
      vodId: vodId,
      name: name,
      pic: pic,
      sourceName: sourceName,
      index: index,
      posMs: posMs,
      durMs: durMs,
      ts: DateTime.now().millisecondsSinceEpoch,
    ));
    _list.sort((HistoryItem a, HistoryItem b) => b.ts.compareTo(a.ts));
    await _persist();
  }

  static List<HistoryItem> get items => List<HistoryItem>.from(_list);

  static int get count => _list.length;

  static Future<void> remove(String sourceKey, String vodId) async {
    _list.removeWhere((HistoryItem e) => e.key == keyOf(sourceKey, vodId));
    await _persist();
  }

  static Future<void> clearAll() async {
    _list.clear();
    await _persist();
  }

  static Future<void> _persist() async {
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      final List<Map<String, dynamic>> list = _list
          .map((HistoryItem h) => <String, dynamic>{
                'k': h.key,
                'sk': h.sourceKey,
                'vid': h.vodId,
                'n': h.name,
                'p': h.pic,
                's': h.sourceName,
                'i': h.index,
                'pos': h.posMs,
                'dur': h.durMs,
                't': h.ts,
              })
          .toList();
      await p.setString(_k, jsonEncode(list));
    } catch (_) {
      // 写入失败不阻断交互
    }
  }
}
