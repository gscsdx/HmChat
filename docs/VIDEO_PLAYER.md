# 原生视频播放器

本轮目标是手机单栏/指定阔折叠真机未展开窗口的播放器。入口仍为聊天媒体查看器，使用官方 AVPlayer + XComponent。功能参考 Web A 的播放意图，采用当前 SDK 26 的 AVPlayer 原生网络源；没有 WebView 播放页、第三方闭源播放器或外部媒体代理。

## 能力清单

| 能力 | 源码行为 | 验收重点 |
| --- | --- | --- |
| 边下边播 | 未完成文件通过短生命周期的本机 HTTP Range 通道按需供给；已完成文件仍走 fdSrc | 冷缓存真实云端视频，prepared 时已下载量小于总量，画面/播放时间推进 |
| 拖动进度 | 原生 Slider 与 AVPlayer.seek；解码器新的字节请求驱动 TDLib 修改下载位置 | 跳到尚未缓存的中后段；缓冲后继续，旧回调不能覆盖新位置 |
| 前后 30 秒 | 官方 gobackward_30 / goforward_30 Symbol 按钮 | 正常跳转，开头/结尾越界限制，暂停时保持暂停 |
| 播放与重播 | 播放/暂停，完成后回到开头重播 | 播放时长推进、暂停稳定、结束重播 |
| 常用倍速 | 0.5 / 0.75 / 1 / 1.25 / 1.5 / 1.75 / 2 倍速系统选择弹层 | UI 选择与原生 speedDone 事件一致 |
| 长按临时 2 倍速 | 正在播放时长按画面；松手/取消恢复先前选定倍速 | 原生速率变更；离开/切后台/音频中断不能遗留 2 倍速 |
| 缓冲与错误 | 准备/缓冲提示，准备 45 秒和缺片 30 秒超时，重试保留位置；可选完整下载退路 | 网络不足不喂零字节或稀疏空洞，不假装播放成功 |
| 操作与生命周期 | 单击画面显隐控制栏、双击播放暂停、横向滑动预览/提交定位，播放约 3.5 秒后自动收起；静音、按比例显示、播放保持亮屏 | 控件不遮挡核心画面；后台/音频中断暂停，回来不自动播放；关闭释放资源 |

上述表格描述源码行为，设备实际结果见 STATUS.md；不能把宿主机测试或组件显示当作设备/服务端通过。画中画、字幕/多音轨、投屏、清晰度切换、播放历史持久化和完整多形态仍需独立设计与验证，本轮不借「好播放器」宣称所有能力都已具备。

## 数据链路与边界

1. `TelegramClient.videoFile` 验证活动会话、真实消息/富内容归属、文件 ID 和视频类型。秘密/剧透媒体没有可播放映射，不经流式入口自动揭示。只接受已知大小且不超过当前 2,000,000,000 字节视频上限的文件。
2. `VideoRangeReader` 向 TDLib `getFileDownloadedPrefixSize` 查询**当前字节偏移**连续可用长度，确认后才通过 CoreFileKit 异步读取。不能用稀疏文件长度或 downloaded_size 推断某个随机位置已可读。每次最多读 64 KiB，缺片请求以 128 KiB 对齐、最多 2 MiB 的下载窗口，priority 32，synchronous false。
3. `VideoHttpStream` 用 NetworkKit 仅绑定 `127.0.0.1`、端口由系统临时分配，每个查看器使用独立随机路径，仅能读已验证的单个视频。支持 GET/HEAD、标准 206/Content-Range、单范围和后缀范围；错误/重复/多范围请求不扩大读取范围。无 CORS、目录映射、额外副本或外部媒体服务器。请求头最多 8 KiB、空闲头请求 8 秒超时、最多四个连接。
4. 新的 GET 替换旧预取连接，旧连接的迟到读不能再发送数据，避免多个偏移争抢同一个 TDLib 下载窗口；TCP send 的背压限制预取。退出播放器会关闭连接、监听与本轮按需下载。URL/随机路径不打印，日志仅有字节数量和原生状态/seekDone/speedDone。官方 MediaSourceLoader 尝试在本机出现后续定位 I/O 问题，已移除该未采用实现，不能把它的提前首帧当作最终连续播放验收。
5. `TelegramService` 用账户身份和连接代数阻止旧任务跨账户读取；协议请求有超时，完全冷缓存或 GC 后残留路径先经文件可访问性检查和 downloadFile 触发 TDLib 本地位置重验证，再查询前缀，关闭后不能将迟到文件响应写回新连接。播放/暂停原生调用串行并按最新意图收敛，定位按一项在途、最后一项目标合并，等待 seekDone 后再按用户播放/暂停意图恢复；旧 timeUpdate 不得拉回预览进度。用户关闭播放器时停止本轮按需下载；如果打开前已有独立的完整下载任务，按其手动/自动策略恢复，避免关闭播放器误取消原任务。
6. native decoder 释放后才关闭完整文件 fd；流式销毁立即停止新的读取与数据供给。当前会话由存储管理排除，不能在播放期间整理掉依赖文件。上传暂存仍按既有策略保留，不把本机发送素材播放当作远端重新下载的证据。

流式文件必须仍能从 Telegram 获取，网络和设备解码能力也会影响成功率。系统不支持的编码/容器或无效文件提供错误/重试/完整下载退路；不承诺所有格式都能流式播放。本机发送的文件仍保持原有 supports_streaming 标记约束，本轮没有假装对上传视频做过 faststart 重封装。

## 证据入口

- 项目固定 TDLib `td_api.tl`：downloadFile、getFileDownloadedPrefixSize、localFile。
- 当前 SDK `@ohos.multimedia.media.d.ts`：AVPlayer.url、bufferingUpdate、seek、setSpeed；`@ohos.net.socket.d.ts`：TCPSocketServer / TCPSocketConnection。
- 官方参考：[TDLib 下载范围](https://core.telegram.org/tdlib/docs/classtd_1_1td__api_1_1download_file.html)、[AVPlayer](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/arkts-apis-media-avplayer)、[MediaSource](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/arkts-apis-media-mediasource)。
- 宿主机回归：`tests/video-playback.test.mjs`、`tests/video-http-stream.test.mjs`；SDK 编译、安装、真实云端/真机证据与未通过项统一记录在 STATUS.md。所有测试素材均为合成色块/声波，原始设备截图和私有草稿备份保持忽略。

## 本轮真机结果

2026-10-31 指定未展开真机：完全清除测试视频缓存后，46.5 MB 视频在约 1.57 MB 即起播；未缓存中段定位后不补按播放也能自动推进；1.5× 长按切 2× 并松手恢复、前后 30 秒、单/双击/横滑、跨多个下载片段连续播放到结尾、重播及后台返回保持暂停均已取得设备证据。314 项宿主机回归、SDK 编译签名、最终覆盖安装/启动与原草稿保持通过。具体计时、日志及未验证边界见 STATUS.md；不从单一编码/设备推断所有文件和设备通过。
