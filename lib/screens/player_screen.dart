import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

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
    _controller = VideoController(
      _player,
      configuration: const VideoControllerConfiguration(
        enableHardwareAcceleration: true,
      ),
    );

    _subs.add(_player.stream.error.listen((String e) {
      if (mounted) setState(() => _error = e);
    }));
    _subs.add(_player.stream.position.listen((Duration v) => _pos = v));
    _subs.add(_player.stream.duration.listen((Duration v) => _dur = v));
    _subs.add(_player.stream.playing.listen((bool v) => _playing = v));
    _subs.add(_player.stream.volume.listen((double v) => _vol = v));
    _subs.add(_player.stream.rate.listen((double v) => _rate = v));

    unawaited(_player.open(Media(widget.url)));
    unawaited(WakelockPlus.enable());
    unawaited(_initBrightness());
    _restartHideTimer();
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
    });
    await _player.setRate(_speed);
    await _player.open(Media(_url));
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
    for (final StreamSubscription<dynamic> s in _subs) {
      unawaited(s.cancel());
    }
    _hud.dispose();
    unawaited(WakelockPlus.disable());
    unawaited(_player.dispose());
    unawaited(
      SystemChrome.setPreferredOrientations(const <DeviceOrientation>[]),
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

  Future<void> _toggleFullscreen() async {
    if (_landscape) {
      await SystemChrome.setPreferredOrientations(
        const <DeviceOrientation>[DeviceOrientation.portraitUp],
      );
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } else {
      await SystemChrome.setPreferredOrientations(
        const <DeviceOrientation>[
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ],
      );
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
    if (!mounted) return;
    setState(() => _landscape = !_landscape);
    _restartHideTimer();
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
      unawaited(_player.seek(_seekTarget));
    } else if (_mode == _Mode.pending) {
      _handleTap();
    }
    _mode = _Mode.idle;
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
          _buildTopBar(),
          _buildBottomBar(),
          _buildLockButton(),
          if (_error != null) _buildError(),
          _buildHud(),
        ],
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

  Widget _progressRow() {
    final double rawMax = _dur.inMilliseconds.toDouble();
    final double max = rawMax > 0 ? rawMax : 1.0;
    final double value = _pos.inMilliseconds.toDouble().clamp(0.0, max);

    return Row(
      children: <Widget>[
        Text(
          _fmt(_pos),
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
              onChanged: (double v) =>
                  _player.seek(Duration(milliseconds: v.round())),
            ),
          ),
        ),
        Text(
          _fmt(_dur),
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
      ],
    );
  }

  Widget _landscapeControls() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _progressRow(),
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
            Expanded(child: _danmakuPill()),
            _textBtn('${_speed}x', onTap: _showSpeedSheet),
            _textBtn('选集', onTap: _showEpisodeSheet),
          ],
        ),
      ],
    );
  }

  Widget _portraitControls() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(
              _fmt(_pos),
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
                  value: _pos.inMilliseconds
                      .toDouble()
                      .clamp(0.0, _dur.inMilliseconds > 0
                          ? _dur.inMilliseconds.toDouble()
                          : 1.0),
                  max: _dur.inMilliseconds > 0
                      ? _dur.inMilliseconds.toDouble()
                      : 1.0,
                  onChanged: (double v) =>
                      _player.seek(Duration(milliseconds: v.round())),
                ),
              ),
            ),
            Text(
              _fmt(_dur),
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
            _iconBtn('full', 22, _toggleFullscreen),
          ],
        ),
      ],
    );
  }

  Widget _danmakuPill() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _showHud('弹幕未开启'),
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: const Color(0x1FFFFFFF),
          borderRadius: BorderRadius.circular(17),
        ),
        child: Row(
          children: <Widget>[
            const Expanded(
              child: Text(
                '发送一条友善的弹幕吧~',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ),
            _svg('dm_open', 18, color: Colors.white70),
          ],
        ),
      ),
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
