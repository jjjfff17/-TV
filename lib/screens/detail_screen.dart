import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../api.dart';
import '../history_store.dart';
import '../models.dart';
import '../mpv_tuning.dart';
import '../store.dart';
import '../theme.dart';
import '../ui.dart';
import 'player_screen.dart';

/// 详情页（对齐 Lanerc）：顶部 16:9 内嵌播放器 + 简介 + 选集 + 底部悬浮栏。
///
/// 0.5.0 的三处关键改动：
/// 1) 打开详情就**预载第一集但不播**（open play:false），点播放键直接 play → 秒开；
/// 2) 播放状态全部走 ValueNotifier，避免整页 setState 导致卡顿；
/// 3) 补齐 Lanerc 结构：简介 tab、3 行简介+展开、选集横向网格、底部「收藏/换源」悬浮栏。
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

  // ---------- 内嵌播放器 ----------
  Player? _player;
  VideoController? _controller;
  final List<StreamSubscription<dynamic>> _subs = <StreamSubscription<dynamic>>[];

  int? _ep; // 当前集；null = 还没开始播（显示封面 + 播放键）
  int _loadedIndex = -1; // 播放器里当前已装载的集（用于判断能否直接 play）
  bool _fullscreen = false; // 全屏时卸载本页 Video，避免抢纹理
  bool _viaProxy = false;
  bool _fav = false;
  bool _controls = true;
  bool _seeking = false;
  bool _descOpen = false;

  /// 播放状态（局部刷新，不整页重建）
  final ValueNotifier<Duration> _pos = ValueNotifier<Duration>(Duration.zero);
  final ValueNotifier<Duration> _dur = ValueNotifier<Duration>(Duration.zero);
  final ValueNotifier<bool> _playing = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _buffering = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _started = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _slow = ValueNotifier<bool>(false);
  final ValueNotifier<String?> _pErr = ValueNotifier<String?>(null);

  Timer? _hideTimer;
  Timer? _slowTimer;
  Timer? _histTimer;

  /// 全屏返回时暂存：当前集与进度（PlayerScreen 在 dispose 回传）
  int _resumeIndex = 0;
  Duration _resumePos = Duration.zero;

  @override
  void initState() {
    super.initState();
    _load();
    FavStore.load().then((_) {
      if (!mounted) return;
      setState(() {
        _fav = FavStore.has(widget.item.sourceKey, widget.item.vodId);
      });
    });
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _slowTimer?.cancel();
    _histTimer?.cancel();
    _recordHist();
    for (final StreamSubscription<dynamic> s in _subs) {
      unawaited(s.cancel());
    }
    _pos.dispose();
    _dur.dispose();
    _playing.dispose();
    _buffering.dispose();
    _started.dispose();
    _slow.dispose();
    _pErr.dispose();
    final Player? p = _player;
    _player = null;
    if (p != null) {
      unawaited(WakelockPlus.disable());
      unawaited(p.dispose());
    }
    super.dispose();
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
      // 预载第一集：只装载不播放，点播放键时直接 play
      unawaited(_preload());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is ApiException ? e.message : '$e';
        _loading = false;
      });
    }
  }

  // ---------------- 播放器 ----------------

  void _ensurePlayer() {
    if (_player != null) return;
    final Player p = Player();
    _player = p;
    applyMpvTuning(p);
    _controller = VideoController(
      p,
      configuration: const VideoControllerConfiguration(
        enableHardwareAcceleration: true,
      ),
    );

    _subs.add(p.stream.position.listen((Duration v) {
      if (!_seeking) _pos.value = v;
      // 出画判据 = 时间轴开始前进（libmpv 的 playing 在首帧前就为 true）
      if (!_started.value && v > const Duration(milliseconds: 250)) {
        _started.value = true;
        _slow.value = false;
        _slowTimer?.cancel();
      }
    }));
    _subs.add(p.stream.duration.listen((Duration v) => _dur.value = v));
    _subs.add(p.stream.playing.listen((bool v) {
      _playing.value = v;
      if (v) _armHide();
    }));
    _subs.add(p.stream.buffering.listen((bool v) => _buffering.value = v));
    _subs.add(p.stream.error.listen((String e) {
      if (!_viaProxy) {
        _viaProxy = true;
        _started.value = false;
        _slow.value = false;
        _pErr.value = null;
        _pos.value = Duration.zero;
        _armSlow(seconds: 12);
        unawaited(_reopenViaProxy());
        return;
      }
      _pErr.value = e;
    }));
  }

  Future<void> _preload() async {
    final VideoDetail? d = _detail;
    if (d == null || d.episodes.isEmpty) return;
    _ensurePlayer();
    if (_loadedIndex >= 0) return;
    try {
      await _player!.open(Media(d.episodes[0]), play: false);
      _loadedIndex = 0;
    } catch (_) {
      // 预载失败不影响正常播放，点播放键时会重新 open
    }
  }

  Future<void> _reopenViaProxy() async {
    final VideoDetail? d = _detail;
    final int? i = _ep;
    if (d == null || i == null || i >= d.episodes.length) return;
    try {
      await _player?.open(Media(Api.i.proxyUrl(d.episodes[i])));
      _loadedIndex = i;
      await _player?.play();
    } catch (e) {
      _pErr.value = '$e';
    }
  }

  Future<void> _openEpisode(int i) async {
    final VideoDetail? d = _detail;
    if (d == null || i < 0 || i >= d.episodes.length) return;
    _ensurePlayer();
    unawaited(HapticFeedback.selectionClick());
    setState(() {
      _ep = i;
      _controls = true;
    });
    _pErr.value = null;
    _started.value = false;
    _slow.value = false;
    _pos.value = Duration.zero;
    _dur.value = Duration.zero;
    _viaProxy = false;
    _armSlow();
    _armHide();
    try {
      if (_loadedIndex == i) {
        await _player!.play();
      } else {
        await _player!.open(Media(d.episodes[i]));
        _loadedIndex = i;
      }
      unawaited(WakelockPlus.enable());
      _armHist();
    } catch (e) {
      _pErr.value = '$e';
    }
  }

  void _armSlow({int seconds = 10}) {
    _slowTimer?.cancel();
    _slowTimer = Timer(Duration(seconds: seconds), () {
      if (mounted && !_started.value) _slow.value = true;
    });
  }

  void _armHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _playing.value) setState(() => _controls = false);
    });
  }

  void _toggleControls() {
    if (_ep == null) return;
    setState(() => _controls = !_controls);
    if (_controls) _armHide();
  }

  // ---------- 观看记录 ----------

  void _armHist() {
    _histTimer?.cancel();
    _histTimer = Timer.periodic(const Duration(seconds: 10), (_) => _recordHist());
  }

  void _recordHist() {
    final VideoDetail? d = _detail;
    final int? i = _ep;
    if (d == null || i == null) return;
    final int posMs = _pos.value.inMilliseconds;
    if (posMs <= 0) return;
    unawaited(HistoryStore.record(
      sourceKey: widget.item.sourceKey,
      vodId: widget.item.vodId,
      name: widget.item.name,
      pic: widget.item.pic,
      sourceName: widget.item.sourceName,
      index: i,
      posMs: posMs,
      durMs: _dur.value.inMilliseconds,
    ));
  }

  /// 彻底释放本页播放器：取消订阅 → 等 Video 摘树 → 销毁 libmpv 实例。
  ///
  /// 必须"先放后建"：一台设备上的硬件解码器与上游流连接都是稀缺资源，
  /// 两个 Player 同时活着时，后建的那个会开不出流（全屏页永远 00:00）。
  Future<void> _releasePlayer() async {
    final Player? p = _player;
    _player = null;
    _controller = null;
    _loadedIndex = -1;
    _viaProxy = false;
    for (final StreamSubscription<dynamic> s in _subs) {
      unawaited(s.cancel());
    }
    _subs.clear();
    // 等一帧，确保 Video widget 已从树上摘掉，再销毁原生播放器
    await Future<void>.delayed(const Duration(milliseconds: 80));
    if (p != null) {
      try {
        await p.dispose();
      } catch (_) {}
    }
  }

  /// 进全屏：详情页先把播放器彻底释放（唯一播放器原则），
  /// PlayerScreen 在横屏新建 Player+VideoController 开流（绕开共享 Surface 黑屏），
  /// 退出后按回传的集与进度重建续播。
  Future<void> _enterFullscreen() async {
    final VideoDetail? d = _detail;
    final int? i = _ep;
    if (d == null || i == null) return;
    _hideTimer?.cancel();
    _histTimer?.cancel();
    _recordHist();
    _resumeIndex = i;
    _resumePos = _pos.value;
    setState(() {
      _controls = true;
      _fullscreen = true; // 本页 Video 卸载，随后销毁纹理
    });
    await _releasePlayer();
    if (!mounted) return;
    await Navigator.of(context).push(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 240),
        reverseTransitionDuration: const Duration(milliseconds: 200),
        pageBuilder: (BuildContext _, Animation<double> __, Animation<double> ___) =>
            PlayerScreen(
              url: d.episodes[i],
              title: d.info.title.isNotEmpty ? d.info.title : widget.item.name,
              episodes: d.episodes,
              index: i,
              sourceName: widget.item.sourceName,
              startFullscreen: true,
              startAt: _resumePos,
              item: widget.item,
              onEpisodeChanged: (int ni) {
                if (!mounted) return;
                setState(() => _ep = ni);
              },
              onExit: (int idx, Duration pos, Duration dur) {
                _resumeIndex = idx;
                if (pos > Duration.zero) _resumePos = pos;
              },
            ),
        transitionsBuilder: (BuildContext _, Animation<double> a, Animation<double> __, Widget child) {
          return FadeTransition(opacity: a, child: child);
        },
      ),
    );
    if (!mounted) return;
    setState(() {
      _fullscreen = false;
      _controls = true;
    });
    await _resumeFromFullscreen();
    _armHide();
  }

  /// 从全屏回来：重建本页播放器，按回传的集与进度续播
  Future<void> _resumeFromFullscreen() async {
    final VideoDetail? d = _detail;
    if (d == null || d.episodes.isEmpty) return;
    // 全屏页的 Player 是在 dispose 里异步销毁的，先让原生侧收干净，
    // 否则新实例又要和旧实例抢解码器（同 00:00 那个坑）。
    await Future<void>.delayed(const Duration(milliseconds: 180));
    if (!mounted) return;
    final int idx = _resumeIndex.clamp(0, d.episodes.length - 1).toInt();
    final Duration pos = _resumePos;
    _pErr.value = null;
    _slow.value = false;
    _started.value = false;
    _pos.value = Duration.zero;
    _dur.value = Duration.zero;
    _ensurePlayer();
    if (!mounted) return;
    setState(() {
      _ep = idx;
      _controls = true;
    });
    _armSlow();
    final Player? p = _player;
    if (p == null) return;
    final bool resume = pos > const Duration(seconds: 1);
    try {
      unawaited(WakelockPlus.enable());
      await p.open(Media(d.episodes[idx]), play: !resume);
      _loadedIndex = idx;
      if (resume) {
        await p.seek(pos);
        await p.play();
      }
      _armHist();
    } catch (e) {
      _pErr.value = '$e';
    }
    _playing.value = p.state.playing;
  }

  Future<void> _toggleFav() async {
    final SearchItem it = widget.item;
    final bool now = await FavStore.toggle(
      sourceKey: it.sourceKey,
      vodId: it.vodId,
      name: it.name,
      pic: it.pic,
      sourceName: it.sourceName,
    );
    if (!mounted) return;
    unawaited(HapticFeedback.selectionClick());
    setState(() => _fav = now);
    _toast(now ? '已加入收藏' : '已取消收藏');
  }

  // ---------------- 界面 ----------------

  @override
  Widget build(BuildContext context) {
    final bool ready = !_loading && _error == null;
    return Scaffold(
      backgroundColor: C.bg,
      body: Stack(
        children: <Widget>[
          Column(
            children: <Widget>[
              _videoArea(),
              Expanded(
                child: _loading
                    ? _skeletonBody()
                    : _error != null
                        ? _errorView()
                        : _body(),
              ),
            ],
          ),
          if (ready) _bottomBar(),
        ],
      ),
    );
  }

  Widget _videoArea() {
    final VideoDetail? d = _detail;
    final String title = d?.info.title.isNotEmpty == true
        ? d!.info.title
        : widget.item.name;
    final String? cover = d?.info.cover ?? widget.item.pic;
    final bool playing = _ep != null;

    return AspectRatio(
      aspectRatio: 16 / 9,
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            const ColoredBox(color: C.darkBg),

            if (playing && _controller != null && !_fullscreen)
              RepaintBoundary(
                child: Video(
                  controller: _controller!,
                  controls: NoVideoControls,
                ),
              ),

            // 尚未开播：封面（带 Hero，从列表进来时无缝放大）
            if (!playing && cover != null && cover.isNotEmpty)
              Hero(
                tag: 'p_${widget.item.sourceKey}_${widget.item.vodId}',
                child: NetImg(url: cover, memWidth: 900),
              ),

            if (!playing)
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: <Color>[
                      Color(0x88000000),
                      Color(0x33000000),
                      Color(0x8C000000),
                    ],
                    stops: <double>[0, 0.45, 1],
                  ),
                ),
              ),

            if (playing)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _toggleControls,
                child: const SizedBox.expand(),
              ),

            if (playing) _playerOverlay(),

            if (!playing) _bigPlayButton(),
            if (playing && _controls) _controlsBar(),

            _topBar(title, playing),
          ],
        ),
      ),
    );
  }

  Widget _bigPlayButton() {
    final bool ready = _detail != null;
    return Center(
      child: GestureDetector(
        onTap: ready ? () => _openEpisode(0) : null,
        child: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: const Color(0x59000000),
            shape: BoxShape.circle,
            border: Border.all(
              color: ready ? Colors.white70 : Colors.white24,
              width: 1.4,
            ),
          ),
          child: Icon(
            Icons.play_arrow_rounded,
            color: ready ? Colors.white : Colors.white38,
            size: 32,
          ),
        ),
      ),
    );
  }

  Widget _playerOverlay() {
    return ValueListenableBuilder<String?>(
      valueListenable: _pErr,
      builder: (BuildContext _, String? err, Widget? __) {
        if (err != null) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Icon(Icons.error_outline_rounded, color: Colors.white70, size: 26),
                  const SizedBox(height: 8),
                  Text(
                    '播放失败：$err',
                    maxLines: 2,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 11.5),
                  ),
                  const SizedBox(height: 6),
                  TextButton(
                    onPressed: () {
                      final int? i = _ep;
                      if (i != null) unawaited(_openEpisode(i));
                    },
                    child: const Text('重试', style: TextStyle(color: C.accent, fontSize: 12)),
                  ),
                ],
              ),
            ),
          );
        }
        return ValueListenableBuilder<bool>(
          valueListenable: _buffering,
          builder: (BuildContext _, bool buf, Widget? __) {
            return ValueListenableBuilder<bool>(
              valueListenable: _started,
              builder: (BuildContext _, bool started, Widget? ___) {
                if (started && !buf) return const SizedBox.shrink();
                return ValueListenableBuilder<bool>(
                  valueListenable: _slow,
                  builder: (BuildContext _, bool slow, Widget? ____) {
                    final String text = (buf && started)
                        ? '缓冲中…'
                        : (slow ? '加载较慢，可换一集或换源' : '正在加载…');
                    return IgnorePointer(
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          decoration: BoxDecoration(
                            color: const Color(0xCC000000),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70),
                              ),
                              const SizedBox(width: 10),
                              Text(text, style: const TextStyle(color: Colors.white, fontSize: 12)),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  /// 极简控件：`播放键 + 当前时间 ──进度条── 总时长 + 全屏`（对齐 Lanerc 的 4 元素）
  Widget _controlsBar() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 22, 6, 2),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: <Color>[Color(0xE6000000), Color(0x00000000)],
          ),
        ),
        child: ValueListenableBuilder<Duration>(
          valueListenable: _dur,
          builder: (BuildContext _, Duration dur, Widget? __) {
            final double maxMs = dur.inMilliseconds > 0
                ? dur.inMilliseconds.toDouble()
                : 1.0;
            return Row(
              children: <Widget>[
                ValueListenableBuilder<bool>(
                  valueListenable: _playing,
              builder: (BuildContext _, bool p, Widget? __) => _ctlIcon(
                p ? Icons.pause_rounded : Icons.play_arrow_rounded,
                () {
                  unawaited(_player?.playOrPause() ?? Future<void>.value());
                  _armHide();
                },
              ),
            ),
            const SizedBox(width: 2),
            ValueListenableBuilder<Duration>(
              valueListenable: _pos,
              builder: (BuildContext _, Duration pos, Widget? __) => SizedBox(
                width: 44,
                child: Text(
                  fmtDuration(pos),
                  style: const TextStyle(color: Colors.white, fontSize: 11.5),
                ),
              ),
            ),
            Expanded(
              child: ValueListenableBuilder<Duration>(
                valueListenable: _pos,
                builder: (BuildContext _, Duration pos, Widget? __) {
                  final double value = pos.inMilliseconds.toDouble().clamp(0.0, maxMs);
                  return SliderTheme(
                    data: SliderThemeData(
                      trackHeight: 2.5,
                      activeTrackColor: Colors.white,
                      inactiveTrackColor: Colors.white24,
                      thumbColor: Colors.white,
                      overlayColor: Colors.white24,
                      thumbShape: RoundSliderThumbShape(enabledThumbRadius: _seeking ? 7 : 4),
                      overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                      trackShape: const RectangularSliderTrackShape(),
                    ),
                    child: Slider(
                      value: value,
                      max: maxMs,
                      onChangeStart: (double _) {
                        _hideTimer?.cancel();
                        setState(() => _seeking = true);
                      },
                      onChanged: (double v) {
                        _pos.value = Duration(milliseconds: v.round());
                      },
                      onChangeEnd: (double v) async {
                        final Duration t = Duration(milliseconds: v.round());
                        setState(() => _seeking = false);
                        await _player?.seek(t);
                        _armHide();
                      },
                    ),
                  );
                },
              ),
            ),
            ValueListenableBuilder<Duration>(
              valueListenable: _dur,
              builder: (BuildContext _, Duration dur, Widget? __) => SizedBox(
                width: 46,
                child: Text(
                  fmtDuration(dur),
                  textAlign: TextAlign.right,
                  style: const TextStyle(color: Colors.white70, fontSize: 11.5),
                ),
              ),
            ),
                _ctlIcon(Icons.fullscreen_rounded, _enterFullscreen, size: 22),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _ctlIcon(IconData icon, VoidCallback onTap, {double size = 24}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Icon(icon, size: size, color: Colors.white),
      ),
    );
  }

  Widget _topBar(String title, bool playing) {
    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[Color(0xB3000000), Color(0x00000000)],
          ),
        ),
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
                      shadows: <Shadow>[Shadow(color: Color(0x66000000), blurRadius: 4)],
                    ),
                  ),
                ),
                _topIcon(Icons.list_rounded, () {
                  if (playing) _showEpisodeSheet();
                }, size: 22),
              ],
            ),
          ),
        ),
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
          shadows: const <Shadow>[Shadow(color: Color(0x66000000), blurRadius: 4)],
        ),
      ),
    );
  }

  // ---------------- 下方内容 ----------------

  Widget _body() {
    final VideoDetail d = _detail!;
    final VideoInfo info = d.info;
    return ListView(
      padding: const EdgeInsets.only(bottom: 96),
      children: <Widget>[
        _sectionTab(),
        _titleBlock(info),
        if ((info.desc ?? '').isNotEmpty) _introBlock(info.desc!),
        _episodeBlock(d),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _sectionTab() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 2),
      child: Row(
        children: <Widget>[
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text(
                '简介',
                style: TextStyle(color: C.accentDeep, fontSize: 15, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Container(
                width: 20,
                height: 3,
                decoration: BoxDecoration(
                  color: C.accent,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _titleBlock(VideoInfo info) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            info.title.isNotEmpty ? info.title : widget.item.name,
            style: const TextStyle(
              color: C.text,
              fontSize: 18,
              fontWeight: FontWeight.w600,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              for (final String t in _metaTags(info)) _pillTag(t),
            ],
          ),
        ],
      ),
    );
  }

  List<String> _metaTags(VideoInfo info) {
    final List<String?> raw = <String?>[
      info.typeName,
      info.year,
      info.area,
      info.remarks,
    ];
    return raw
        .where((String? s) => s != null && s.trim().isNotEmpty)
        .map((String? s) => s!.trim())
        .toList();
  }

  Widget _pillTag(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: C.soft,
        borderRadius: BorderRadius.circular(Metrics.tag),
      ),
      child: Text(text, style: const TextStyle(color: C.sub, fontSize: 11)),
    );
  }

  Widget _introBlock(String desc) {
    final String clean = _cleanDesc(desc);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            alignment: Alignment.topCenter,
            child: Text(
              clean,
              maxLines: _descOpen ? null : 3,
              overflow: _descOpen ? TextOverflow.visible : TextOverflow.ellipsis,
              style: const TextStyle(color: C.sub, fontSize: 12.5, height: 1.75),
            ),
          ),
          const SizedBox(height: 4),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _descOpen = !_descOpen),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  _descOpen ? '收起' : '展开',
                  style: const TextStyle(color: C.accentDeep, fontSize: 12),
                ),
                Icon(
                  _descOpen ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                  size: 16,
                  color: C.accentDeep,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _episodeBlock(VideoDetail d) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 0, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Row(
              children: <Widget>[
                const Text(
                  '选集',
                  style: TextStyle(color: C.text, fontSize: 15, fontWeight: FontWeight.w600),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: C.accentSoft,
                    borderRadius: BorderRadius.circular(Metrics.tag),
                  ),
                  child: Text(
                    widget.item.sourceName,
                    style: const TextStyle(color: C.accentDeep, fontSize: 10),
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: () => _showEpisodeSheet(),
                  child: Text(
                    '共 ${d.episodes.length} 集 · 全部',
                    style: const TextStyle(color: C.muted, fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 42,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(right: 16),
              itemCount: d.episodes.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (BuildContext _, int i) => _epChip(d, i),
            ),
          ),
        ],
      ),
    );
  }

  Widget _epChip(VideoDetail d, int i) {
    final bool on = _ep == i;
    return GestureDetector(
      onTap: () => _openEpisode(i),
      child: Container(
        constraints: const BoxConstraints(minWidth: 84),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        height: 42,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: on ? C.accentSoft : C.chipBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: on ? C.accent : C.border, width: on ? 1.4 : 1),
        ),
        child: Text(
          d.episodeLabel(i),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: on ? C.accentDeep : C.text,
            fontSize: 13,
            fontWeight: on ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }

  void _showEpisodeSheet() {
    final VideoDetail? d = _detail;
    if (d == null) return;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (BuildContext ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    const Text('选集', style: TextStyle(color: C.text, fontSize: 16, fontWeight: FontWeight.w600)),
                    const Spacer(),
                    Text('共 ${d.episodes.length} 集', style: const TextStyle(color: C.muted, fontSize: 11)),
                  ],
                ),
                const SizedBox(height: 14),
                Flexible(
                  child: SingleChildScrollView(
                    child: Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: <Widget>[
                        for (int i = 0; i < d.episodes.length; i++)
                          GestureDetector(
                            onTap: () {
                              Navigator.of(ctx).pop();
                              unawaited(_openEpisode(i));
                            },
                            child: Container(
                              width: 78,
                              height: 38,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: i == _ep ? C.accentSoft : C.chipBg,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: i == _ep ? C.accent : C.border),
                              ),
                              child: Text(
                                d.episodeLabel(i),
                                style: TextStyle(
                                  color: i == _ep ? C.accentDeep : C.text,
                                  fontSize: 13,
                                  fontWeight: i == _ep ? FontWeight.w600 : FontWeight.w400,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _bottomBar() {
    return Positioned(
      left: 16,
      right: 16,
      bottom: MediaQuery.of(context).padding.bottom + 10,
      child: Container(
        height: 56,
        decoration: BoxDecoration(
          color: const Color(0xF214171C),
          borderRadius: BorderRadius.circular(28),
          boxShadow: const <BoxShadow>[
            BoxShadow(color: Color(0x33000000), blurRadius: 18, offset: Offset(0, 6)),
          ],
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: _barItem(
                _fav ? Icons.star_rounded : Icons.star_border_rounded,
                _fav ? '已收藏' : '收藏',
                _toggleFav,
                active: _fav,
              ),
            ),
            Container(width: 1, height: 22, color: Colors.white12),
            Expanded(
              child: _barItem(
                Icons.swap_horiz_rounded,
                '换片源',
                () => Navigator.of(context).maybePop(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _barItem(IconData icon, String label, VoidCallback onTap, {bool active = false}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(icon, size: 20, color: active ? C.accent : Colors.white70),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: active ? C.accent : Colors.white70,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _skeletonBody() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      children: const <Widget>[
        Skeleton(width: 60, height: 14, radius: 5),
        SizedBox(height: 14),
        Skeleton(width: 240, height: 20, radius: 6),
        SizedBox(height: 10),
        Skeleton(width: 160, height: 12, radius: 5),
        SizedBox(height: 18),
        Skeleton(height: 12, radius: 5),
        SizedBox(height: 8),
        Skeleton(height: 12, radius: 5),
        SizedBox(height: 8),
        Skeleton(width: 220, height: 12, radius: 5),
      ],
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
    t = t
        .replaceAll(RegExp(r'[ \t]+\n'), '\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return t.trim();
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
              child: const Text('重试', style: TextStyle(color: C.accentDeep)),
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
        backgroundColor: C.dark,
      ),
    );
  }
}
