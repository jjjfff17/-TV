import 'package:flutter/material.dart';

import '../api.dart';
import '../theme.dart';

/// 登录页：只做一件事——用站点密码换一个 30 天有效的登录 cookie。
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.onSuccess});

  final VoidCallback onSuccess;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _pwd = TextEditingController();
  bool _busy = false;
  String? _error;

  /// 底部「服务器设置」上显示的版本信息
  String get _versionLabel =>
      Api.i.version.isEmpty ? '未连接' : 'v${Api.i.version}';

  @override
  void dispose() {
    _pwd.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    final String pwd = _pwd.text.trim();
    if (pwd.isEmpty) {
      setState(() => _error = '请输入站点密码');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Api.i.login(pwd);
      if (!mounted) return;
      widget.onSuccess();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '登录失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openEndpointDialog() async {
    final TextEditingController b = TextEditingController(text: Api.i.base);
    final TextEditingController s = TextEditingController(
      text: Api.i.shareCode,
    );
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: C.dark,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Metrics.card),
        ),
        title: const Text(
          '服务器设置',
          style: TextStyle(color: Colors.white, fontSize: 16),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              controller: b,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: const InputDecoration(
                labelText: '站点地址',
                labelStyle: TextStyle(color: Colors.white54),
              ),
            ),
            TextField(
              controller: s,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: const InputDecoration(
                labelText: '分享码',
                labelStyle: TextStyle(color: Colors.white54),
              ),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('保存', style: TextStyle(color: C.accent)),
          ),
        ],
      ),
    );
    if (ok == true) {
      await Api.i.saveEndpoint(
        newBase: b.text,
        newShareCode: s.text,
      );
      try {
        await Api.i.refreshStatus();
      } on ApiException catch (e) {
        if (!mounted) return;
        setState(() => _error = e.message);
      }
    }
    b.dispose();
    s.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: C.darkBg,
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0, -0.55),
            radius: 1.1,
            colors: <Color>[Color(0xFF1B2436), C.darkBg],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Text(
                    'LibreTV',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 30,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '私人影院 · 原生版',
                    style: TextStyle(color: Colors.white38, fontSize: 13),
                  ),
                  const SizedBox(height: 34),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    decoration: BoxDecoration(
                      color: Colors.white10,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: TextField(
                      controller: _pwd,
                      obscureText: true,
                      autofocus: false,
                      style: const TextStyle(color: Colors.white, fontSize: 15),
                      onSubmitted: (_) => _submit(),
                      decoration: const InputDecoration(
                        hintText: '输入站点密码',
                        hintStyle: TextStyle(color: Colors.white38),
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(vertical: 16),
                      ),
                    ),
                  ),
                  if (_error != null) ...<Widget>[
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Color(0xFFFF7A7A), fontSize: 12),
                    ),
                  ],
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton(
                      onPressed: _busy ? null : _submit,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: C.accent,
                        disabledBackgroundColor: C.accent.withAlpha(120),
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(24),
                        ),
                      ),
                      child: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text(
                              '进入',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  TextButton(
                    onPressed: _openEndpointDialog,
                    child: Text(
                      '服务器设置（$_versionLabel）',
                      style: const TextStyle(color: Colors.white30, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
