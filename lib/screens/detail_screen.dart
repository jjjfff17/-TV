import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:screen_brightness/screen_brightness.dart';

import '../api.dart';
import '../history_store.dart';
import '../models.dart';
import '../store.dart';
import '../theme.dart';
import '../ui.dart';

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

  // ---------- 内嵌播放器（video_player / ExoPlayer：原生分段流，拖动秒开） ----------
  VideoPlayerController? _player;

  int? _ep; // 当前集；null = 还没开始播（显示封面 + 播放键）
  int _loadedIndex = -1; // 播放器里当前已装载的集（用于判断能否直接 play）
  bool _fullscreen = false; // 原地全屏：只放大视频盒子，不新建播放器、不重新开流
  bool _viaProxy = false;
  bool _fav = false;
  bool _controls = true;
  bool _seeking = false;
  bool _descOpen = false;
  int _fitMode = 0; // 0=原比例(contain, 默认) 1=自适应屏幕(智能铺满)；默认原比例

  // ---------- 手势状态 ----------
  final ValueNotifier<Duration?> _seekPreview = ValueNotifier<Duration?>(null);
  final ValueNotifier<int> _seekDelta = ValueNotifier<int>(0); // 拖动时的相对秒数（+快进 / -快退）
  final ValueNotifier<int> _vMode = ValueNotifier<int>(-1); // -1=无 0=音量 1=亮度
  final ValueNotifier<double> _vValue = ValueNotifier<double>(0); // 当前音量/亮度 0..1
  final ValueNotifier<double> _speed = ValueNotifier<double>(0); // 0=无长按变速
  double _videoAspect = 0; // 0=未知；>0=视频宽高比（来自控制器 value.aspectRatio）
  double _rateBefore = 1.0;
  Duration _dragStartPos = Duration.zero;
  double _dragStartX = 0; // 横滑起点 X，用于累计位移（修复"有动画但进度条不走"）
  bool _vDraggingY = false; // 竖向手势是否进行中（防止复位定时误关 HUD）
  bool _longPressing = false; // 长按变速进行中
  double _longStartY = 0; // 长按起点 Y，用于判断上滑(3.0x)/下滑(1.5x)


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
    if (_fullscreen) {
      // 全屏状态下页面被直接关掉时，把屏幕方向与系统栏恢复，避免下一次进来还是横屏
      unawaited(SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
        DeviceOrientation.portraitUp,
      ]));
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    }
    _pos.dispose();
    _dur.dispose();
    _playing.dispose();
    _buffering.dispose();
    _started.dispose();
    _slow.dispose();
    _pErr.dispose();
    _seekPreview.dispose();
    _seekDelta.dispose();
    _vMode.dispose();
    _vValue.dispose();
    _speed.dispose();
    final VideoPlayerController? p = _player;
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

  // ---------------- 播放器（video_player / ExoPlayer：原生分段流，拖动秒开） ----------------

  int _reqSeq = 0; // 播放请求序号：防止预载与换集并发时互相覆盖

  /// 创建并初始化一个控制器；play=false 用于预载（只装载不播）。
  /// 直连失败自动走代理兜底一次（_viaProxy 防止死循环）。
  Future<void> _attach(String url, {bool play = true, int seq = 0}) async {
    final VideoPlayerController c = VideoPlayerController.networkUrl(
      Uri.parse(url),
      videoPlayerOptions: const VideoPlayerOptions(mixWithOthers: false),
    );
    c.addListener(_onTick);
    try {
      await c.initialize();
    } catch (e) {
      if (!_viaProxy) {
        // 直连失败 → 代理兜底（仅一次）
        _viaProxy = true;
        unawaited(c.dispose());
        final VideoPlayerController c2 = VideoPlayerController.networkUrl(
          Uri.parse(Api.i.proxyUrl(url)),
          videoPlayerOptions: const VideoPlayerOptions(mixWithOthers: false),
        );
        c2.addListener(_onTick);
        try {
          await c2.initialize();
        } catch (e2) {
          unawaited(c2.dispose());
          _pErr.value = '$e2';
          return;
        }
        if (seq != 0 && seq != _reqSeq) {
          unawaited(c2.dispose());
          return;
        }
        _replacePlayer(c2);
        if (mounted) setState(() {});
        if (play) await _startPlay();
        return;
      }
      _pErr.value = '$e';
      return;
    }
    if (seq != 0 && seq != _reqSeq) {
      unawaited(c.dispose());
      return;
    }
    _replacePlayer(c);
    if (mounted) setState(() {});
    if (play) await _startPlay();
  }

  void _replacePlayer(VideoPlayerController next) {
    final VideoPlayerController? old = _player;
    _player = next;
    if (old != null && old != next) {
      unawaited(old.dispose());
    }
  }

  Future<void> _startPlay() async {
    await _player?.play();
    unawaited(WakelockPlus.enable());
    _armHist();
  }

  /// 统一从控制器 value 同步到各 ValueNotifier（video_player 用 addListener 而非流）。
  void _onTick() {
    final VideoPlayerController? p = _player;
    if (p == null || !p.value.isInitialized) return;
    if (!_seeking) _pos.value = p.value.position;
    _dur.value = p.value.duration;
    _playing.value = p.value.isPlaying;
    _buffering.value = p.value.isBuffering;
    if (p.value.aspectRatio > 0) {
      final double a = p.value.aspectRatio;
      if ((_videoAspect - a).abs() > 0.01) {
        _videoAspect = a;
        if (mounted) setState(() {});
      }
    }
    // 出画判据：时间轴开始前进
    if (!_started.value && p.value.position > const Duration(milliseconds: 250)) {
      _started.value = true;
      _slow.value = false;
      _slowTimer?.cancel();
    }
    if (p.value.hasError && _pErr.value == null) {
      _pErr.value = p.value.errorDescription ?? '播放出错';
    }
  }

  Future<void> _preload() async {
    final VideoDetail? d = _detail;
    if (d == null || d.episodes.isEmpty) return;
    if (_loadedIndex >= 0) return;
    final int seq = ++_reqSeq;
    try {
      await _attach(d.episodes[0], play: false, seq: seq);
      if (seq == _reqSeq) _loadedIndex = 0;
    } catch (_) {
      // 预载失败不影响正常播放，点播放键时会重新 attach
    }
  }

  // 代理兜底逻辑已并入 _attach（直连失败自动走 Api.i.proxyUrl 重试一次）。

  Future<void> _openEpisode(int i) async {
    final VideoDetail? d = _detail;
    if (d == null || i < 0 || i >= d.episodes.length) return;
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
    final int seq = ++_reqSeq;
    // 已装载同一集且未出错：直接播放（不重新开流）；否则重建控制器
    if (_loadedIndex == i && _player != null && !_player!.value.hasError) {
      unawaited(_startPlay());
      return;
    }
    try {
      await _attach(d.episodes[i], play: true, seq: seq);
      if (seq == _reqSeq) _loadedIndex = i;
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

  /// 双击：播放/暂停切换
  Future<void> _togglePlayPause() async {
    if (_ep == null) return;
    await _playOrPause();
  }

  Future<void> _playOrPause() async {
    final VideoPlayerController? p = _player;
    if (p == null || !p.value.isInitialized) return;
    if (p.value.isPlaying) {
      await p.pause();
    } else {
      await p.play();
    }
  }

  // ---------- 手势：横滑拖动、竖滑音量/亮度、长按变速（2.0x / 上滑 3.0x / 下滑 1.5x） ----------

  void _onHStart(DragStartDetails d) {
    _hideTimer?.cancel();
    setState(() {
      _controls = true;
      _seeking = true;
    });
    _dragStartPos = _pos.value;
    _dragStartX = d.localPosition.dx;
    _seekPreview.value = _pos.value;
  }

  void _onHUpdate(DragUpdateDetails d) {
    final double w = MediaQuery.of(context).size.width;
    // 累计位移（右滑为正=快进，左滑为负=快退），半屏 ≈ 60s
    final double dxTotal = d.localPosition.dx - _dragStartX;
    final double frac = dxTotal / (w * 0.5);
    final int deltaSec = (frac * 60).round();
    Duration target = _dragStartPos + Duration(seconds: deltaSec);
    if (target < Duration.zero) {
      target = Duration.zero;
    } else if (_dur.value > Duration.zero && target > _dur.value) {
      target = _dur.value;
    }
    _seekPreview.value = target;
    _seekDelta.value = deltaSec;
    _pos.value = target; // 拖动时实时移动进度条（真正 seek 在 _onHEnd 执行）
  }

  void _onHEnd(DragEndDetails d) {
    final Duration? t = _seekPreview.value;
    _seekPreview.value = null;
    _seekDelta.value = 0;
    setState(() => _seeking = false);
    if (t != null) unawaited(_player?.seekTo(t));
    _armHide();
  }

  void _onVStart(DragStartDetails d) {
    if (_longPressing) return; // 长按时由 onLongPressMoveUpdate 接管，不触发音量/亮度
    _vDraggingY = true;
    final double w = MediaQuery.of(context).size.width;
    _vMode.value = d.localPosition.dx < w / 2 ? 1 : 0; // 左半屏亮度 / 右半屏音量
    if (_vMode.value == 0) {
      _vValue.value = _player?.value.volume ?? 1.0;
    } else {
      ScreenBrightness()
          .application
          .then((double b) => _vValue.value = b)
          .catchError((Object _) {
        _vValue.value = 1;
      });
    }
  }

  void _onVUpdate(DragUpdateDetails d) {
    if (_longPressing) return; // 长按时由 onLongPressMoveUpdate 接管
    final double dy = d.primaryDelta ?? 0; // 上滑为负 → 增大
    double v = _vValue.value - dy * (_vMode.value == 0 ? 0.004 : 0.005);
    v = v.clamp(0.0, 1.0);
    _vValue.value = v;
    if (_vMode.value == 0) {
      unawaited(_player?.setVolume(v));
    } else {
      unawaited(ScreenBrightness()
          .setApplicationScreenBrightness(v)
          .catchError((Object _) => null));
    }
  }

  void _onVEnd(DragEndDetails d) {
    _vDraggingY = false;
    Future.delayed(const Duration(milliseconds: 600), () {
      // 仅当没有新的竖向手势开始时才复位 HUD
      if (mounted && !_vDraggingY) _vMode.value = -1;
    });
  }

  void _onLongStart(LongPressStartDetails d) {
    _longPressing = true;
    _rateBefore = _player?.value.playbackSpeed ?? 1.0;
    _longStartY = d.localPosition.dy;
    _vMode.value = -1; // 关掉可能已亮的音量/亮度 HUD
    _setLongSpeed(2.0);
  }

  // 长按中上/下滑切换倍速：上滑=3.0x，回正=2.0x，下滑=1.5x。
  // 用 onLongPressMoveUpdate 而非竖向拖拽，确保长按期间移动一定能触发。
  void _onLongMove(LongPressMoveUpdateDetails d) {
    final double dy = _longStartY - d.localPosition.dy; // 上滑为正
    if (dy > 16) {
      _setLongSpeed(3.0);
    } else if (dy < -16) {
      _setLongSpeed(1.5);
    } else {
      _setLongSpeed(2.0);
    }
  }

  void _onLongEnd(LongPressEndDetails d) {
    _longPressing = false;
    unawaited(_player?.setPlaybackSpeed(_rateBefore));
    _speed.value = 0;
  }

  /// 长按变速：仅在倍率变化时调用 setRate，避免每帧重复下发。
  void _setLongSpeed(double r) {
    if ((_player?.value.playbackSpeed ?? 1.0) != r) {
      unawaited(_player?.setPlaybackSpeed(r));
    }
    _speed.value = r;
  }

  /// 播放框宽高比：全屏=整屏；内嵌=16:9 盒子
  double _boxAspect() {
    final double w = MediaQuery.of(context).size.width;
    final double h = _fullscreen ? MediaQuery.of(context).size.height : w * 9 / 16;
    return w / h;
  }

  /// 自适应模式填充方式：视频比盒子更宽 → cover 铺满（贴底保字幕）；否则 contain 不裁切
  BoxFit _adaptiveBoxFit() {
    if (_videoAspect <= 0) return BoxFit.contain; // 未知宽高比时保守用原比例
    final double boxAspect = _boxAspect();
    return _videoAspect > boxAspect ? BoxFit.cover : BoxFit.contain;
  }

  Alignment _playerAlign() {
    if (_fitMode == 0) return Alignment.center; // 原比例：不裁切，居中
    // 自适应：cover 时贴底保字幕，contain 时居中
    final double boxAspect = _boxAspect();
    if (_videoAspect > 0 && _videoAspect > boxAspect) {
      return Alignment.bottomCenter;
    }
    return Alignment.center;
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

  /// 原地全屏（0.5.3 定案）：**不新建页面、不新建播放器、不重新开流**。
  ///
  /// 历史教训：
  /// - 0.5.0 把同一个 `VideoController` 挂到新路由的 `Video` 上 → 黑屏只有声音；
  /// - 0.5.1/0.5.2 改成全屏页新建 `Player` 重新 `open()` → 聚合站 m3u8 会话只认第一条
  ///   连接，第二条开不出来 → 全屏永远 00:00。
  /// 现在只改布局：视频仍在同一个 `Positioned` 里、同一个 `Video` widget、同一条流，
  /// 仅高度从 16:9 变成整屏，因此不存在重新加载，也不存在纹理重建。
  Future<void> _toggleFullscreen() async {
    if (_fullscreen) {
      await _exitFullscreen();
    } else {
      await _enterFullscreen();
    }
  }

  Future<void> _enterFullscreen() async {
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky));
    await SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    if (!mounted) return;
    setState(() {
      _fullscreen = true;
      _controls = true;
    });
    _armHide();
  }

  Future<void> _exitFullscreen() async {
    await SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
      DeviceOrientation.portraitUp,
    ]);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    if (!mounted) return;
    setState(() {
      _fullscreen = false;
      _controls = true;
    });
    _armHide();
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
    return PopScope(
      // 全屏时拦一次返回：先退回竖屏详情，而不是直接退出整个页面
      canPop: !_fullscreen,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (!didPop && _fullscreen) unawaited(_exitFullscreen());
      },
      child: Scaffold(
        backgroundColor: _fullscreen ? Colors.black : C.bg,
        body: LayoutBuilder(
          builder: (BuildContext _, BoxConstraints cons) {
            // 16:9 高度恒定，内容区几何不动；全屏只把视频盒子的高度换成整屏
            final double vh = cons.maxWidth * 9 / 16;
            // 全屏时 maxWidth*9/16 可能大于屏高，内容区必须塌成 0 高，否则约束为负会断言崩溃
            final double contentTop = _fullscreen ? cons.maxHeight : vh;
            return Stack(
              children: <Widget>[
                // 视频层：两种模式下都是同一个 Positioned + 同一个 _videoArea()，
                // 只改高度。Video 元素与原生纹理原地不动 → 不重新开流、不黑屏。
                Positioned(
                  left: 0,
                  top: 0,
                  right: 0,
                  height: _fullscreen ? cons.maxHeight : vh,
                  child: _videoArea(),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  top: contentTop,
                  bottom: 0,
                  // Offstage 而非条件移除：保留列表滚动位置，退出全屏回到原处
                  child: Offstage(
                    offstage: _fullscreen,
                    child: _loading
                        ? _skeletonBody()
                        : _error != null
                            ? _errorView()
                            : _body(),
                  ),
                ),
                if (!_fullscreen && ready) _bottomBar(),
              ],
            );
          },
        ),
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
    final bool hasVid = _player != null && _player!.value.isInitialized;

    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          const ColoredBox(color: C.darkBg),

          // 播放中始终挂这个 Video：全屏只是把它所在的盒子放大，
          // 不做卸载/重挂 → 纹理与流都不重建。
          if (hasVid)
            RepaintBoundary(
              child: ClipRect(
                child: FittedBox(
                  fit: _fitMode == 0 ? BoxFit.contain : _adaptiveBoxFit(),
                  alignment: _playerAlign(),
                  child: SizedBox(
                    width: 1000,
                    height: _videoAspect > 0 ? 1000 / _videoAspect : 1000 * 9 / 16,
                    child: VideoPlayer(_player!),
                  ),
                ),
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
              onDoubleTap: _togglePlayPause,
              onHorizontalDragStart: _onHStart,
              onHorizontalDragUpdate: _onHUpdate,
              onHorizontalDragEnd: _onHEnd,
              onVerticalDragStart: _onVStart,
              onVerticalDragUpdate: _onVUpdate,
              onVerticalDragEnd: _onVEnd,
              onLongPressStart: _onLongStart,
              onLongPressMoveUpdate: _onLongMove,
              onLongPressEnd: _onLongEnd,
              child: const SizedBox.expand(),
            ),

          if (playing) _playerOverlay(),

          if (playing) _gestureHud(),

          if (!playing) _bigPlayButton(),
          if (playing && _controls) _controlsBar(),

          if (!_fullscreen || _controls) _topBar(title, playing),
        ],
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

  /// 手势浮层：拖动进度预览 / 音量亮度 / 长按倍速（与控件栏独立，不随 _controls 隐藏）
  Widget _gestureHud() {
    return Stack(
      children: <Widget>[
        ValueListenableBuilder<Duration?>(
          valueListenable: _seekPreview,
          builder: (BuildContext _, Duration? t, Widget? __) {
            if (t == null) return const SizedBox.shrink();
            final int delta = _seekDelta.value;
            return Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xCC000000),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      delta >= 0 ? Icons.fast_forward_rounded : Icons.fast_rewind_rounded,
                      color: Colors.white,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${delta >= 0 ? '+' : '-'}${fmtDuration(Duration(seconds: delta.abs()))}  ${fmtDuration(t)}',
                      style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
        ValueListenableBuilder<int>(
          valueListenable: _vMode,
          builder: (BuildContext _, int m, Widget? __) {
            if (m < 0) return const SizedBox.shrink();
            final bool isVol = m == 0;
            return Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xCC000000),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      isVol ? Icons.volume_up_rounded : Icons.brightness_6_rounded,
                      color: Colors.white,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    ValueListenableBuilder<double>(
                      valueListenable: _vValue,
                      builder: (BuildContext _, double v, Widget? ___) => Text(
                        '${(v * 100).round()}%',
                        style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
        ValueListenableBuilder<double>(
          valueListenable: _speed,
          builder: (BuildContext _, double s, Widget? __) {
            if (s <= 0) return const SizedBox.shrink();
            return Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xCC000000),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${s.toStringAsFixed(1)}x',
                  style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700),
                ),
              ),
            );
          },
        ),
      ],
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
                  unawaited(_playOrPause());
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
                        await _player?.seekTo(t);
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
                  Tooltip(
                  message: _fitMode == 0 ? '画面：原比例' : '画面：自适应',
                  child: _ctlIcon(
                    _fitMode == 0 ? Icons.aspect_ratio_rounded : Icons.auto_awesome_rounded,
                    () {
                      setState(() => _fitMode = _fitMode == 0 ? 1 : 0);
                      _armHide();
                    },
                    size: 22,
                  ),
                ),
                _ctlIcon(
                  _fullscreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
                  () {
                    unawaited(_toggleFullscreen());
                  },
                  size: 22,
                ),
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
                  // 全屏时先退回竖屏详情，非全屏才退出页面
                  if (_fullscreen) {
                    unawaited(_exitFullscreen());
                  } else {
                    Navigator.of(context).maybePop();
                  }
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
