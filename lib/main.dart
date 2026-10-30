import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart'; // CupertinoPageTransitionsBuilder（pageTransitionsTheme 用）
import 'package:media_kit/media_kit.dart';

import 'api.dart';
import 'asset_paths.dart';
import 'screens/main_shell.dart';
import 'screens/login_screen.dart';
import 'theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // media_kit 必须在 runApp 前初始化，否则播放页会白屏
  MediaKit.ensureInitialized();
  runApp(const LibreTvApp());
}

class LibreTvApp extends StatelessWidget {
  const LibreTvApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LibreTV',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: 'MiSans',
        scaffoldBackgroundColor: C.bg,
        colorScheme: ColorScheme.fromSeed(seedColor: C.accent),
        // 页面切换统一走 iOS 式横向滑动，比默认 Android 缩放更顺、更"贵"
        // 注意：新版 Flutter 的 CupertinoPageTransitionsBuilder() 已非 const，
        // 故此处不能加 const，否则报 "Not a constant expression"
        pageTransitionsTheme: PageTransitionsTheme(
          builders: <TargetPlatform, PageTransitionsBuilder>{
            TargetPlatform.android: CupertinoPageTransitionsBuilder(),
            TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          },
        ),
      ),
      home: const _BootGate(),
    );
  }
}

enum _Phase { loading, login, home, error }

/// 启动闸门：先拉站点状态，已登录直接进首页，否则去登录页
class _BootGate extends StatefulWidget {
  const _BootGate();

  @override
  State<_BootGate> createState() => _BootGateState();
}

class _BootGateState extends State<_BootGate> {
  _Phase _phase = _Phase.loading;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    setState(() => _phase = _Phase.loading);
    try {
      // 先探资源前缀（图标），再连后端；探测失败也不阻断启动
      await AssetPaths.probe();
      await Api.i.boot();
      if (!mounted) return;
      setState(() {
        _phase = (!Api.i.passwordRequired || Api.i.verified)
            ? _Phase.home
            : _Phase.login;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is ApiException ? e.message : '$e';
        _phase = _Phase.error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    switch (_phase) {
      case _Phase.loading:
        return const Scaffold(
          backgroundColor: C.darkBg,
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  'LibreTV',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1,
                  ),
                ),
                SizedBox(height: 18),
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white54,
                  ),
                ),
              ],
            ),
          ),
        );
      case _Phase.login:
        return LoginScreen(
          onSuccess: () => setState(() => _phase = _Phase.home),
        );
      case _Phase.home:
        return MainShell(
          onLogout: () => setState(() => _phase = _Phase.login),
        );
      case _Phase.error:
        return Scaffold(
          backgroundColor: C.darkBg,
          body: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Text(
                    '连接不上站点',
                    style: TextStyle(color: Colors.white, fontSize: 16),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    _error,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                  const SizedBox(height: 18),
                  TextButton(
                    onPressed: _boot,
                    child: const Text('重试', style: TextStyle(color: C.accent)),
                  ),
                ],
              ),
            ),
          ),
        );
    }
  }
}
