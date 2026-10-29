import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../api.dart';
import '../models.dart';
import '../mpv_tuning.dart';
import '../theme.dart';
import 'player_screen.dart';

/// 详情页（对齐 lanerc 形态）：顶部 16:9 内嵌播放器 + 简介 + 选集。
///
/// 关键设计：**不再跳转到独立播放页**。
/// 点播放/选集就地开播，播放器始终嵌在页面顶部，下方照常浏览简介和选集；
/// 只有点右下角全屏键才进入横屏全屏（PlayerScreen），并复用同一个 Player 实例，
/// 退出全屏后进度不丢、不用重新拉流。
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

  // ---------- 内嵌播放器 ----------
  Player? _player;
  VideoController? _controller;
  final List<StreamSubscription<dynamic>> _subs = <StreamSubscription<dynamic>>[];

  /// 当前正在播的集索引；null = 还没开始播（显示封面 + 播放键）
  int? _ep;

  bool _started = false; // 已真正出画（时间轴前进过）
  bool _slow = false; // 起播超过 10 秒还没出画
  bool _buffering = false;
  bool _playing = false;
  bool _controls = true;
  bool _viaProxy = false;
  bool _seeking = false;
  String? _pErr;
  Duration _dur = Duration.zero;

  /// 是否正在全屏页里。全屏时本页的 Video 必须卸载：
  /// 同一个 VideoController 同时挂两个 Video 会抢同一个 SurfaceTexture，表现就是全屏黑屏。
  bool _fullscreen = false;

  /// 进度条/时间专用：拖动时是目标位置，否则是真实位置。
  /// 用它驱动局部重建，避免整页 setState 导致进度条看起来"不跟手"。
  final ValueNotifier<Duration> _uiPos = ValueNotifier<Duration>(Duration.zero);

  Timer? _hideTimer;
  Timer? _slowTimer;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _slowTimer?.cancel();
    for (final StreamSubscription<dynamic> s in _subs) {
      unawaited(s.cancel());
    }
    _uiPos.dispose();
    final Player? p = _player;
    _player = null;
    if (p != null) {
      unawaited(WakelockPlus.disable());
      // 只释放 Player：media_kit 的 VideoController 由 Player 连带回收，
      // 这里不再单独 dispose，避免不同版本 API 差异导致编译失败。
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
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is ApiException ? e.message : '$e';
        _loading = false;
      });
    }
  }

  // ---------------- 播放器 ----------------

  /// 懒创建：只有用户真的点了播放才初始化原生播放器，进详情页不占内存、不拉流
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
      if (!mounted) return;
      if (!_seeking) _uiPos.value = v;
      // 出画判据是"时间轴开始前进"，不是 playing 事件：
      // libmpv 的 playing 在首帧之前就为 true，用它会让加载浮层刚出现就被收掉。
      if (!_started && v > const Duration(milliseconds: 250)) {
        _started = true;
        _slow = false;
        _slowTimer?.cancel();
        if (mounted) setState(() {});
      }
    }));
    _subs.add(p.stream.duration.listen((Duration v) {
      if (mounted) setState(() => _dur = v);
    }));
    _subs.add(p.stream.playing.listen((bool v) {
      if (!mounted) return;
      setState(() => _playing = v);
      if (v) _armHide();
    }));
    _subs.add(p.stream.buffering.listen((bool v) {
      if (mounted) setState(() => _buffering = v);
    }));
    _subs.add(p.stream.error.listen((String e) {
      if (!mounted) return;
      // 直连源站失败 → 自动切同源代理重试一次（与 Web 端 hls.js 的策略一致）
      if (!_viaProxy) {
        _viaProxy = true;
        setState(() {
          _pErr = null;
          _started = false;
          _slow = false;
        });
        _uiPos.value = Duration.zero;
        _armSlow(seconds: 12);
        unawaited(_reopenViaProxy());
        return;
      }
      setState(() => _pErr = e);
    }));
  }

  Future<void> _reopenViaProxy() async {
    final VideoDetail? d = _detail;
    final int? i = _ep;
    if (d == null || i == null || i >= d.episodes.length) return;
    try {
      await _player?.open(Media(Api.i.proxyUrl(d.episodes[i])));
      await _player?.play();
    } catch (e) {
      if (mounted) setState(() => _pErr = '$e');
    }
  }

  Future<void> _openEpisode(int i) async {
    final VideoDetail? d = _detail;
    if (d == null || i < 0 || i >= d.episodes.length) return;
    _ensurePlayer();
    setState(() {
      _ep = i;
      _pErr = null;
      _started = false;
      _slow = false;
      _viaProxy = false;
      _controls = true;
    });
    _uiPos.value = Duration.zero;
    _armSlow();
    _armHide();
    try {
      await _player!.open(Media(d.episodes[i]));
      await _player!.play();
      unawaited(WakelockPlus.enable());
    } catch (e) {
      if (mounted) setState(() => _pErr = '$e');
    }
  }

  void _armSlow({int seconds = 10}) {
    _slowTimer?.cancel();
    _slowTimer = Timer(Duration(seconds: seconds), () {
      if (mounted && !_started) setState(() => _slow = true);
    });
  }

  void _armHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _playing) setState(() => _controls = false);
    });
  }

  void _toggleControls() {
    if (_ep == null) return;
    setState(() => _controls = !_controls);
    if (_controls) _armHide();
  }

  /// 进全屏：把同一个 Player / VideoController 交给 PlayerScreen，
  /// 所以切换是瞬时的，进度、音量、倍速全部连续。
  Future<void> _enterFullscreen() async {
    final VideoDetail? d = _detail;
    final int? i = _ep;
    final Player? p = _player;
    final VideoController? c = _controller;
    if (d == null || i == null || p == null || c == null) return;
    _hideTimer?.cancel();
    setState(() {
      _controls = true;
      _fullscreen = true; // 让本页的 Video 卸载，独占纹理
    });
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext _) => PlayerScreen(
          url: d.episodes[i],
          title: d.info.title.isNotEmpty ? d.info.title : widget.item.name,
          episodes: d.episodes,
          index: i,
          sourceName: widget.item.sourceName,
          player: p,
          controller: c,
          onEpisodeChanged: (int ni) {
            if (!mounted) return;
            setState(() => _ep = ni);
          },
        ),
      ),
    );
    if (!mounted) return;
    setState(() {
      _fullscreen = false;
      _started = true; // 从全屏回来通常已经在播，别再弹一次加载浮层
      _controls = true;
    });
    _uiPos.value = p.state.position;
    _armHide();
  }

  // ---------------- 界面 ----------------

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
            Container(color: const Color(0xFF0B0F16)),

            // 播放器本体（未播放时不存在，避免无谓的原生初始化；
            //  全屏时卸载，避免和全屏页抢纹理）
            if (playing && _controller != null && !_fullscreen)
              Video(controller: _controller!, controls: NoVideoControls),

            // 未播放：封面
            if (!playing && cover != null && cover.isNotEmpty)
              Image.network(
                Api.i.imageUrl(cover),
                fit: BoxFit.cover,
                headers: Api.i.imageUrl(cover).contains('/api/proxy')
                    ? Api.i.imageHeaders
                    : null,
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),

            // 未播放：压暗 + 说明这里能播
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

            // 单击切换控件（播放中才有意义）
            if (playing)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _toggleControls,
                child: const SizedBox.expand(),
              ),

            // 加载 / 缓冲 / 错误
            if (playing) _playerOverlay(),

            // 未播放：中间播放键
            if (!playing) _bigPlayButton(),

            // 播放中：极简控件条
            if (playing && _controls && _pErr == null) _controlsBar(),

            // 顶部栏（常驻，避免控件隐藏后找不到返回）
            _topBar(title),
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
          width: 54,
          height: 54,
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
            size: 30,
          ),
        ),
      ),
    );
  }

  /// 起播/缓冲浮层：黑屏期间明确告知"在加载"，超时提示换集或换源
  Widget _playerOverlay() {
    if (_pErr != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(
                Icons.error_outline_rounded,
                color: Colors.white70,
                size: 26,
              ),
              const SizedBox(height: 8),
              Text(
                '播放失败：$_pErr',
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70, fontSize: 11.5),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () {
                  final int? i = _ep;
                  if (i != null) unawaited(_openEpisode(i));
                },
                child: const Text(
                  '重试',
                  style: TextStyle(color: C.accent, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final bool show = !_started || _buffering;
    if (!show) return const SizedBox.shrink();
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
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white70,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                _buffering && _started
                    ? '缓冲中…'
                    : (_slow ? '加载较慢，可换一集或换源' : '正在加载…'),
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 极简控件：`播放键 + 当前时间 ──进度条── 总时长 + 全屏`（对齐 lanerc 的 4 元素）
  Widget _controlsBar() {
    final double maxMs = _dur.inMilliseconds > 0
        ? _dur.inMilliseconds.toDouble()
        : 1.0;

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
          valueListenable: _uiPos,
          builder: (BuildContext _, Duration pos, Widget? __) {
            final double value = pos.inMilliseconds.toDouble().clamp(0.0, maxMs);
            return Row(
              children: <Widget>[
                _ctlIcon(
                  _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  () {
                    unawaited(_player?.playOrPause() ?? Future<void>.value());
                    _armHide();
                  },
                ),
                const SizedBox(width: 2),
                SizedBox(
                  width: 44,
                  child: Text(
                    fmtDuration(pos),
                    style: const TextStyle(color: Colors.white, fontSize: 11.5),
                  ),
                ),
                Expanded(
                  child: SliderTheme(
                    data: SliderThemeData(
                      trackHeight: 2.5,
                      activeTrackColor: Colors.white,
                      inactiveTrackColor: Colors.white24,
                      thumbColor: Colors.white,
                      overlayColor: Colors.white24,
                      thumbShape: RoundSliderThumbShape(
                        enabledThumbRadius: _seeking ? 7 : 4,
                      ),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 12,
                      ),
                      trackShape: const RectangularSliderTrackShape(),
                    ),
                    child: Slider(
                      value: value,
                      max: maxMs,
                      // 拖动中只移动显示位置，松手才真正 seek：
                      // 每帧都 seek 会让 libmpv 反复清缓冲重连，既卡又不同步。
                      onChangeStart: (double _) {
                        _hideTimer?.cancel();
                        setState(() => _seeking = true);
                      },
                      onChanged: (double v) {
                        _uiPos.value = Duration(milliseconds: v.round());
                      },
                      onChangeEnd: (double v) async {
                        final Duration t = Duration(milliseconds: v.round());
                        setState(() => _seeking = false);
                        await _player?.seek(t);
                        _armHide();
                      },
                    ),
                  ),
                ),
                SizedBox(
                  width: 46,
                  child: Text(
                    fmtDuration(_dur),
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 11.5,
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

  Widget _topBar(String title) {
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

  // ---------------- 下方内容 ----------------

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
              for (int i = 0; i < d.episodes.length; i++) _epChip(d, i),
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

  /// 集数按钮：正在播的那一集用强调色描边（对齐 lanerc 的选中态）
  Widget _epChip(VideoDetail d, int i) {
    final bool on = _ep == i;
    return GestureDetector(
      onTap: () => _openEpisode(i),
      child: Container(
        width: 96,
        height: 42,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: on ? C.accentSoft : C.chipBg,
          borderRadius: BorderRadius.circular(Metrics.card),
          border: Border.all(
            color: on ? C.accent : C.border,
            width: on ? 1.4 : 1,
          ),
        ),
        child: Text(
          d.episodeLabel(i),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: on ? C.accent : C.text,
            fontSize: 13,
            fontWeight: on ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
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
    t = t
        .replaceAll(RegExp(r'[ \t]+\n'), '\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n');
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
