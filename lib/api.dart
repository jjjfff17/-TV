import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// 后端调用异常（消息直接可展示给用户）
class ApiException implements Exception {
  ApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// LibreTV 后端客户端。
///
/// 关键事实（已实测）：
/// - 网关要求每个请求带 `?sharecode=xxx`，否则返回 403 HTML「链接不完整」；
/// - `/api/*` 需要登录态 cookie（ltv_session），由 POST /api/auth 种下；
/// - 网关还会种 __wb_rsc，两个 cookie 必须一起回传，所以这里做手工 cookie 罐。
class Api {
  Api._();

  static final Api i = Api._();

  static const String defaultBase = 'https://libretv-tv-65752.app.workbuddy.host';
  static const String defaultShareCode = 'I7GLYKL3VS';
  static const String defaultPassword = 'LibreTV@2026';

  late final Dio _dio;
  late SharedPreferences _prefs;

  String base = defaultBase;
  String shareCode = defaultShareCode;

  String _cookie = '';
  List<SourceConfig> sources = <SourceConfig>[];
  bool passwordRequired = true;
  bool verified = false;
  String version = '';

  bool get hasSources => sources.isNotEmpty;

  /// 启动：读本地配置 + cookie，再拉一次站点状态
  Future<void> boot() async {
    _prefs = await SharedPreferences.getInstance();
    base = _prefs.getString('base') ?? defaultBase;
    shareCode = _prefs.getString('sharecode') ?? defaultShareCode;
    _cookie = _prefs.getString('cookie') ?? '';

    _dio = Dio(
      BaseOptions(
        baseUrl: base,
        connectTimeout: const Duration(seconds: 12),
        sendTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 30),
        // 4xx 也要拿到响应体（错误信息在里面），只有 5xx 才抛
        validateStatus: (int? s) => s != null && s < 500,
        responseType: ResponseType.plain,
      ),
    );
    // 每个请求带上 cookie 罐（ltv_session 登录态 + __wb_rsc 网关态）
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (RequestOptions o, RequestInterceptorHandler h) {
          if (_cookie.isNotEmpty) {
            o.headers['Cookie'] = _cookie;
          }
          h.next(o);
        },
      ),
    );
    await refreshStatus();
  }

  Future<void> saveEndpoint({String? newBase, String? newShareCode}) async {
    if (newBase != null && newBase.trim().isNotEmpty) {
      base = newBase.trim().replaceAll(RegExp(r'/+$'), '');
      _dio.options.baseUrl = base;
    }
    if (newShareCode != null && newShareCode.trim().isNotEmpty) {
      shareCode = newShareCode.trim();
    }
    await _prefs.setString('base', base);
    await _prefs.setString('sharecode', shareCode);
  }

  // ---------- 站点状态 ----------

  Future<void> refreshStatus() async {
    final Map<String, dynamic> d = await _get('/api/status');
    passwordRequired = d['passwordRequired'] == true;
    verified = d['verified'] == true;
    version = (d['version'] ?? '').toString();

    final List<SourceConfig> list = <SourceConfig>[];
    final Object? raw = d['defaultSources'];
    if (raw is List) {
      for (final Object? e in raw) {
        if (e is Map) {
          final SourceConfig s = SourceConfig.fromJson(
            Map<String, dynamic>.from(e),
          );
          if (s.url.startsWith('http')) list.add(s);
        }
      }
    }
    sources = list;
  }

  // ---------- 登录 ----------

  Future<void> login(String password) async {
    final Response<String> r = await _request(
      () => _dio.post<String>(
        '/api/auth',
        queryParameters: _query(),
        data: <String, dynamic>{'password': password},
        options: Options(contentType: Headers.jsonContentType),
      ),
    );
    _mergeCookies(r.headers.map['set-cookie']);
    final Map<String, dynamic> d = _asMap(r);
    if (r.statusCode == 200 && d['success'] == true) {
      verified = true;
      return;
    }
    throw ApiException((d['error'] ?? '登录失败（HTTP ${r.statusCode}）').toString());
  }

  Future<void> logout() async {
    try {
      await _dio.delete<String>('/api/auth', queryParameters: _query());
    } catch (_) {
      // 退出失败也要清本地登录态
    }
    _cookie = '';
    verified = false;
    await _prefs.remove('cookie');
  }

  // ---------- 业务接口 ----------

  Future<List<HotItem>> hotList(String id) async {
    final Map<String, dynamic> d = await _get(
      '/api/hot-list',
      query: <String, dynamic>{'id': id},
    );
    final Object? raw = d['items'];
    if (raw is! List) return <HotItem>[];
    return raw
        .whereType<Map>()
        .map((Map e) => HotItem.fromJson(Map<String, dynamic>.from(e)))
        .where((HotItem e) => e.title.isNotEmpty)
        .toList();
  }

  Future<List<SearchItem>> search(String wd) async {
    if (sources.isEmpty) {
      await refreshStatus();
    }
    if (sources.isEmpty) {
      throw ApiException('站点没有配置采集源（DEFAULT_SOURCES 为空）');
    }
    final Response<String> r = await _request(
      () => _dio.post<String>(
        '/api/search',
        queryParameters: _query(),
        data: <String, dynamic>{
          'wd': wd,
          'sources': sources.map((SourceConfig s) => s.toJson()).toList(),
          'filterAdult': true,
        },
        options: Options(
          contentType: Headers.jsonContentType,
          // 聚合搜索要并发打十几个源，给足时间
          receiveTimeout: const Duration(seconds: 90),
        ),
      ),
    );
    _mergeCookies(r.headers.map['set-cookie']);
    final Map<String, dynamic> d = _asMap(r);
    if (r.statusCode != 200) {
      throw ApiException((d['error'] ?? '搜索失败（HTTP ${r.statusCode}）').toString());
    }
    final Object? list = d['list'];
    if (list is! List) return <SearchItem>[];
    return list
        .whereType<Map>()
        .map((Map e) => SearchItem.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<VideoDetail> detail(SearchItem item) async {
    final Map<String, dynamic> src = <String, dynamic>{
      'key': item.sourceKey,
      'name': item.sourceName,
      'url': item.sourceUrl ?? '',
    };
    final Map<String, dynamic> d = await _get(
      '/api/detail',
      query: <String, dynamic>{
        'id': item.vodId,
        'source': jsonEncode(src),
      },
    );
    final VideoDetail detail = VideoDetail.fromJson(d);
    if (detail.episodes.isEmpty) {
      throw ApiException('该源没有解析到播放地址，换一个源试试');
    }
    return detail;
  }

  // ---------- 内部 ----------

  Map<String, dynamic> _query([Map<String, dynamic>? extra]) =>
      <String, dynamic>{...?extra, 'sharecode': shareCode};

  Future<Map<String, dynamic>> _get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    final Response<String> r = await _request(
      () => _dio.get<String>(path, queryParameters: _query(query)),
    );
    _mergeCookies(r.headers.map['set-cookie']);
    final Map<String, dynamic> d = _asMap(r);
    if (r.statusCode != 200) {
      throw ApiException((d['error'] ?? '请求失败（HTTP ${r.statusCode}）').toString());
    }
    return d;
  }

  /// 统一异常转换：网络层错误 → 中文提示
  Future<Response<String>> _request(
    Future<Response<String>> Function() run,
  ) async {
    try {
      return await run();
    } on DioException catch (e) {
      throw ApiException(_dioMessage(e));
    }
  }

  /// 不写成 switch：dio 的 DioExceptionType 会随版本增删成员，穷尽匹配容易编译失败
  String _dioMessage(DioException e) {
    final DioExceptionType t = e.type;
    if (t == DioExceptionType.connectionTimeout ||
        t == DioExceptionType.sendTimeout ||
        t == DioExceptionType.receiveTimeout) {
      return '连接超时，请检查网络后重试';
    }
    if (t == DioExceptionType.connectionError) {
      return '无法连接服务器，请检查网络或站点地址';
    }
    if (t == DioExceptionType.badResponse) {
      return '服务器返回错误（HTTP ${e.response?.statusCode}）';
    }
    if (t == DioExceptionType.cancel) {
      return '请求已取消';
    }
    return '网络异常：${e.message ?? '未知错误'}';
  }

  /// 响应体统一转 Map；网关的 403 HTML（链接不完整）在这里被翻译成人话
  Map<String, dynamic> _asMap(Response<String> r) {
    final String? body = r.data;
    if (body == null || body.trim().isEmpty) {
      throw ApiException(_statusMessage(r.statusCode, ''));
    }
    final String head = body.trimLeft();
    if (head.startsWith('{')) {
      try {
        final Object? decoded = jsonDecode(body);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {
        // 落到下面的兜底
      }
    }
    if (r.statusCode == 403) {
      throw ApiException('被网关拦截（403）：分享码可能已失效，请在设置里更新分享码');
    }
    if (head.startsWith('<')) {
      throw ApiException('服务器返回了网页而不是数据（HTTP ${r.statusCode}），'
          '通常是分享码失效或地址填错');
    }
    throw ApiException(_statusMessage(r.statusCode, body));
  }

  String _statusMessage(int? code, String body) {
    if (code == 401) return '未登录或登录已过期，请重新登录';
    if (code == 403) return '被网关拦截（403）：分享码可能已失效';
    if (code == 429) return '尝试次数过多，请稍后再试';
    return '服务器响应异常（HTTP $code）';
  }

  /// cookie 罐：Set-Cookie 逐条解析，name=value 合并后整体回传
  void _mergeCookies(List<String>? setCookies) {
    if (setCookies == null || setCookies.isEmpty) return;
    final Map<String, String> jar = <String, String>{};
    for (final String pair in _cookie.split(';')) {
      final int i = pair.indexOf('=');
      if (i > 0) {
        jar[pair.substring(0, i).trim()] = pair.substring(i + 1).trim();
      }
    }
    bool changed = false;
    for (final String line in setCookies) {
      final String first = line.split(';').first;
      final int i = first.indexOf('=');
      if (i <= 0) continue;
      final String k = first.substring(0, i).trim();
      final String v = first.substring(i + 1).trim();
      if (v.isEmpty) {
        if (jar.remove(k) != null) changed = true;
      } else if (jar[k] != v) {
        jar[k] = v;
        changed = true;
      }
    }
    if (!changed) return;
    _cookie = jar.entries
        .map((MapEntry<String, String> e) => '${e.key}=${e.value}')
        .join('; ');
    unawaited(_prefs.setString('cookie', _cookie));
  }

  /// 播放地址：默认直连（实测多数源可直接播）；
  /// 直连失败时调用方可以退回这里给出的代理地址。
  String proxyUrl(String raw) {
    final String encoded = Uri.encodeComponent(raw);
    return '$base/api/proxy?url=$encoded&sharecode=$shareCode';
  }
}
