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
import '../history_store.dart';
import '../models.dart';
import '../mpv_tuning.dart';

/// lanerc 风格播放页（全屏）
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
    this.player,
    this.controller,
    this.onEpisodeChanged,

    /// 从详情页点全屏进入：横屏上下文自建 Player+VideoController（绕开共享 Surface 黑屏）。
    /// 此时不传 player/controller，PlayerScreen 自己开流，退出时回传 index/进度给详情页续播。
    this.startFullscreen = false,

    /// 起播定位（续播用）：开流后自动 seek 到这个位置再播。
    this.startAt,

    /// 用于写入「观看记录」的条目信息（来源/片名/封面）。不传则不记录历史。
    this.item,

    /// 退出全屏（任何方式：返回键/返回按钮/退出按钮）时回调，回传当前集与进度，
    /// 详情页据此续播。用 dispose 回调而非拦截 pop，避免不同 Flutter 版本 API 差异。
    this.onExit,
  });

  final String url;
  final String title;
  final List<String> episodes;
  final int index;
  final String? sourceName;
  final Player? player;
  final VideoController? controller;
  final ValueChanged<int>? onEpisodeChanged;

  /// 从详情页点全屏进入：横屏上下文自建 Player+VideoController，退出回传 index/进度。
  final bool startFullscreen;

  /// 起播定位（续播用）：开流后先 seek 到这里再播。
  final Duration? startAt;

  /// 写入「观看记录」用的条目信息（来源/片名/封面）；为空则不记录。
  final SearchItem? item;

  /// 退出回调：回传当前集与进度（详情页续播用）。
  final void Function(int index, Duration position, Duration duration)? onExit;

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

  bool _started = false;
  bool _slow = false;
  bool _buffering = false;
  Timer? _slowTimer;

  /// 画面比例：0 = 铺满(cover)，1 = 原始(contain)，2 = 16:9
  int _fitMode = 0;

  final ValueNotifier<Duration> _uiPos = ValueNotifier<Duration>(Duration.zero);
  bool _seekingSlider = false;
  bool _viaProxy = false;
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

  /// 观看记录：每 10s 写一次进度；退出时再补一次
  Timer? _histTimer;

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
    // 先发横屏/沉浸请求，再建 Player + VideoController，
    // 尽量让 media_kit 的原生 Surface 一开始就按横屏尺寸创建（避免旋转后黑屏）。
    if (widget.startFullscreen) {
      unawaited(
        SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]),
      );
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky));
    }
    _index = widget.index;
    _url = widget.url;
    final bool own = widget.player == null;
    _player = widget.player ?? Player();
    if (own) {
      applyMpvTuning(_player);
      _controller = VideoController(
        _player,
        configuration: const VideoControllerConfiguration(
          enableHardwareAcceleration: true,
        ),
      );
    } else {
      _controller = widget.controller!;
    }

    _subs.add(_player.stream.error.listen((String e) {
      if (!mounted) return;
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

    if (own) {
      unawaited(_startInitial());
    } else {
      _pos = _player.state.position;
      _dur = _player.state.duration;
      _playing = _player.state.playing;
      _started = _pos > Duration.zero;
      _uiPos.value = _pos;
    }
    unawaited(WakelockPlus.enable());
    unawaited(_initBrightness());
    _restartHideTimer();
    if (widget.startFullscreen) {
      // 横屏请求已在 initState 最前面发出，这里只标记状态
      _landscape = true;
    } else if (own) {
      unawaited(_lockPortrait());
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_lockPortrait());
      });
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    } else {
      _landscape = true;
      unawaited(
        SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]),
      );
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky));
    }
    _armSlowTimer();
    if (own && widget.item != null) _armHist();
  }

  Future<void> _lockPortrait() {
    return SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
      DeviceOrientation.portraitUp,
    ]);
  }

  void _armSlowTimer({int seconds = 10}) {
    _slowTimer?.cancel();
    _slowTimer = Timer(Duration(seconds: seconds), () {
      if (!mounted || _started) return;
      // 看门狗：直连一直没出画，自动切代理重试一次；
      // 代理再等不到才提示"加载较慢"，避免永远卡在 00:00 转圈。
      if (!_viaProxy) {
        _viaProxy = true;
        setState(() {
          _error = null;
          _started = false;
          _slow = false;
        });
        _uiPos.value = Duration.zero;
        _showHud('起播较慢，切换代理线路重试…', ms: 1600);
        unawaited(_openCurrent());
        _armSlowTimer(seconds: 12);
        return;
      }
      setState(() => _slow = true);
    });
  }

  /// 起播：全新播放器自己开流；带 startAt 时先定位再播（从详情页续播）。
  Future<void> _startInitial() async {
    final Duration? at = widget.startAt;
    final bool resume = at != null && at > const Duration(seconds: 1);
    await _openCurrent(play: !resume);
    if (at == null || at <= const Duration(seconds: 1)) return;
    try {
      await _player.seek(at);
    } catch (_) {}
    try {
      await _player.play();
    } catch (_) {}
  }

  Future<void> _openCurrent({bool play = true}) async {
    if (!mounted) return;
    final String target = _viaProxy ? Api.i.proxyUrl(_url) : _url;
    try {
      await _player.open(Media(target), play: play);
    } catch (e) {
      // open 抛异常时 stream.error 不一定触发，这里兜一次：直连失败切代理
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
        await _openCurrent(play: play);
        return;
      }
      if (mounted) setState(() => _error = '$e');
    }
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
    widget.onEpisodeChanged?.call(i);
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

  // ---------- 观看记录 ----------

  void _armHist() {
    _histTimer?.cancel();
    _histTimer = Timer.periodic(const Duration(seconds: 10), (_) => _recordHist());
  }

  void _recordHist() {
    final SearchItem? it = widget.item;
    if (it == null) return;
    // 没真正开始播（位置为 0）不落记录，避免污染观看列表
    if (_pos.inMilliseconds <= 0) return;
    unawaited(HistoryStore.record(
      sourceKey: it.sourceKey,
      vodId: it.vodId,
      name: it.name,
      pic: it.pic,
      sourceName: it.sourceName,
      index: _index,
      posMs: _pos.inMilliseconds,
      durMs: _dur.inMilliseconds,
    ));
  }

  /// 退出时回传给详情页：当前集 + 播放进度 + 总时长
  @override
  void dispose() {
    _pressTimer?.cancel();
    _hideTimer?.cancel();
    _tapTimer?.cancel();
    _hudTimer?.cancel();
    _slowTimer?.cancel();
    _histTimer?.cancel();
    _recordHist();
    // 任何方式退出（返回键/返回按钮/退出按钮）都会走到 dispose，
    // 在这里回传当前集与进度，详情页据此续播。
    widget.onExit?.call(_index, _pos, _dur);
    for (final StreamSubscription<dynamic> s in _subs) {
      unawaited(s.cancel());
    }
    _hud.dispose();
    _uiPos.dispose();
    if (widget.player == null) {
      unawaited(WakelockPlus.disable());
      unawaited(_player.dispose());
    }
    unawaited(
      SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
        DeviceOrientation.portraitUp,
      ]),
    );
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
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

  /// 画面比例切换：铺满 → 原始 → 16:9
  void _cycleFit() {
    setState(() => _fitMode = (_fitMode + 1) % 3);
    _showHud(_fitMode == 0
        ? '画面：铺满'
        : _fitMode == 1
            ? '画面：原始比例'
            : '画面：16:9');
    _restartHideTimer();
  }

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

  Future<void> _exitFullscreen() async {
    // 从详情页进入的全屏：退出 = 回到详情页（dispose 回传进度）
    if (widget.startFullscreen) {
      if (mounted) Navigator.of(context).maybePop();
      return;
    }
    if (widget.player != null) {
      if (mounted) Navigator.of(context).maybePop();
      return;
    }
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
      _pos = _seekTarget;
      _uiPos.value = _seekTarget;
      unawaited(_player.seek(_seekTarget));
    } else if (_mode == _Mode.pending) {
      _handleTap();
    }
    _mode = _Mode.idle;
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
                                      ? const Color(0xFF13BFD2)
                                      : const Color(0x14FFFFFF),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: i == _index
                                        ? const Color(0xFF13BFD2)
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

  /// 全屏画面：铺满(cover) / 原始(contain) / 16:9
  Widget _videoLayer() {
    final Widget v = Video(
      controller: _controller,
      controls: NoVideoControls,
      fit: _fitMode == 1 ? BoxFit.contain : BoxFit.cover,
    );
    if (_fitMode == 2) {
      return Center(
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: Video(
            controller: _controller,
            controls: NoVideoControls,
            fit: BoxFit.contain,
          ),
        ),
      );
    }
    // cover 时超出屏幕的部分裁掉，避免画到屏幕外
    return ClipRect(child: SizedBox.expand(child: v));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: <Widget>[
          Positioned.fill(child: _videoLayer()),
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
            if (withFullscreen) ...<Widget>[
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _cycleFit,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                  child: Icon(Icons.aspect_ratio_rounded, size: 20, color: Colors.white),
                ),
              ),
              _iconBtn('full', 22, _toggleFullscreen),
            ],
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
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _cycleFit,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                child: Icon(Icons.aspect_ratio_rounded, size: 22, color: Colors.white),
              ),
            ),
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
