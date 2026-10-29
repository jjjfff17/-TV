# LibreTV 原生版（Android）· M0

Flutter + media_kit（libmpv）原生客户端。M0 只验证「能出包、能装、能播」。

## 怎么出 APK（全程网页，不用装软件）

1. GitHub 右上角 `+ → New repository`，建一个空仓库（建议名 `libretv-native`）。
2. 进仓库点 **Add file → Upload files**，把**本文件夹里的全部内容**拖进去（注意：是内容，不是把 `libretv-native/` 这层文件夹拖进去）。
   - 关键：仓库根目录要**直接**看到 `pubspec.yaml`、`lib/`、`tool/`、`.github/`。
3. 页面底部点 **Commit changes**。
4. 顶部 **Actions → Build LibreTV Native APK → Run workflow**（提交到 main 一般会自动触发）。
5. 等 **8~12 分钟**（Flutter 首次要下 SDK），变绿后在记录底部 **Artifacts** 下载 `libretv-native-apk`。
6. 解压后按手机架构选：绝大多数手机装 **`app-arm64-v8a-release.apk`**。

## 说明

- M0 用公开 HLS 测试流，只为验证播放链路；M1 起接真实片源。
- 本仓库**不含** `android/`：CI 用 `flutter create` 现场生成，再打补丁（加 INTERNET 权限、cleartext）。这样不用提交 Gradle wrapper 二进制。
- 这是 **release** 包，但用的是 Flutter 默认 debug 签名，可直接安装；正式分发在 M4 换 `KS_PWD` 签名。

## 目录

```
lib/main.dart                 初始化 media_kit + 入口
lib/screens/player_screen.dart 播放页（播放/暂停/进度/倍速/全屏横屏）
tool/patch_manifest.py         给生成的 manifest 补 INTERNET 等
.github/workflows/build-apk.yml CI：生成 android → 构建 → 上传
PROJECT.md / CHECKLIST.md / tasks/M0.md  轻量协作空间
```
