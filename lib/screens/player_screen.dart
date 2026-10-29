import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../api.dart';
import '../asset_paths.dart';

/// lanerc 风格播放页（M2 皮肤 + 手势）
/// 手势：轻横滑 ±4s / 长横滑 ±15s；竖滑音量亮度；双击播放暂停；长按 2x，上滑 3x，下滑 1.5x。
enum _Mode { idle, pending, speed, seek, vertical }

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    required this.url,
    required this.title,
    this.episodes = const <String>[],
    this.index = 0,
    this.sourceName,
  });

  final String url;
  final String title;

  /// 同一部片子的全部剧集地址（为空时上一集/下一集不可用）
  final List<String> episodes;

  /// 当前是第几集（0 起）
  final int index;

  final String? sourceName;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final Player _player;
  late final VideoController _controller;

  final List<StreamSubscription<dynamic>> _subs = <StreamSubscription<dynamic>>[];

  bool _landscape = false;
  String? _error;
  double _speed = 1.0;

  /// 是否已经真正出画（出过画面就不再显示加载浮层）
  bool _started = false;
  /// 起播超过 10 秒还没出画
  bool _slow = false;
  /// libmpv 正在缓冲（网络抖动或拖动后重新取流）
  bool _buffering = false;
  Timer? _slowTimer;
  /// 进度条/时间文本专用：拖动时是目标位置，否则是真实位置。
  /// 用它做局部重建，替代"整树 setState"——那才是进度条看起来不跟手的根因（节流期间不刷新）。
  final ValueNotifier<Duration> _uiPos = ValueNotifier<Duration>(Duration.zero);
  /// 是否正在手动拖动底部进度条（拖动中只更新显示，松手才真正 seek）
  bool _seekingSlider = false;
  /// 是否已切到 /api/proxy 代理线路（只切一次，避免死循环）
  bool _viaProxy = false;
  /// 拖动时进度条重绘节流
  int _lastSeekUiAt = 0;

  late int _index;
  late String _url;

  bool _controlsVisible = true;
  bool _locked = false;
  Timer? _hideTimer;
  Timer? _tapTimer;

  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;
  bool _playing = false;
  double _vol = 100;
  double _rate = 1.0;

  _Mode _mode = _Mode.idle;
  Offset _startPos = Offset.zero;
  Duration _basePos = Duration.zero;
  Duration _seekTarget = Duration.zero;
  double _baseVolume = 100;
  double _baseBrightness = 1.0;
  double _baseRate = 1.0;
  double _speedRate = 1.0;
  Timer? _pressTimer;
  int _lastHudAt = 0;

  final ValueNotifier<String> _hud = ValueNotifier<String>('');
  Timer? _hudTimer;

  static const List<double> _speeds = <double>[
    0.5,
    0.75,
    1.0,
    1.25,
    1.5,
    2.0,
    3.0,
  ];

  @override
  void initState() {
    super.initState();
    _index = widget.index;
    _url = widget.url;
    _player = Player();
    _applyMpvTuning();
    _controller = VideoController(
      _player,
      configuration: const VideoControllerConfiguration(
        enableHardwareAcceleration: true,
      ),
    );

    _subs.add(_player.stream.error.listen((String e) {
      if (!mounted) return;
      // 直连源站失败时自动走同源代理（和 Web 端 hls.js 的策略一致），只重试一次
      if (!_viaProxy) {
        _viaProxy = true;
        setState(() {
          _error = null;
          _started = false;
          _slow = false;
        });
        _uiPos.value = Duration.zero;
        _showHud('直连失败，正在切换代理线路…', ms: 1600);
        _armSlowTimer(seconds: 12);
        unawaited(_openCurrent());
        return;
      }
      setState(() => _error = e);
    }));
    _subs.add(_player.stream.position.listen((Duration v) {
      _pos = v;
      if (!_seekingSlider && _mode != _Mode.seek) _uiPos.value = v;
      // 真正的"出画"判据是时间轴开始前进。
      // libmpv 的 playing 事件在首帧之前就为 true，用它判断会让加载浮层刚显示就被收掉，
      // 用户看到的就是"一直黑屏、没有任何加载提示"。
      if (!_started && v > const Duration(milliseconds: 250)) {
        _started = true;
        _slow = false;
        _slowTimer?.cancel();
        if (mounted) setState(() {});
      }
    }));
    _subs.add(_player.stream.duration.listen((Duration v) {
      if (!mounted) return;
      setState(() => _dur = v);
    }));
    _subs.add(_player.stream.playing.listen((bool v) {
      if (!mounted) return;
      setState(() => _playing = v);
    }));
    _subs.add(_player.stream.buffering.listen((bool v) {
      if (mounted) setState(() => _buffering = v);
    }));
    _subs.add(_player.stream.volume.listen((double v) => _vol = v));
    _subs.add(_player.stream.rate.listen((double v) => _rate = v));

    unawaited(_openCurrent());
    unawaited(WakelockPlus.enable());
    unawaited(_initBrightness());
    _restartHideTimer();
    // 默认竖屏播放：点全屏键才转横屏。
    // 关键：锁屏放到首帧之后再补一次 —— Android 12+ 在 initState 阶段 Activity 可能还没 attach，
    // 只在 initState 调一次会被系统静默丢弃，表现就是"点播放自己变横屏"。
    unawaited(_lockPortrait());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_lockPortrait());
    });
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    // 起播慢时给个"不是卡死"的交代（10 秒还没出画面就提示换源）
    _armSlowTimer();
  }

  /// 锁竖屏（可被 initState / 首帧后 / 退出全屏复用）
  Future<void> _lockPortrait() {
    return SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
      DeviceOrientation.portraitUp,
    ]);
  }

  /// 起播看门狗：到点还没出画就提示"加载较慢"
  void _armSlowTimer({int seconds = 10}) {
    _slowTimer?.cancel();
    _slowTimer = Timer(Duration(seconds: seconds), () {
      if (mounted && !_started) setState(() => _slow = true);
    });
  }

  /// libmpv 调优：默认缓存很小，起播和 seek 都要重新连源站，
  /// 这就是"同样片源 App 明显比 Web 慢"的主因（Web 走 hls.js + MSE，缓冲 120 秒）。
  /// 用 dynamic 调用 setProperty：media_kit 各版本对 NativePlayer 的导出不完全一致，
  /// 写死类型会让 CI 编译失败，这里失败也只是少了优化，不影响播放。
  void _applyMpvTuning() {
    final Map<String, String> props = <String, String>{
      'cache': 'yes',
      'cache-secs': '60',
      'demuxer-max-bytes': '67108864', // 64MiB
      'demuxer-max-back-bytes': '33554432', // 32MiB
      'demuxer-readahead-secs': '30',
      'hwdec': 'auto-safe',
      'network-timeout': '15',
    };
    unawaited(() async {
      try {
        final dynamic np = _player.platform;
        for (final MapEntry<String, String> e in props.entries) {
          try {
            await np.setProperty(e.key, e.value);
          } catch (_) {
            // 个别属性在当前 libmpv 版本不存在，忽略
          }
        }
      } catch (_) {
        // 拿不到原生播放器（理论上不会），放弃调优
      }
    }());
  }

  /// 打开当前剧集：直连失败过一次就改用代理地址
  Future<void> _openCurrent() async {
    if (!mounted) return;
    final String target = _viaProxy ? Api.i.proxyUrl(_url) : _url;
    await _player.open(Media(target));
  }

  bool get _hasEpisodes => widget.episodes.length > 1;

  String get _displayTitle {
    if (widget.episodes.isEmpty) return widget.title;
    return '${widget.title} · 第${_index + 1}集';
  }

  Future<void> _playIndex(int i) async {
    if (i < 0 || i >= widget.episodes.length) return;
    setState(() {
      _index = i;
      _url = widget.episodes[i];
      _error = null;
      _pos = Duration.zero;
      _dur = Duration.zero;
      _started = false;
      _slow = false;
      _viaProxy = false;
      _seekingSlider = false;
    });
    _uiPos.value = Duration.zero;
    _armSlowTimer();
    await _player.setRate(_speed);
    await _openCurrent();
    _restartHideTimer();
    _showHud('第${i + 1}集');
  }

  Future<void> _initBrightness() async {
    try {
      _baseBrightness = await ScreenBrightness().application;
    } catch (_) {
      _baseBrightness = 1.0;
    }
  }

  @override
  void dispose() {
    _pressTimer?.cancel();
    _hideTimer?.cancel();
    _tapTimer?.cancel();
    _hudTimer?.cancel();
    _slowTimer?.cancel();
    for (final StreamSubscription<dynamic> s in _subs) {
      unawaited(s.cancel());
    }
    _hud.dispose();
    _uiPos.dispose();
    unawaited(WakelockPlus.disable());
    unawaited(_player.dispose());
    unawaited(
      SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
        DeviceOrientation.portraitUp,
      ]),
    );
    unawaited(
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge),
    );
    super.dispose();
  }

  // ---------- UI 辅助 ----------

  Widget _svg(String name, double size, {Color color = Colors.white}) {
    return SvgPicture.asset(
      '${AssetPaths.icons}$name.svg',
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
    );
  }

  Widget _iconBtn(
    String name,
    double size,
    VoidCallback onTap, {
    bool flip = false,
    Color color = Colors.white,
  }) {
    Widget child = _svg(name, size, color: color);
    if (flip) {
      child = Transform.flip(flipX: true, child: child);
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
        child: child,
      ),
    );
  }

  Widget _textBtn(
    String text, {
    bool highlighted = true,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Text(
          text,
          style: TextStyle(
            color: highlighted ? Colors.white : Colors.white54,
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  String _fmt(Duration d) {
    final int h = d.inHours;
    final String m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final String s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  void _showHud(String text, {int ms = 900}) {
    if (!mounted) return;
    _hud.value = text;
    _hudTimer?.cancel();
    _hudTimer = Timer(Duration(milliseconds: ms), () {
      if (_hud.value == text) _hud.value = '';
    });
  }

  void _restartHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted || _locked) return;
      setState(() => _controlsVisible = false);
    });
  }

  void _toggleControls() {
    if (_locked) return;
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _restartHideTimer();
  }

  void _toggleLock() {
    setState(() {
      _locked = !_locked;
      _controlsVisible = !_locked;
    });
    if (!_locked) _restartHideTimer();
    _showHud(_locked ? '已锁定' : '已解锁');
  }

  /// 进入横屏全屏（只由全屏键/横屏控件调用，进播放页不再自动转屏）
  Future<void> _enterFullscreen() async {
    await SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    if (!mounted) return;
    setState(() => _landscape = true);
    _restartHideTimer();
  }

  /// 退出全屏：回到竖屏 + 恢复系统栏
  Future<void> _exitFullscreen() async {
    await SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
      DeviceOrientation.portraitUp,
    ]);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    if (!mounted) return;
    setState(() => _landscape = false);
    _restartHideTimer();
  }

  Future<void> _toggleFullscreen() async {
    if (_landscape) {
      await _exitFullscreen();
    } else {
      await _enterFullscreen();
    }
  }

  // ---------- 手势 ----------

  void _onDown(PointerDownEvent e) {
    if (_locked) return;
    _hideTimer?.cancel();
    _pressTimer?.cancel();
    _mode = _Mode.pending;
    _startPos = e.localPosition;
    _basePos = _pos;
    _seekTarget = _pos;
    _baseVolume = _vol;
    _baseRate = _rate;
    _speedRate = _rate;
    _lastHudAt = 0;
    _pressTimer = Timer(const Duration(milliseconds: 420), () {
      if (!mounted || _mode != _Mode.pending || !_playing) return;
      _mode = _Mode.speed;
      _speedRate = 2.0;
      unawaited(_player.setRate(2.0));
      _showHud('2X快进中');
    });
  }

  void _onMove(PointerMoveEvent e) {
    if (_locked || _mode == _Mode.idle) return;
    final double dx = e.localPosition.dx - _startPos.dx;
    final double dy = e.localPosition.dy - _startPos.dy;

    if (_mode == _Mode.pending) {
      if (dx.abs() <= 12 && dy.abs() <= 12) return;
      _pressTimer?.cancel();
      _pressTimer = null;
      _mode = dx.abs() >= dy.abs() ? _Mode.seek : _Mode.vertical;
    }

    final Size size = MediaQuery.of(context).size;
    final int now = DateTime.now().millisecondsSinceEpoch;

    if (_mode == _Mode.speed) {
      double rate = 2.0;
      if (dy <= -26) {
        rate = 3.0;
      } else if (dy >= 26) {
        rate = 1.5;
      }
      if (rate != _speedRate) {
        _speedRate = rate;
        unawaited(_player.setRate(rate));
        _showHud('${rate}X快进中');
      }
      return;
    }

    if (_mode == _Mode.seek) {
      double secs = (dx / size.width) * 24;
      secs = secs.clamp(-15.0, 15.0).toDouble();
      final Duration raw =
          _basePos + Duration(milliseconds: (secs * 1000).round());
      _seekTarget = Duration(
        milliseconds:
            raw.inMilliseconds.clamp(0, _dur.inMilliseconds).toInt(),
      );
      if (now - _lastHudAt > 120) {
        _lastHudAt = now;
        final String sign = secs >= 0 ? '+' : '';
        _showHud('$sign${secs.round()}s · ${_fmt(_seekTarget)}', ms: 600);
      }
      // 进度条跟手：只更新进度条自己的 notifier，不重建整棵树
      if (now - _lastSeekUiAt > 40) {
        _lastSeekUiAt = now;
        _uiPos.value = _seekTarget;
      }
      return;
    }

    if (_mode == _Mode.vertical) {
      final double ratio = -dy / size.height;
      if (_startPos.dx > size.width / 2) {
        final double v =
            (_baseVolume + ratio * 130).clamp(0.0, 100.0).toDouble();
        unawaited(_player.setVolume(v));
        if (now - _lastHudAt > 120) {
          _lastHudAt = now;
          _showHud('音量 ${v.round()}%', ms: 600);
        }
      } else {
        final double b =
            (_baseBrightness + ratio * 1.3).clamp(0.05, 1.0).toDouble();
        unawaited(ScreenBrightness().setApplicationScreenBrightness(b));
        if (now - _lastHudAt > 120) {
          _lastHudAt = now;
          _showHud('亮度 ${(b * 100).round()}%', ms: 600);
        }
      }
    }
  }

  void _end() {
    _pressTimer?.cancel();
    _pressTimer = null;

    if (_mode == _Mode.speed) {
      unawaited(_player.setRate(_baseRate));
      _showHud('已恢复');
    } else if (_mode == _Mode.seek) {
      // 先把显示对齐到目标位置再发 seek：否则松手瞬间进度条会先"回跳"到旧位置再跳回来
      _pos = _seekTarget;
      _uiPos.value = _seekTarget;
      unawaited(_player.seek(_seekTarget));
    } else if (_mode == _Mode.pending) {
      _handleTap();
    }
    _mode = _Mode.idle;
    // 拖动结束后让进度条回到真实播放位置
    if (mounted) setState(() {});
    if (_controlsVisible && !_locked) _restartHideTimer();
  }

  void _handleTap() {
    if (_locked) return;
    if (_tapTimer != null) {
      _tapTimer!.cancel();
      _tapTimer = null;
      unawaited(_player.playOrPause());
      _showHud(_playing ? '暂停' : '播放');
      return;
    }
    _tapTimer = Timer(const Duration(milliseconds: 260), () {
      _tapTimer = null;
      _toggleControls();
    });
  }

  Future<void> _showSpeedSheet() async {
    _hideTimer?.cancel();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF15171E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (BuildContext ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
            child: Wrap(
              spacing: 10,
              runSpacing: 10,
              children: _speeds
                  .map((double s) => ChoiceChip(
                        label: Text('${s}x'),
                        selected: _speed == s,
                        onSelected: (_) {
                          unawaited(_player.setRate(s));
                          setState(() => _speed = s);
                          Navigator.of(ctx).pop();
                        },
                      ))
                  .toList(),
            ),
          ),
        );
      },
    );
    _restartHideTimer();
  }

  Future<void> _showEpisodeSheet() async {
    _hideTimer?.cancel();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF15171E),
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
                    const Text(
                      '选集',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (widget.sourceName != null)
                      Text(
                        widget.sourceName!,
                        style: const TextStyle(color: Colors.white38, fontSize: 11),
                      ),
                    const Spacer(),
                    Text(
                      '共 ${widget.episodes.length} 集',
                      style: const TextStyle(color: Colors.white38, fontSize: 11),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                if (widget.episodes.isEmpty)
                  const Text(
                    '没有剧集数据',
                    style: TextStyle(color: Colors.white54, fontSize: 12),
                  )
                else
                  Flexible(
                    child: SingleChildScrollView(
                      child: Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: <Widget>[
                          for (int i = 0; i < widget.episodes.length; i++)
                            GestureDetector(
                              onTap: () {
                                Navigator.of(ctx).pop();
                                unawaited(_playIndex(i));
                              },
                              child: Container(
                                width: 78,
                                height: 38,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: i == _index
                                      ? const Color(0xFF2F6BFF)
                                      : const Color(0x14FFFFFF),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: i == _index
                                        ? const Color(0xFF2F6BFF)
                                        : const Color(0x1FFFFFFF),
                                  ),
                                ),
                                child: Text(
                                  '第${i + 1}集',
                                  style: TextStyle(
                                    color: i == _index ? Colors.white : Colors.white70,
                                    fontSize: 13,
                                    fontWeight: i == _index
                                        ? FontWeight.w600
                                        : FontWeight.w400,
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
    _restartHideTimer();
  }

  // ---------- 构建 ----------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: <Widget>[
          Center(
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: Video(
                controller: _controller,
                controls: NoVideoControls,
              ),
            ),
          ),
          Positioned.fill(
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: _onDown,
              onPointerMove: _onMove,
              onPointerUp: (PointerUpEvent e) => _end(),
              onPointerCancel: (PointerCancelEvent e) => _end(),
              child: const SizedBox.expand(),
            ),
          ),
          _buildLoading(),
          _buildTopBar(),
          _buildBottomBar(),
          _buildLockButton(),
          if (_error != null) _buildError(),
          _buildHud(),
        ],
      ),
    );
  }

  /// 起播/缓冲浮层：黑屏期间明确告知"在加载"，避免误判资源失效。
  /// 做成整屏压暗 + 居中大字：之前只有一个小半透明方块，叠在黑色视频上几乎看不见。
  Widget _buildLoading() {
    final bool show = !_started || _buffering;
    if (!show || _error != null) return const SizedBox.shrink();
    final String text = _buffering && _started
        ? '缓冲中…'
        : (_slow ? '加载较慢，可换一集或换源' : '正在加载…');
    return Positioned.fill(
      child: IgnorePointer(
        child: ColoredBox(
          color: const Color(0x4D000000),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const SizedBox(
                  width: 34,
                  height: 34,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.6,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  text,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    shadows: <Shadow>[
                      Shadow(color: Color(0x99000000), blurRadius: 6),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      child: IgnorePointer(
        ignoring: !_controlsVisible || _locked,
        child: AnimatedOpacity(
          opacity: _controlsVisible && !_locked ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          child: Container(
            padding: EdgeInsets.only(
              top: MediaQuery.of(context).padding.top + 6,
              left: 6,
              right: 8,
              bottom: 10,
            ),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[Color(0x73000000), Color(0x1A000000), Colors.transparent],
                stops: <double>[0, 0.55, 1],
              ),
            ),
            child: Row(
              children: <Widget>[
                _iconBtn('video_back', 22, () => Navigator.of(context).maybePop()),
                const SizedBox(width: 2),
                Expanded(
                  child: Text(
                    _displayTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      shadows: <Shadow>[
                        Shadow(color: Color(0x66000000), blurRadius: 4),
                      ],
                    ),
                  ),
                ),
                _iconBtn('floating', 22, () => _showHud('悬浮窗将在后续版本接入')),
                _iconBtn('airplay', 22, () => _showHud('投屏将在后续版本接入')),
                _iconBtn('more', 22, _showEpisodeSheet),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: IgnorePointer(
        ignoring: !_controlsVisible || _locked,
        child: AnimatedOpacity(
          opacity: _controlsVisible && !_locked ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          child: Container(
            padding: EdgeInsets.only(
              left: 10,
              right: 10,
              bottom: MediaQuery.of(context).padding.bottom + 8,
              top: 30,
            ),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[
                  Colors.transparent,
                  Color(0xCC000000),
                  Color(0xF2000000),
                ],
              ),
            ),
            child: _landscape ? _landscapeControls() : _portraitControls(),
          ),
        ),
      ),
    );
  }

  /// 进度条（横竖屏共用）
  ///
  /// 之前的坑：Slider 是"受控组件"，value 绑的是 200ms 节流后的播放位置，而 onChanged
  /// 每一帧都在发 seek —— 手指滑到哪、滑块被拉回旧位置，越拖越乱，还让 libmpv 反复重建缓冲。
  /// 现在：拖动期间只更新本地显示（_uiPos + _seekingSlider），松手才发一次 seek。
  Widget _progressBlock({required bool withFullscreen}) {
    return ValueListenableBuilder<Duration>(
      valueListenable: _uiPos,
      builder: (BuildContext context, Duration shown, Widget? _) {
        final double max =
            _dur.inMilliseconds > 0 ? _dur.inMilliseconds.toDouble() : 1.0;
        final double value = shown.inMilliseconds.toDouble().clamp(0.0, max);
        return Row(
          children: <Widget>[
            Text(
              _fmt(shown),
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
            Expanded(
              child: SliderTheme(
                data: SliderThemeData(
                  trackHeight: 3,
                  activeTrackColor: Colors.white,
                  inactiveTrackColor: Colors.white24,
                  thumbColor: Colors.white,
                  overlayColor: Colors.white24,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                ),
                child: Slider(
                  value: value,
                  max: max,
                  onChangeStart: (double v) {
                    _seekingSlider = true;
                    _hideTimer?.cancel();
                  },
                  onChanged: (double v) {
                    _uiPos.value = Duration(
                      milliseconds: v.round().clamp(0, max.round()).toInt(),
                    );
                  },
                  onChangeEnd: (double v) {
                    final Duration t = Duration(milliseconds: v.round());
                    _seekingSlider = false;
                    _pos = t;
                    _uiPos.value = t;
                    unawaited(_player.seek(t));
                    _restartHideTimer();
                  },
                ),
              ),
            ),
            Text(
              _fmt(_dur),
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
            if (withFullscreen) _iconBtn('full', 22, _toggleFullscreen),
          ],
        );
      },
    );
  }

  Widget _landscapeControls() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _progressBlock(withFullscreen: false),
        Row(
          children: <Widget>[
            _iconBtn(
              'next',
              24,
              () {
                if (_hasEpisodes && _index > 0) {
                  unawaited(_playIndex(_index - 1));
                } else {
                  _showHud('已经是第一集');
                }
              },
              flip: true,
            ),
            _iconBtn(_playing ? 'pause' : 'right', 30, () {
              unawaited(_player.playOrPause());
              _restartHideTimer();
            }),
            _iconBtn(
              'next',
              24,
              () {
                if (_hasEpisodes && _index < widget.episodes.length - 1) {
                  unawaited(_playIndex(_index + 1));
                } else {
                  _showHud('已经是最后一集');
                }
              },
            ),
            const SizedBox(width: 8),
            const Spacer(),
            _textBtn('${_speed}x', onTap: _showSpeedSheet),
            _textBtn('选集', onTap: _showEpisodeSheet),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => unawaited(_exitFullscreen()),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                child: Icon(
                  Icons.fullscreen_exit_rounded,
                  size: 22,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _portraitControls() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _progressBlock(withFullscreen: true),
      ],
    );
  }

  Widget _buildLockButton() {
    final bool visible = _locked || _controlsVisible;
    if (!visible) return const SizedBox.shrink();
    return Positioned(
      right: 12,
      top: 0,
      bottom: 0,
      child: Center(
        child: GestureDetector(
          onTap: _toggleLock,
          child: Container(
            width: 44,
            height: 44,
            decoration: const BoxDecoration(
              color: Color(0x66000000),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: _svg(_locked ? 'unlock' : 'lock', 20),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildError() {
    return Positioned(
      left: 16,
      right: 16,
      top: 70,
      child: Material(
        color: const Color(0xD9B3261E),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Text(
            '播放失败：$_error',
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ),
      ),
    );
  }

  Widget _buildHud() {
    return Positioned.fill(
      child: IgnorePointer(
        child: Center(
          child: ValueListenableBuilder<String>(
            valueListenable: _hud,
            builder: (BuildContext context, String v, Widget? _) {
              return AnimatedOpacity(
                opacity: v.isEmpty ? 0 : 1,
                duration: const Duration(milliseconds: 150),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    v,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
