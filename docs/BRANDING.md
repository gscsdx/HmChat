# HmChat 应用图标与品牌

## 2026-11-06 当前定稿

用户确认品牌统一为 HmChat，并采用新图标：纯黑底、白色圆环、圆环下方一条白色横线。源图为用户提供的 500 × 500 PNG，已按现有 1254 × 1254 单层 PNG 规格缩放，写入 `AppScope/resources/base/media/harlgram_icon.png`。资源文件名与清单引用保持不变。

按要求 bundleName 已改为 `com.hmchat.app`，签名 profile 与之匹配；这是独立新应用，旧包 `xyz.3333189.harlgram` 的数据不会自动迁移，旧包未卸载。内部持久化键与 `harlgramOnly` scope 未改。

用户可见品牌已在应用 label、聊天页、关于页、代理范围、订阅 UA、通知和演示欢迎语中改为 HmChat。构建、安装、label 和关于页已核对；桌面图标截图与已登录时「退出」按钮排列待补验。

## 历史：旧版黑白轻拟物纸飞机图标（已替换）

2026-10-29，内置 imagegen 编辑第三轮 D3。按用户要求改为黑白/中性灰、下方横条直角矩形，增加克制的浅浮雕与折纸明暗。随后用户确认该版本，已接入应用资源并完成真机桌面及点击启动验证；接入记录见 `docs/APP_ICON.md`。以下提示词与定稿描述仅保留为历史，不代表当前图标。

参考方向来自官方的轻拟物设计理念与 HarmonyOS 7 沉浸光感介绍；没有声称是系统默认图标或精确复刻默认图标。

- https://developer.huawei.com/consumer/cn/design/concept/
- https://consumer.huawei.com/cn/harmonyos-7/

输入图：先前未采用的蓝色设计稿；不随源码分发。

定稿：`AppScope/resources/base/media/harlgram_icon.png`。

## 完整提示词

```text
Use case: precise-object-edit / logo-brand.
Edit the supplied launcher icon. Keep the existing overall composition: a circular O containing a very simple Telegram-like paper airplane pointing northeast, with a detached horizontal bar centered below. Preserve the airplane's simplified silhouette and its single main fold cut. Do not add the old complicated H crossbar back.

REQUIRED CHANGES:
1. Strictly monochrome black, white and neutral grey only. Remove ALL blue, violet, cyan and colored tint. The full square background is deep graphite black; the circle, plane and underline are luminous neutral white.
2. Replace the rounded capsule underline with a plain horizontal RECTANGLE. Both ends are straight vertical edges. All four corners are exact sharp 90-degree corners, absolutely zero corner radius. Keep its current width, height and centered alignment.
3. Introduce just a restrained touch of skeuomorphism, inspired by contemporary HarmonyOS 7 native launcher icon light/material treatment: white shapes with very shallow satin-ceramic relief, a fine soft upper-left highlight, tiny neutral-grey side facets, and subtle close contact shadows. The main white faces stay bright and clean. The airplane may have a very gentle single folded-paper plane change in value, but no added geometry or internal detail. Ring is softly beveled in depth only, maintaining a perfect circular silhouette. The bar has shallow thickness but its FRONT SILHOUETTE remains a mathematically sharp-cornered rectangle. The background has only a barely perceptible black-to-charcoal lighting falloff, no texture or scene.

This must read as a polished actual mobile APP ICON, not an engraved metal plaque, product photograph, medallion, or logo on a presentation sheet. Front-on orthographic view. Keep the entire background full-bleed to all canvas edges and leave the outer square unmasked for the OS launcher. Maintain generous spacing and clear silhouette at small sizes. Subtle materiality, not bulky 3D. No glossy glass, no chrome, no neon, no orbit effects, no outer frame, no round-ended underline, no extra symbols, no text, no mockup. Deliver one square finished icon.
```
