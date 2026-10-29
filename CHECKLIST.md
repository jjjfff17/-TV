# CHECKLIST · 验收清单库

> 只增不改。每条必须能在验收时打勾。

## 一、沿用网页端踩坑（CL-LTV）

- [ ] **CL-LTV-01** 源探活必须用真实片名（默认「无间道」），禁止 `wd=test`。
- [ ] **CL-LTV-02** 访问线上 URL 前 `export MSYS_NO_PATHCONV=1`，否则 Git Bash 把 `/watch` 当本地路径。
- [ ] **CL-LTV-04** sharecode 走 query 参数（`?sharecode=xxx`）；静态 chunk 也要带 cookie 否则 403。
- [ ] **CL-LTV-05** 部分源是图片型 m3u8（分片 JPEG，`ffd8ffe0`），验证时别误判为失败。
- [ ] **CL-LTV-06** 预置源与订阅源 URL 重复 → 按 URL 去尾斜杠去重。

## 二、原生新增（CL-NAT）

- [ ] **CL-NAT-01** APK 必须含 `INTERNET` 权限。Flutter release 模板默认**没有**，必须在 manifest 补。
- [ ] **CL-NAT-02** 片源防盗链：请求必须带 `Referer` / `User-Agent`，否则 403。
- [ ] **CL-NAT-03** media_kit 必须在 `runApp` 前调 `MediaKit.ensureInitialized()`，否则启动崩。
- [ ] **CL-NAT-04** APK 体积：libmpv 每个 ABI 约 20MB。只保留 arm64 可把 ~80MB 降到 ~40MB（`--split-per-abi`）。
- [ ] **CL-NAT-05** 全屏横屏用 `SystemChrome.setPreferredOrientations`，退出时必须恢复竖屏 + 系统 UI。
- [ ] **CL-NAT-06** Flutter release 包默认用 debug 签名；正式分发前必须换 `KS_PWD` 签名。
- [ ] **CL-NAT-07** 播放器 `dispose()` 必须释放 `Player`，否则切集内存泄漏。
