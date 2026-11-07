# 应用图标

## 2026-11-06 品牌更名 HmChat 与新图标

- 用户确认应用显示品牌统一为 HmChat，并使用「纯黑底、白色圆环、下方白色横线」的新图标。
- 源图：用户提供的 500 × 500 PNG；按现有 1254 × 1254 单层 PNG 资源规格高质量缩放，保持正方形、黑底与白色图形完整，未拉伸。
- 当前资源：`AppScope/resources/base/media/harlgram_icon.png`（文件名不变，减少引用改动），`AppScope/app.json5` 与 `entry/src/main/module.json5` 的 icon / startWindowIcon 继续引用 `$media:harlgram_icon`。
- 用户可见品牌同步为 HmChat：应用 label、聊天页标题、关于页、代理通知、代理范围文案、订阅 UA、演示欢迎语和附件保存文件名。
- 2026-11-06 后续按用户要求将 bundleName 从 `xyz.3333189.harlgram` 改为 `com.hmchat.app`；签名 profile 已绑定新包名，signed HAP 构建与安装通过。内部持久化键、`harlgramOnly` scope 值和日志 TAG 保持不变，避免无关功能改动。
- 新包是独立应用，旧包数据不会自动迁移；旧包未卸载，可共存。设置页「关于 HmChat」已移动到「退出 Telegram 账号」之前；未登录时退出按钮不显示，源码顺序与已登录设备路径分别记录。
- 已验证：真实 SDK 26 构建成功；新包 signed HAP 覆盖安装并启动；`bm dump` 确认 `com.hmchat.app` 的 label 为 `HmChat`，`xyz.3333189.harlgram` 旧包仍在；关于页标题和正文均为 HmChat。
- 未完成：验证时桌面未找到 HmChat 快捷方式，桌面图标截图与已登录时的退出按钮实际排列尚未采集；图标资源与清单引用已确认。

## 历史：2026-10-29 黑白纸飞机图标（已替换）

2026-10-29，用户确认采用黑白轻拟物纸飞机图标，并已在真机查看后确认效果。以下为当时的记录，当前品牌和图标以上一节为准。

## 定稿与配置

- 确认稿：`AppScope/resources/base/media/harlgram_icon.png`；设计记录见 [BRANDING.md](BRANDING.md)。
- 应用资源：`AppScope/resources/base/media/harlgram_icon.png`，与确认稿的压缩像素数据一致，仅移除生成元数据，不重新绘制造型。
- `AppScope/app.json5` 的 app.icon、`entry/src/main/module.json5` 的 EntryAbility.icon 和 startWindowIcon 均引用 `$media:harlgram_icon`。
- 当前使用官方支持的单层 PNG 图标配置，系统负责桌面外轮廓裁切。保留黑底、白色圆环、简化纸飞机、直角横条和轻微浮雕；不要恢复旧蓝色图标或胶囊横条。
- 资源统一放在 AppScope，由构建合入 entry，避免两处同名图标内容不一致。配置依据见[官方应用图标说明](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/quick-start/layered-image.md)。

## 已验证

- `./scripts/build.sh`：SDK 26 构建成功，日志位于 ignored `artifacts/build-app-icon.log`。
- 检查 signed HAP：图标资源存在，应用、入口与启动图标引用均正确。构建工具将 1254 × 1254 原图处理为包内 512 × 512 图标，因此不以压缩后字节相等作为验收条件。
- 指定 HOP-AL00 / API 26 真机正常覆盖安装与启动成功，保持原登录状态。
- 真机桌面显示新的黑白图标，系统圆角裁切后圆环和横条完整；点击该图标可进入已登录应用。截图 `artifacts/screenshots/app-icon-launcher.png` 仅留本机忽略目录。
- 用户现场确认「已经 ok 了我看了」。本次为资源变更，未触发消息发送或修改账号数据，不涉及新的服务端功能验收。

未验证其他设备形态或商店视觉审核；未卸载应用、清空沙箱或运行同 bundle 的 ohosTest。

## 2026-10-31 应用内品牌统一

欢迎首屏、登录/注册页和关于页统一引用 AppScope 的 `harlgram_icon` 定稿资源，集中使用 `brandLogo` 构建器，去除旧蓝底纸飞机品牌占位。消息发送按钮继续保留其功能图标。系统启动窗口和桌面本来已经引用同一定稿资源，本次无须重复配置。

SDK 26 编译及签名、指定真机覆盖安装和启动通过。已实际截图检查欢迎首屏与手机号登录页，显示黑白定稿 Logo、比例与圆角正常；关于页仅编译核对，未单独打开验收。截图 `artifacts/screenshots/brand-welcome.png` 和 `brand-login.png` 仅保留本机忽略目录，登录截图含账户名称，不得公开。验证只在欢迎/手机号页往返，未提交手机号或验证码。
