/// 与 LibreTV 后端 /api/* 对应的数据模型。
/// 字段名严格对齐 src/lib/types.ts（SourceConfig / SearchResultItem / VideoDetail / DoubanItem）。

class SourceConfig {
  const SourceConfig({
    required this.key,
    required this.name,
    required this.url,
    this.detail,
  });

  final String key;
  final String name;
  final String url;
  final String? detail;

  factory SourceConfig.fromJson(Map<String, dynamic> j) => SourceConfig(
    key: (j['key'] ?? '').toString(),
    name: (j['name'] ?? '').toString(),
    url: (j['url'] ?? '').toString(),
    detail: (j['detail'] is String && (j['detail'] as String).isNotEmpty)
        ? j['detail'] as String
        : null,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'key': key,
    'name': name,
    'url': url,
    if (detail != null) 'detail': detail,
  };
}

class SearchItem {
  const SearchItem({
    required this.sourceKey,
    required this.sourceName,
    required this.vodId,
    required this.name,
    this.pic,
    this.typeName,
    this.year,
    this.area,
    this.remarks,
    this.sourceUrl,
  });

  final String sourceKey;
  final String sourceName;
  final String vodId;
  final String name;
  final String? pic;
  final String? typeName;
  final String? year;
  final String? area;
  final String? remarks;
  final String? sourceUrl;

  factory SearchItem.fromJson(Map<String, dynamic> j) => SearchItem(
    sourceKey: (j['sourceKey'] ?? '').toString(),
    sourceName: (j['sourceName'] ?? '').toString(),
    vodId: (j['vodId'] ?? '').toString(),
    name: (j['name'] ?? '').toString(),
    pic: _str(j['pic']),
    typeName: _str(j['typeName']),
    year: _str(j['year']),
    area: _str(j['area']),
    remarks: _str(j['remarks']),
    sourceUrl: _str(j['sourceUrl']),
  );

  /// 副标题：类型 / 年份 / 备注，过滤空值
  String get subtitle => <String?>[typeName, year, remarks]
      .where((String? s) => s != null && s.isNotEmpty)
      .join(' · ');
}

class HotItem {
  const HotItem({
    required this.id,
    required this.title,
    this.cover,
    this.rating,
  });

  final String id;
  final String title;
  final String? cover;
  final String? rating;

  factory HotItem.fromJson(Map<String, dynamic> j) => HotItem(
    id: (j['id'] ?? '').toString(),
    title: (j['title'] ?? '').toString(),
    cover: _str(j['cover']),
    rating: _str(j['rating']),
  );
}

class VideoInfo {
  const VideoInfo({
    required this.title,
    this.cover,
    this.desc,
    this.typeName,
    this.year,
    this.area,
    this.remarks,
    this.sourceName,
  });

  final String title;
  final String? cover;
  final String? desc;
  final String? typeName;
  final String? year;
  final String? area;
  final String? remarks;
  final String? sourceName;

  factory VideoInfo.fromJson(Map<String, dynamic> j) => VideoInfo(
    title: (j['title'] ?? '').toString(),
    cover: _str(j['cover']),
    desc: _str(j['desc']),
    typeName: _str(j['typeName']),
    year: _str(j['year']),
    area: _str(j['area']),
    remarks: _str(j['remarks']),
    sourceName: _str(j['sourceName']),
  );

  String get metaLine => <String?>[typeName, year, area]
      .where((String? s) => s != null && s.isNotEmpty)
      .join(' · ');
}

class VideoDetail {
  const VideoDetail({required this.episodes, required this.info});

  final List<String> episodes;
  final VideoInfo info;

  factory VideoDetail.fromJson(Map<String, dynamic> j) {
    final List<dynamic> rawEps = (j['episodes'] as List<dynamic>?) ?? <dynamic>[];
    final Map<String, dynamic> info = (j['videoInfo'] is Map)
        ? Map<String, dynamic>.from(j['videoInfo'] as Map)
        : <String, dynamic>{};
    return VideoDetail(
      episodes: rawEps.map((dynamic e) => e.toString()).toList(),
      info: VideoInfo.fromJson(info),
    );
  }

  /// 第 n 集的展示名：优先从 URL 里抓「第12集 / EP12 / 12」，抓不到就用序号
  String episodeLabel(int index) {
    if (index < 0 || index >= episodes.length) return '第${index + 1}集';
    final String url = episodes[index];
    try {
      final String decoded = Uri.decodeFull(url);
      final RegExpMatch? m = RegExp(
        r'第\s*(\d+)\s*[集话話]|[Ee][Pp]\.?\s*(\d+)|/(\d+)\.(?:m3u8|mp4)',
      ).firstMatch(decoded);
      if (m != null) {
        final String? g = m.group(1) ?? m.group(2) ?? m.group(3);
        if (g != null) return '第$g集';
      }
    } catch (_) {
      // URL 解不出就退回序号，不影响播放
    }
    return '第${index + 1}集';
  }
}

String? _str(Object? v) {
  if (v == null) return null;
  final String s = v.toString().trim();
  return s.isEmpty ? null : s;
}
