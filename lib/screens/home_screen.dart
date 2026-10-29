import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';
import 'detail_screen.dart';

/// 首页：榜单浏览 + 搜索。点海报 → 按标题搜索 → 打开详情。
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.onLogout});

  final VoidCallback onLogout;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const List<List<String>> _tabs = <List<String>>[
    <String>['douban_tv_chinese', '国产剧'],
    <String>['douban_movie_weekly', '电影'],
    <String>['douban_tv_global', '美剧'],
    <String>['douban_show_chinese', '综艺'],
    <String>['baidu_teleplay', '热播'],
  ];

  final TextEditingController _q = TextEditingController();

  String _tab = 'douban_tv_chinese';
  List<HotItem> _hots = <HotItem>[];
  bool _loadingHot = true;
  String? _hotError;

  List<SearchItem>? _results;
  bool _searching = false;
  String? _searchError;
  int _srcDone = 0;
  int _srcTotal = 0;
  final Set<String> _seen = <String>{};

  @override
  void initState() {
    super.initState();
    _loadHot(_tab);
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _loadHot(String id) async {
    setState(() {
      _loadingHot = true;
      _hotError = null;
      _tab = id;
    });
    try {
      final List<HotItem> list = await Api.i.hotList(id);
      if (!mounted) return;
      setState(() {
        _hots = list;
        _loadingHot = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _hotError = e is ApiException ? e.message : '$e';
        _loadingHot = false;
      });
    }
  }

  void _beginSearch() {
    _seen.clear();
    setState(() {
      _searching = true;
      _searchError = null;
      _results = <SearchItem>[];
      _srcDone = 0;
      _srcTotal = Api.i.sources.isEmpty ? 16 : Api.i.sources.length;
    });
  }

  /// 并入一批流式结果：按「源+vodId」去重，done 事件里的全量列表也不会重复
  void _appendEvent(SearchEvent e) {
    final List<SearchItem> buf = _results ?? <SearchItem>[];
    for (final SearchItem it in e.items) {
      if (_seen.add('${it.sourceKey}|${it.vodId}')) buf.add(it);
    }
    _results = buf;
    if (e.done) {
      _searching = false;
      _srcDone = _srcTotal;
    } else {
      _srcDone = (_srcDone + 1).clamp(0, _srcTotal);
    }
  }

  Future<void> _runSearch(String wd) async {
    final String key = wd.trim();
    if (key.isEmpty) return;
    FocusScope.of(context).unfocus();
    _beginSearch();
    try {
      // 流式：每完成一个源就刷新一次，首个结果约 2 秒出现（不再等满 16 个源）
      await for (final SearchEvent e in Api.i.searchStream(key)) {
        if (!mounted) return;
        setState(() => _appendEvent(e));
      }
      if (!mounted) return;
      setState(() => _searching = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searchError = e is ApiException ? e.message : '$e';
        _searching = false;
      });
    }
  }

  /// 榜单条目没有片源 ID，用它做关键词搜一次再进详情。
  /// 拿到第一批结果就进详情，不等 16 个源跑完。
  Future<void> _openByTitle(String title) async {
    _q.text = title;
    _beginSearch();
    try {
      SearchItem? first;
      await for (final SearchEvent e in Api.i.searchStream(title)) {
        if (!mounted) return;
        setState(() => _appendEvent(e));
        if (e.items.isNotEmpty) {
          first = e.items.first;
          break;
        }
      }
      if (!mounted) return;
      if (first == null) {
        setState(() {
          _searching = false;
          _searchError = '没有找到「$title」的片源，试试搜索别的关键词';
        });
        return;
      }
      setState(() {
        _searching = false;
        _results = null;
      });
      _openDetail(first);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _searchError = e is ApiException ? e.message : '$e';
      });
    }
  }

  void _openDetail(SearchItem item) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext _) => DetailScreen(item: item),
      ),
    );
  }

  Future<void> _confirmLogout() async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('退出登录', style: TextStyle(fontSize: 16)),
        content: const Text('退出后需要重新输入站点密码才能看片。', style: TextStyle(fontSize: 13)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('退出', style: TextStyle(color: Color(0xFFE5484D))),
          ),
        ],
      ),
    );
    if (ok == true) {
      await Api.i.logout();
      if (!mounted) return;
      widget.onLogout();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: C.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _header(),
            _searchBar(),
            if (_searching && (_results == null || _results!.isEmpty))
              Expanded(child: _searchingView())
            else if (_results == null) ...<Widget>[
              _tabBar(),
              Expanded(child: _hotGrid()),
            ] else
              Expanded(child: _resultList()),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 4),
      child: Row(
        children: <Widget>[
          const Text(
            'LibreTV',
            style: TextStyle(
              color: C.text,
              fontSize: 22,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(width: 8),
          if (Api.i.version.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: C.soft,
                borderRadius: BorderRadius.circular(Metrics.tag),
              ),
              child: Text(
                'v${Api.i.version}',
                style: const TextStyle(color: C.muted, fontSize: 10),
              ),
            ),
          const Spacer(),
          IconButton(
            onPressed: _confirmLogout,
            icon: const Icon(Icons.power_settings_new_rounded, size: 20),
            color: C.muted,
            tooltip: '退出登录',
          ),
        ],
      ),
    );
  }

  Widget _searchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      child: Container(
        height: 40,
        padding: const EdgeInsets.only(left: 14, right: 6),
        decoration: BoxDecoration(
          color: C.soft,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          children: <Widget>[
            const Icon(Icons.search_rounded, size: 18, color: C.muted),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _q,
                textInputAction: TextInputAction.search,
                onSubmitted: _runSearch,
                style: const TextStyle(fontSize: 13.5, color: C.text),
                decoration: const InputDecoration(
                  hintText: '搜索影片、剧集、动漫',
                  hintStyle: TextStyle(color: C.muted, fontSize: 13),
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(vertical: 10),
                ),
              ),
            ),
            if (_results != null)
              IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () => setState(() {
                  _results = null;
                  _q.clear();
                }),
                icon: const Icon(Icons.close_rounded, size: 18, color: C.muted),
              )
            else
              TextButton(
                onPressed: () => _runSearch(_q.text),
                child: const Text(
                  '搜索',
                  style: TextStyle(color: C.accent, fontSize: 13),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _tabBar() {
    return SizedBox(
      height: 34,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        scrollDirection: Axis.horizontal,
        itemCount: _tabs.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (BuildContext _, int i) {
          final bool on = _tabs[i][0] == _tab;
          return GestureDetector(
            onTap: () => _loadHot(_tabs[i][0]),
            child: Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: on ? C.accentSoft : C.chipBg,
                borderRadius: BorderRadius.circular(Metrics.pill),
                border: Border.all(
                  color: on ? C.accent : C.border,
                  width: on ? 1.2 : 1,
                ),
              ),
              child: Text(
                _tabs[i][1],
                style: TextStyle(
                  color: on ? C.accent : C.sub,
                  fontSize: 13,
                  fontWeight: on ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _hotGrid() {
    if (_loadingHot) {
      return const Center(
        child: CircularProgressIndicator(strokeWidth: 2, color: C.accent),
      );
    }
    if (_hotError != null) {
      return _hint(_hotError!, retry: () => _loadHot(_tab));
    }
    if (_hots.isEmpty) {
      return _hint('这个榜单暂时没有数据');
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 14,
        crossAxisSpacing: 10,
        childAspectRatio: 0.52,
      ),
      itemCount: _hots.length,
      itemBuilder: (BuildContext _, int i) {
        final HotItem it = _hots[i];
        return GestureDetector(
          onTap: () => _openByTitle(it.title),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Stack(
                  children: <Widget>[
                    Positioned.fill(child: _poster(it.cover)),
                    if (it.rating != null)
                      Positioned(
                        right: 5,
                        top: 5,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xCC000000),
                            borderRadius: BorderRadius.circular(Metrics.tag),
                          ),
                          child: Text(
                            it.rating!,
                            style: const TextStyle(
                              color: Color(0xFFFFC94D),
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Text(
                it.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: C.text,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 首次搜索时的整页反馈：给出进度，避免"点了没反应"
  Widget _searchingView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2, color: C.accent),
          ),
          const SizedBox(height: 14),
          const Text(
            '正在搜索各个片源…',
            style: TextStyle(color: C.text, fontSize: 13),
          ),
          const SizedBox(height: 6),
          Text(
            _srcTotal > 0 ? '已完成 $_srcDone / $_srcTotal 个源' : '连接中…',
            style: const TextStyle(color: C.muted, fontSize: 11.5),
          ),
        ],
      ),
    );
  }

  Widget _resultList() {
    if (_searchError != null) {
      return _hint(_searchError!, retry: () => _runSearch(_q.text));
    }
    final List<SearchItem> list = _results ?? <SearchItem>[];
    if (list.isEmpty && !_searching) {
      return _hint('没有找到相关片源，换个关键词试试');
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
      // 末尾多一行：搜索中时显示进度
      itemCount: list.length + (_searching ? 1 : 0),
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (BuildContext _, int i) {
        if (i >= list.length) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                const SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.6,
                    color: C.muted,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '继续搜索中 $_srcDone / $_srcTotal',
                  style: const TextStyle(color: C.muted, fontSize: 11.5),
                ),
              ],
            ),
          );
        }
        final SearchItem it = list[i];
        return GestureDetector(
          onTap: () => _openDetail(it),
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: softBox(),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SizedBox(
                    width: 62,
                    height: 88,
                    child: _poster(it.pic),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const SizedBox(height: 2),
                      Text(
                        it.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: C.text,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        it.subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: C.muted, fontSize: 11.5),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: C.accentSoft,
                          borderRadius: BorderRadius.circular(Metrics.tag),
                        ),
                        child: Text(
                          it.sourceName,
                          style: const TextStyle(color: C.accent, fontSize: 10),
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: C.muted,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _poster(String? url) {
    if (url == null || url.isEmpty) return _posterFallback();
    // 豆瓣图有防盗链（418/403），走自家代理；采集站图直连
    final String u = Api.i.imageUrl(url);
    final bool proxied = u.contains('/api/proxy');
    return Image.network(
      u,
      fit: BoxFit.cover,
      headers: proxied ? Api.i.imageHeaders : null,
      errorBuilder: (_, __, ___) => _posterFallback(),
      loadingBuilder: (BuildContext _, Widget child, ImageChunkEvent? p) {
        if (p == null) return child;
        return Container(color: C.soft);
      },
    );
  }

  Widget _posterFallback() {
    return Container(
      color: C.soft,
      alignment: Alignment.center,
      child: const Icon(Icons.movie_outlined, size: 20, color: C.muted),
    );
  }

  Widget _hint(String text, {VoidCallback? retry}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: C.muted, fontSize: 13, height: 1.6),
            ),
            if (retry != null) ...<Widget>[
              const SizedBox(height: 14),
              TextButton(
                onPressed: retry,
                child: const Text('重试', style: TextStyle(color: C.accent)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
