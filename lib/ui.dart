import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import 'api.dart';
import 'theme.dart';

/// 统一的网络图片：
/// - 磁盘 + 内存双缓存（滚动不重复请求，不卡）
/// - 按显示尺寸解码（memCacheWidth，避免整张大图进内存）
/// - 加载完渐显，不再"啪"地跳出来
class NetImg extends StatelessWidget {
  const NetImg({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.memWidth,
    this.radius,
    this.fallback,
  });

  final String? url;
  final BoxFit fit;
  final int? memWidth;
  final double? radius;
  final Widget? fallback;

  @override
  Widget build(BuildContext context) {
    final String raw = (url ?? '').trim();
    Widget child;
    if (raw.isEmpty) {
      child = _ph();
    } else {
      // 豆瓣图有防盗链，必须走自家代理并带登录 cookie；采集站图直连
      final String u = Api.i.imageUrl(raw);
      final bool proxied = u.contains('/api/proxy');
      child = CachedNetworkImage(
        imageUrl: u,
        fit: fit,
        memCacheWidth: memWidth,
        httpHeaders: proxied ? Api.i.imageHeaders : null,
        fadeInDuration: const Duration(milliseconds: 240),
        fadeOutDuration: Duration.zero,
        placeholder: (BuildContext _, String __) => const ColoredBox(color: C.soft),
        errorWidget: (BuildContext _, String __, Object ___) => fallback ?? _ph(),
      );
    }
    if (radius != null) {
      return ClipRRect(borderRadius: BorderRadius.circular(radius!), child: child);
    }
    return child;
  }

  Widget _ph() => Container(
    color: C.soft,
    alignment: Alignment.center,
    child: const Icon(Icons.movie_outlined, size: 18, color: C.muted),
  );
}

/// 骨架屏方块（加载中占位，做一个很轻的呼吸效果）
class Skeleton extends StatefulWidget {
  const Skeleton({super.key, this.width, this.height, this.radius = 10});

  final double? width;
  final double? height;
  final double radius;

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (BuildContext _, Widget? __) {
        final double t = 0.45 + 0.25 * _c.value;
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            // 用 withAlpha（老 API，兼容所有 Flutter 版本；withValues 是 3.27+ 才有）
            color: C.soft.withAlpha((t * 255).round()),
            borderRadius: BorderRadius.circular(widget.radius),
          ),
        );
      },
    );
  }
}
