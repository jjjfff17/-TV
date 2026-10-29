# PROJECT · LibreTV 原生版（Android）

> 轻量协作空间：本文件 = 事实基准；`CHECKLIST.md` = 验收清单库；`tasks/` = 里程碑任务书。

## 一、目标（可检验）

- 交付可安装的 Android APK：**搜索 → 详情 → 选集/线路 → 播放**，手势/倍速完整、断点续播。
- 播放内核 = **media_kit（libmpv）**，与参考 App 同款。
- **不做**：弹幕、iOS、投屏、下载、推送。

## 二、事实基准（红线，不许猜）

| 项 | 值 |
|---|---|
| 后端 API 基址 | `https://libretv-tv-65752.app.workbuddy.host` |
| 访问参数 | `sharecode=I7GLYKL3VS` |
| 站点密码 | `LibreTV@2026`（网页用） |
| 现有接口 | `/api/search` `/api/detail` `/api/source-list` `/api/proxy` `/api/quality` `/api/hot-list` `/api/bangumi/calendar` |
| 包名 | `com.libretv.native` |
| App 名 | `LibreTV` |
| 签名 | 沿用 `KS_PWD`；M0~M3 用 debug 签名出 release 包，M4 换正式签名 |

## 三、里程碑（每阶段自检，真人验收点标注）

| 阶段 | 产出 | 验收标准 | 真人验收 |
|---|---|---|---|
| **M0** | Flutter 骨架 + media_kit 播放测试流 + CI 出 APK | 装上能播、不崩、CI 绿 | ✅ 装 APK 试播 |
| **M1** | 首页/搜索/详情/选集/线路（调现有 API） | 能搜到片、进详情、列出剧集与线路 | ✅ 点一遍 |
| **M2** | 播放器完整手势（2x/3x/1.5x、±4s、±15s、竖滑、双击、全屏横屏、续播、下一集） | 真机逐项过 | ✅ 逐项试 |
| **M3** | 历史/收藏/打磨 | 重启后数据仍在 | ✅ 重启验证 |

## 四、约束

- 本机无 Flutter / Java / Android SDK → **一律 GitHub Actions 构建**。
- **单窗串行**推进，不硬拆多窗（避免合并冲突）。
- 每阶段只动当前阶段需要的代码，不跨阶段预埋。

## 五、交付节奏

- 每阶段：写代码 → 自检（静态检查 + CI 构建）→ 报告 → 等真人验收 → 进下一阶段。
