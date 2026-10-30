import 'package:flutter/material.dart';

import '../theme.dart';
import 'home_screen.dart';
import 'mine_screen.dart';

/// 应用主壳：底部导航（首页 / 我的）。
/// 只放我们真实有的两个页面；专题/榜单暂无内容，不做占位。
class MainShell extends StatefulWidget {
  const MainShell({super.key, required this.onLogout});

  final VoidCallback onLogout;

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _tab = 0;
  final GlobalKey<MineScreenState> _mineKey = GlobalKey<MineScreenState>();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: C.bg,
      body: IndexedStack(
        index: _tab,
        children: <Widget>[
          HomeScreen(onLogout: widget.onLogout),
          MineScreen(key: _mineKey),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _tab,
        onTap: (int i) {
          if (i == _tab) return;
          setState(() => _tab = i);
          // 切到「我的」时刷新，保证收藏/进度是最新的
          if (i == 1) _mineKey.currentState?.reload();
        },
        backgroundColor: C.surface,
        selectedItemColor: C.accentDeep,
        unselectedItemColor: C.muted,
        selectedFontSize: 11,
        unselectedFontSize: 11,
        type: BottomNavigationBarType.fixed,
        elevation: 8,
        items: const <BottomNavigationBarItem>[
          BottomNavigationBarItem(
            icon: Icon(Icons.home_rounded, size: 22),
            label: '首页',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.person_rounded, size: 22),
            label: '我的',
          ),
        ],
      ),
    );
  }
}
