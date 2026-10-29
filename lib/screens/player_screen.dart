import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// M0 播放页：只验证「能播、能暂停、能拖、能全屏横屏、错误不崩」。
/// 手势（2x/3x/1.5x、±4s、±15s、竖滑）在 M2 实现。
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, required this.url, required this.title});

  final String url;
  final String title;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final Player _player;
  late final VideoController _controller;

  bool _landscape = false;
  String? _error;
  double _speed = 1.0;

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
    _player = Player();
    _controller = VideoController(
      _player,
      configuration: const VideoControllerConfiguration(
        enableHardwareAcceleration: true,
      ),
    );

    _player.stream.error.listen((String e) {
      if (mounted) setState(() => _error = e);
    });

    _player.open(Media(widget.url));
  }

  @override
  void dispose() {
    // 必须释放，否则切集/退出会泄漏解码器（CL-NAT-07）
    _player.dispose();
    SystemChrome.setPreferredOrientations(const <DeviceOrientation>[]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
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
    if (mounted) setState(() => _landscape = !_landscape);
  }

  String _fmt(Duration d) {
    final int h = d.inHours;
    final String m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final String s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        top: !_landscape,
        bottom: !_landscape,
        left: false,
        right: false,
        child: Stack(
          children: <Widget>[
            Center(
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Video(controller: _controller, controls: NoVideoControls),
              ),
            ),
            Positioned(
              left: 12,
              top: 12,
              child: Text(
                widget.title,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),
            if (_error != null)
              Positioned(
                left: 16,
                right: 16,
                top: 36,
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
              ),
            Positioned(left: 0, right: 0, bottom: 0, child: _buildControls()),
          ],
        ),
      ),
    );
  }

  Widget _buildControls() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 24, 12, 10),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[Colors.transparent, Colors.black87],
        ),
      ),
      child: StreamBuilder<Duration>(
        stream: _player.stream.position,
        initialData: Duration.zero,
        builder: (BuildContext context, AsyncSnapshot<Duration> posSnap) {
          return StreamBuilder<Duration>(
            stream: _player.stream.duration,
            initialData: Duration.zero,
            builder: (BuildContext context, AsyncSnapshot<Duration> durSnap) {
              final Duration pos = posSnap.data ?? Duration.zero;
              final Duration dur = durSnap.data ?? Duration.zero;
              final double rawMax = dur.inMilliseconds.toDouble();
              final double max = rawMax > 0 ? rawMax : 1.0;
              final double value =
                  pos.inMilliseconds.toDouble().clamp(0.0, max);

              return Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Slider(
                    value: value,
                    max: max,
                    onChanged: (double v) =>
                        _player.seek(Duration(milliseconds: v.round())),
                  ),
                  Row(
                    children: <Widget>[
                      Text(
                        _fmt(pos),
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                      const Text(
                        ' / ',
                        style: TextStyle(color: Colors.white38, fontSize: 12),
                      ),
                      Text(
                        _fmt(dur),
                        style: const TextStyle(
                          color: Colors.white38,
                          fontSize: 12,
                        ),
                      ),
                      const Spacer(),
                      StreamBuilder<bool>(
                        stream: _player.stream.playing,
                        initialData: false,
                        builder: (BuildContext context, AsyncSnapshot<bool> snap) {
                          final bool playing = snap.data ?? false;
                          return IconButton(
                            onPressed: () => _player.playOrPause(),
                            icon: Icon(
                              playing ? Icons.pause : Icons.play_arrow,
                              color: Colors.white,
                            ),
                          );
                        },
                      ),
                      PopupMenuButton<double>(
                        tooltip: '倍速',
                        initialValue: _speed,
                        onSelected: (double v) {
                          _player.setRate(v);
                          setState(() => _speed = v);
                        },
                        itemBuilder: (BuildContext context) => _speeds
                            .map((double s) => PopupMenuItem<double>(
                                  value: s,
                                  child: Text('${s}x'),
                                ))
                            .toList(),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Text(
                            '${_speed}x',
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: _toggleFullscreen,
                        icon: Icon(
                          _landscape
                              ? Icons.fullscreen_exit
                              : Icons.fullscreen,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}
