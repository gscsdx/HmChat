# 图片、相册与视频

## 当前实现

系统 PhotoViewPicker 一次选择 1–10 项 JPEG/PNG 图片或 MP4/MOV 视频，可混选，保留选择顺序，预览逐项移除并添加一条说明。照片上限 10,000,000 字节，视频上限 2,000,000,000 字节；当前不是 Telegram 所有账号权益的大小上限。URI 按 64 KiB 分块复制到应用缓存，核对文件头、大小和完整写入；视频用官方 AVMetadataExtractor 在 10 秒内读取宽高和时长。取消系统选择不发送。

单项使用 `sendMessage`，2–10 项使用固定 TDLib 1.8.69 schema 的 `sendMessageAlbum`。图片/视频分别嵌套 `inputPhoto`/`inputVideo`；说明只放第一项，`show_caption_above_media` 保持一致。未做流式布局保证，不把上传标记为 `supports_streaming`。请求失败保留整组本地附件和说明；部分响应中的空项保留为失败，不能伪造云端确认。正文草稿与附件说明相互独立。

接收时保留字符串 `media_album_id`，只合并同聊天、同方向、连续的相同相册 ID，单项继续保留各自消息 ID、长按菜单和可见已读。图片自动选择不超过 20 MiB 的版本；视频/动图自动下载由网络策略控制，用户打开时通过 TDLib 有界字节窗口边下边播，完整缓存仍可直接播放，失败可重试或完整下载。秘密/剧透媒体不自动揭示，目前仍为类型占位。

全屏查看器支持计数、前后按钮、原尺寸图片查看和缩放；未放大的图片可横向滑动切换。视频使用官方 `AVPlayer` + `XComponent`，提供播放/暂停/重播、未缓存进度拖动、前后 30 秒、时长、静音、七档倍速、长按临时 2 倍速及松手恢复；单击显隐、双击播放暂停、横向滑动定位按移动端 B 站式意图实现。保持画面比例；退后台/音频中断暂停，不自动恢复播放；切换视频、关闭及组件销毁释放播放器与文件句柄，并用 generation 隔离过期异步回调。准备超时 45 秒，缺片读取 30 秒、定位 35 秒；完整路径与真机验收见 [VIDEO_PLAYER.md](VIDEO_PLAYER.md)。

保存使用官方 `showAssetsCreationDialog`，用户确认后写入系统授予的目标 URI；不申请整个私人相册的读取权限。当前导出 JPEG/PNG 与 MP4 容器，其他容器明确报错。

## 模块

- `model/MediaModels.ts`：附件模型、相册分组、时长/大小展示。
- `services/AttachmentService.ets`：系统选择、受控复制、视频元数据、经确认保存。
- `telegram/TelegramClient.ts`：媒体协议、发送确认/失败、下载状态、消息归并。
- `components/MediaViewer.ets`、`PhotoViewer.ets`、`VideoPlayer.ets`：全屏浏览、图片手势、原生播放。
- `pages/Index.ets`：单栏媒体气泡、相册、附件预览和用户动作。

SDK API 以本机 SDK 26 的 `@ohos.multimedia.media.d.ts`、`@ohos.file.photoAccessHelper.d.ts` 为准；上游协议以本地固定 schema 为准。官方接口参考：[AVPlayer](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/arkts-apis-media-avplayer)、[PhotoAccessHelper](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/arkts-apis-photoaccesshelper)。

## 验证与限制

2026-10-31：263 项宿主机测试通过，包含混合相册字段/顺序、失败附件保留、空响应、大小与非法元数据、视频缩略图/手动下载/取消/重试/完成、秘密媒体不揭示、int64 相册 ID 与跨聊天边界。SDK 26 编译签名通过。

指定 Pura X Max 真机未展开形态已验证：Web → 鸿蒙的两图加视频相册；鸿蒙 → Web 的两图加视频相册与说明、独立视频；系统多选、三项预览；三项合成素材经系统确认保存；原生视频播放/暂停、静音、倍速、点击/拖动进度、退后台暂停且返回不自动播放；图片/视频前后按钮、双击图片与系统返回。正文草稿逐字保持，Web 也比对一致。合成测试消息和保存的三项合成素材暂保留，便于用户复验；未删除任何原消息或私人图库内容。原始证据只放 ignored artifacts，不公开用户图库和会话。

当前不支持选择重排、分别发送开关、图像编辑/压缩质量、原文件发送、HEIF 转码、剧透主动揭示、画中画、跨账户后台缓存与上传暂存回收、上传进度百分比。视频实际编码解码依赖设备支持；未声称所有编码和大文件边界已真机通过。真实双指连续手势、下载故障/取消竞态、解码错误重试、音频抢占、保存取消、展开/旋转/分屏仍待真实验收。不要把以上基础链路写为媒体能力全面对齐。

当前账户的分类占用、选择性/按会话清缓存、期限/上限及按网络图片/视频/动图下载设置已接入，验证范围见 [STORAGE_MANAGEMENT.md](STORAGE_MANAGEMENT.md)。
