import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';
import 'player_screen.dart';

/// 详情页（按验收通过的竖屏 demo 复刻）：视频区 + 简介/评论 + 选集 + 简介正文。
class DetailScreen extends StatefulWidget {
  const DetailScreen({super.key, required this.item});

  final SearchItem item;

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  VideoDetail? _detail;
  String? _error;
  bool _loading = true;
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final VideoDetail d = await Api.i.detail(widget.item);
      if (!mounted) return;
      setState(() {
        _detail = d;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is ApiException ? e.message : '$e';
        _loading = false;
      });
    }
  }

  void _play(int index) {
    final VideoDetail? d = _detail;
    if (d == null || index < 0 || index >= d.episodes.length) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext _) => PlayerScreen(
          url: d.episodes[index],
          title: d.info.title.isNotEmpty ? d.info.title : widget.item.name,
          episodes: d.episodes,
          index: index,
          sourceName: widget.item.sourceName,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: C.bg,
      body: Column(
        children: <Widget>[
          _videoArea(),
          Expanded(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: C.accent,
                    ),
                  )
                : _error != null
                ? _errorView()
                : _body(),
          ),
        ],
      ),
    );
  }

  // ---------- 视频区（顶部栏透明浮在画面上） ----------

  Widget _videoArea() {
    final VideoDetail? d = _detail;
    final String title = d?.info.title.isNotEmpty == true
        ? d!.info.title
        : widget.item.name;
    final String? cover = d?.info.cover ?? widget.item.pic;

    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Container(color: const Color(0xFF0B0F16)),
          if (cover != null && cover.isNotEmpty)
            Image.network(
              // 豆瓣封面需代理（防盗链 418/403），代理还要带登录 cookie
              Api.i.imageUrl(cover),
              fit: BoxFit.cover,
              headers: Api.i.imageUrl(cover).contains('/api/proxy')
                  ? Api.i.imageHeaders
                  : null,
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
          // 压暗，保证白色文字和图标在亮封面上也读得清
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[
                  Color(0x99000000),
                  Color(0x33000000),
                  Color(0x8C000000),
                ],
                stops: <double>[0, 0.45, 1],
              ),
            ),
          ),
          // 顶部透明栏
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 2, 4, 8),
                child: Row(
                  children: <Widget>[
                    _topIcon(Icons.arrow_back_ios_new_rounded, () {
                      Navigator.of(context).maybePop();
                    }, size: 18),
                    const SizedBox(width: 2),
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          shadows: <Shadow>[
                            Shadow(color: Color(0x66000000), blurRadius: 4),
                          ],
                        ),
                      ),
                    ),
                    _topIcon(Icons.picture_in_picture_alt_rounded, () {
                      _toast('悬浮窗将在后续版本接入');
                    }, size: 19),
                    _topIcon(Icons.airplay_rounded, () {
                      _toast('投屏将在后续版本接入');
                    }, size: 20),
                  ],
                ),
              ),
            ),
          ),
          // 中间播放键
          Center(
            child: GestureDetector(
              onTap: _detail == null ? null : () => _play(0),
              child: Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  color: const Color(0x59000000),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white70, width: 1.4),
                ),
                child: const Icon(
                  Icons.play_arrow_rounded,
                  color: Colors.white,
                  size: 30,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _topIcon(IconData icon, VoidCallback onTap, {double size = 20}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Icon(
          icon,
          size: size,
          color: Colors.white,
          shadows: const <Shadow>[
            Shadow(color: Color(0x66000000), blurRadius: 4),
          ],
        ),
      ),
    );
  }

  // ---------- 下方内容 ----------

  Widget _body() {
    final VideoDetail d = _detail!;
    final VideoInfo info = d.info;
    return ListView(
      padding: EdgeInsets.zero,
      children: <Widget>[
        _tabs(),
        _titleBlock(info),
        _episodeBlock(d),
        if ((info.desc ?? '').isNotEmpty) _descBlock(info.desc!),
        const SizedBox(height: 28),
      ],
    );
  }

  Widget _tabs() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: <Widget>[
          for (int i = 0; i < 2; i++)
            GestureDetector(
              onTap: () => setState(() => _tab = i),
              child: Padding(
                padding: const EdgeInsets.only(right: 22),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      i == 0 ? '简介' : '评论',
                      style: TextStyle(
                        color: _tab == i ? C.accent : C.sub,
                        fontSize: 15,
                        fontWeight: _tab == i
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      width: 22,
                      height: 3,
                      decoration: BoxDecoration(
                        color: _tab == i ? C.accent : Colors.transparent,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const Spacer(),
        ],
      ),
    );
  }

  Widget _titleBlock(VideoInfo info) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Text(
                  info.title.isNotEmpty ? info.title : widget.item.name,
                  style: const TextStyle(
                    color: C.text,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _meta(info),
            style: const TextStyle(color: C.muted, fontSize: 11.5),
          ),
        ],
      ),
    );
  }

  String _meta(VideoInfo info) {
    final List<String> parts = <String>[
      if ((info.typeName ?? '').isNotEmpty) info.typeName!,
      if ((info.year ?? '').isNotEmpty) info.year!,
      if ((info.area ?? '').isNotEmpty) info.area!,
      if ((info.remarks ?? '').isNotEmpty) info.remarks!,
    ];
    return parts.join(' · ');
  }

  Widget _episodeBlock(VideoDetail d) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Text(
                '选集',
                style: TextStyle(
                  color: C.text,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: C.soft,
                  borderRadius: BorderRadius.circular(Metrics.tag),
                ),
                child: Text(
                  widget.item.sourceName,
                  style: const TextStyle(color: C.muted, fontSize: 10),
                ),
              ),
              const Spacer(),
              Text(
                '共 ${d.episodes.length} 集',
                style: const TextStyle(color: C.muted, fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: <Widget>[
              for (int i = 0; i < d.episodes.length; i++)
                GestureDetector(
                  onTap: () => _play(i),
                  child: Container(
                    width: 96,
                    height: 42,
                    alignment: Alignment.center,
                    decoration: softBox(),
                    child: Text(
                      d.episodeLabel(i),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: C.text, fontSize: 13),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: () => Navigator.of(context).maybePop(),
            child: Row(
              children: <Widget>[
                const Icon(Icons.swap_horiz_rounded, size: 16, color: C.accent),
                const SizedBox(width: 4),
                Text(
                  '换源（返回上一步选其他片源）',
                  style: TextStyle(color: C.accent.withAlpha(230), fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 源站简介里带 <p>/<br>&nbsp; 等标签，直接丢给 Text 会把尖括号原样显示出来
  String _cleanDesc(String s) {
    String t = s
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</p\s*>', caseSensitive: false), '\n\n')
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'");
    t = t.replaceAll(RegExp(r'[ \t]+\n'), '\n').replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return t.trim();
  }

  Widget _descBlock(String desc) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            '简介',
            style: TextStyle(
              color: C.text,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _cleanDesc(desc),
            style: const TextStyle(
              color: C.sub,
              fontSize: 12.5,
              height: 1.75,
            ),
          ),
        ],
      ),
    );
  }

  Widget _errorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: C.muted, fontSize: 13, height: 1.6),
            ),
            const SizedBox(height: 14),
            TextButton(
              onPressed: _load,
              child: const Text('重试', style: TextStyle(color: C.accent)),
            ),
          ],
        ),
      ),
    );
  }

  void _toast(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text, style: const TextStyle(fontSize: 12)),
        duration: const Duration(milliseconds: 1200),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
