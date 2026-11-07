# 功能实现与验证状态

本文件按实际代码列出能力，运行结果需要另行登记。未在本文件确认的其他功能以 `STATUS.md` 为准；源码存在不等于真机或 Telegram 服务端已验证。

## 单张图片选择与本地缓存

实现文件：`entry/src/main/ets/services/AttachmentService.ets`。

接口：`AttachmentService.pickImage(context: common.UIAbilityContext): Promise<string>`。

| 能力 | 实现情况 | 验证情况 |
| --- | --- | --- |
| 系统图片选择器 | 使用官方 `photoAccessHelper.PhotoViewPicker`，最多选择一张，不读取全量相册 | 已通过本机 SDK 26 主 HAP 构建；真机确认打开；模拟器已选取自行生成的无个人内容系统截图并返回应用预览 |
| 格式与大小筛选 | JPEG / PNG；上限 **10,000,000 字节**，与 Telegram 图片上传限制采用保守一致值 | Picker 参数、文件 stat 和复制累计长度三处检查；真机选择待验证 |
| 内容格式判断 | 用 JPEG / PNG 文件签名确认格式，不依赖用户文件名或 URI 后缀 | 源码已实现；不声称完整解码验证 |
| 私有缓存 | 复制到 `context.cacheDir/harlgram-uploads/image-XXXXXX/image.jpg` 或 `.png`；目录由系统生成唯一后缀 | 模拟器选图后应用预览及 TDLib 上传成功，确认该素材的 URI 读取/复制路径可用；真机仍待验证 |
| 资源管理 | 异步打开、stat、64 KiB 分块读写；处理短读/短写；finally 关闭两端 FD；失败清理本次临时文件 | 源码已实现；存储失败与取消回归待验证 |
| 取消 | 返回空 `photoUris` 时返回空字符串，不创建缓存 | 模拟器系统返回取消后恢复收藏夹，原草稿逐字不变；真机仍待复验 |
| 上传或发消息 | **此服务不上传、不发送**；返回路径供 UI 预览，随后点击发送才交 TDLib | 授权自测范围内，模拟器收藏夹已完成安全测试截图发送并显示已发送状态；正文草稿保留。其他格式/失败路径不能据此认定通过 |

已将原先 20 MiB 的本地候选限制调整为 10,000,000 字节，避免选择成功后超出 TDLib `inputMessagePhoto` 对图片上传的大小限制。下载限制属于独立功能，不与该值混用。

### 错误与取消约定

本机 SDK 的 `PhotoViewPicker.select()` 文档只列出 `401`、`13900042`、`23800151`，没有独立的「用户取消」业务错误码。因此只把成功结果中的空选择视为取消；不擅自吞掉 `13900042` 等实际错误。打开选择器失败返回去敏错误提示，不把用户 URI、路径或系统异常正文打印到日志。

文件操作中，空间不足/配额不足 `13900025` / `13900041` 提示清理空间，授权失效 `13900012` / `13900001` 提示重新选择；其他 I/O 错误使用固定提示。图片超过限制、格式不支持、复制时大小变化和关闭失败均拒绝返回成功路径。

### 依赖与使用边界

- 仅依赖官方 `@kit.AbilityKit`、`@kit.BasicServicesKit`、`@kit.CoreFileKit` 和 `@kit.MediaLibraryKit`。
- 不需要全量相册读取权限；只读取用户通过系统选择器明确选择的 URI，不枚举图库。
- MIME / 大小筛选为 API 19 起的官方能力，在本工程 SDK 26、兼容 API 24 的范围内。
- 选择器完成后转入下一事件任务再打开只读 URI，避免在选择结果回调内同步读取文件；实际图库返回时序仍需真机验收。
- 当前不做 HEIF、GIF、WebP 等格式的 ImageKit 转码。需要支持时另加受尺寸、像素数与输出大小约束的异步转换；不能在 UI 线程无界解码大图。
- 成功返回后，缓存文件需要由上层在用户取消预览或 TDLib 不再需要文件时清理。上传/重试尚未结束前不能立即删除。此服务只清理自身失败产生的临时文件。
- 应用缓存可能被系统回收，待发送路径不是永久保存或重启恢复的保证。

### 待执行的真机用例

使用合成测试图片或用户明确选择的测试素材，验证 JPEG、PNG、取消、恰好大小上限、超过上限、格式不支持和重复打开选择器。再检查前后台返回、缓存路径可读、预览取消后的上层清理及低存储错误。不要自动读取用户真实照片，也不要通过自动化发送真实消息。

### 官方依据

- [PhotoViewPicker 接口](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-media-library-kit/arkts-apis-photoAccessHelper-PhotoViewPicker.md)
- [使用 Picker 选择媒体库资源](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/media/medialibrary/photoAccessHelper-photoviewpicker.md)
- 本机 SDK：`ets/api/@ohos.file.photoAccessHelper.d.ts`、`ets/api/@ohos.file.fs.d.ts`。当前核验版本 `26.0.0.105`。
