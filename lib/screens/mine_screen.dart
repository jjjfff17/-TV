import 'package:flutter/material.dart';

import '../history_store.dart';
import '../models.dart';
import '../store.dart';
import '../theme.dart';
import '../ui.dart';
import 'detail_screen.dart';

/// 「我的」：观看记录（带进度）+ 我的收藏。
/// 纯本地数据（shared_preferences），不需要登录。
class MineScreen extends StatefulWidget {
  const MineScreen({super.key});

  @override
  State<MineScreen> createState() => MineScreenState();
}

class MineScreenState extends State<MineScreen> {
  List<HistoryItem> _hist = <HistoryItem>[];
  List<FavItem> _favs = <FavItem>[];

  @override
  void initState() {
    super.initState();
    reload();
  }

  /// 切到本页时刷新（收藏/进度可能在详情页被改过）
  Future<void> reload() async {
    await FavStore.load();
    await HistoryStore.load();
    if (!mounted) return;
    setState(() {
      _hist = HistoryStore.items;
      _favs = FavStore.items;
    });
  }

  void _open({
    required String sourceKey,
    required String vodId,
    required String name,
    String? pic,
    required String sourceName,
  }) {
    final SearchItem item = SearchItem(
      sourceKey: sourceKey,
      sourceName: sourceName,
      vodId: vodId,
      name: name,
      pic: pic,
    );
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 240),
        reverseTransitionDuration: const Duration(milliseconds: 200),
        pageBuilder: (BuildContext _, Animation<double> __, Animation<double> ___) =>
            DetailScreen(item: item),
        transitionsBuilder: (BuildContext _, Animation<double> a, Animation<double> __, Widget child) {
          return FadeTransition(opacity: a, child: child);
        },
      ),
    ).then((_) => reload());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: C.bg,
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          color: C.accent,
          onRefresh: reload,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
            children: <Widget>[
              _header(),
              const SizedBox(height: 20),
              _sectionTitle('观看记录', _hist.length),
              const SizedBox(height: 12),
              _historyBlock(),
              const SizedBox(height: 26),
              _sectionTitle('我的收藏', _favs.length),
              const SizedBox(height: 12),
              _favBlock(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header() {
    return Row(
      children: <Widget>[
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: C.accentSoft,
            borderRadius: BorderRadius.circular(23),
          ),
          child: const Icon(Icons.person_rounded, size: 26, color: C.accentDeep),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text(
                '我的',
                style: TextStyle(
                  color: C.text,
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                '本地记录 · 收藏 ${_favs.length} · 看过 ${_hist.length}',
                style: const TextStyle(color: C.muted, fontSize: 11.5),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _sectionTitle(String title, int count) {
    return Row(
      children: <Widget>[
        Text(
          title,
          style: const TextStyle(
            color: C.text,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(width: 8),
        if (count > 0)
          Text(
            '$count',
            style: const TextStyle(color: C.muted, fontSize: 12),
          ),
        const Spacer(),
        const Icon(Icons.chevron_right_rounded, size: 18, color: C.muted),
      ],
    );
  }

  // ---------------- 观看记录 ----------------

  Widget _historyBlock() {
    if (_hist.isEmpty) {
      return _emptyHint('还没有观看记录，播放一集就会出现在这里');
    }
    return SizedBox(
      height: 150,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        itemCount: _hist.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (BuildContext _, int i) => _historyCard(_hist[i]),
      ),
    );
  }

  Widget _historyCard(HistoryItem h) {
    return GestureDetector(
      onTap: () => _open(
        sourceKey: h.sourceKey,
        vodId: h.vodId,
        name: h.name,
        pic: h.pic,
        sourceName: h.sourceName,
      ),
      child: SizedBox(
        width: 138,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Stack(
                children: <Widget>[
                  SizedBox(
                    width: 138,
                    height: 84,
                    child: NetImg(url: h.pic, memWidth: 320),
                  ),
                  // 进度/看过角标
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(6, 10, 6, 4),
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: <Color>[Color(0x00000000), Color(0xB3000000)],
                        ),
                      ),
                      child: Text(
                        _progText(h),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                  // 进度条
                  if (h.durMs > 0 && h.ratio > 0)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: LinearProgressIndicator(
                        value: h.ratio,
                        minHeight: 2.5,
                        backgroundColor: Colors.white24,
                        valueColor: const AlwaysStoppedAnimation<Color>(C.accent),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              h.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: C.text,
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '第${h.index + 1}集',
              maxLines: 1,
              style: const TextStyle(color: C.muted, fontSize: 10.5),
            ),
          ],
        ),
      ),
    );
  }

  String _progText(HistoryItem h) {
    final double r = h.ratio;
    if (h.durMs > 0 && r >= 0.98) return '已看完';
    if (h.durMs > 0 && r >= 0.02) return '已看 ${(r * 100).round()}%';
    final int age = DateTime.now().millisecondsSinceEpoch - h.ts;
    if (age < const Duration(hours: 24).inMilliseconds) return '刚刚看过';
    return '看过';
  }

  // ---------------- 我的收藏 ----------------

  Widget _favBlock() {
    if (_favs.isEmpty) {
      return _emptyHint('还没有收藏，详情页点「收藏」即可加入');
    }
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 14,
        crossAxisSpacing: 10,
        childAspectRatio: 0.52,
      ),
      itemCount: _favs.length,
      itemBuilder: (BuildContext _, int i) {
        final FavItem f = _favs[i];
        final int bar = f.key.indexOf('|');
        final String sk = bar >= 0 ? f.key.substring(0, bar) : f.key;
        final String vid = bar >= 0 ? f.key.substring(bar + 1) : '';
        return GestureDetector(
          onTap: () => _open(
            sourceKey: sk,
            vodId: vid,
            name: f.name,
            pic: f.pic,
            sourceName: f.sourceName,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: NetImg(url: f.pic, memWidth: 340),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                f.name,
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

  Widget _emptyHint(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 26),
      alignment: Alignment.center,
      decoration: softBox(),
      child: Text(
        text,
        style: const TextStyle(color: C.muted, fontSize: 12.5),
      ),
    );
  }
}
