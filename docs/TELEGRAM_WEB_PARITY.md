# Telegram Web A 手机尺寸能力对齐清单

初稿日期：2026-10-29。目标是功能对齐已登录的 Telegram Web A 手机尺寸界面，界面实现继续使用 HarmonyOS 官方组件与平台交互。本文是差距与验收清单，不是完成声明；只有页面入口、占位文字或 TDLib 库存在，均不能视为该能力实现。

## 基线、证据与范围

- Telegram 官方 [Applications / Source code](https://telegram.org/apps#source-code) 将 Web A 源码指向 [Ajaxy/telegram-tt](https://github.com/Ajaxy/telegram-tt)。本次实读 `git ls-remote`、检出并核验的固定提交为 [`6002824b6532f3d913997ce496d9ab5f9b86bc22`](https://github.com/Ajaxy/telegram-tt/commit/6002824b6532f3d913997ce496d9ab5f9b86bc22)，提交时间 `2026-10-26T18:55:36+01:00`；[package.json][W00] 版本 `12.0.48`。该提交是审查时官方仓库 HEAD，不据此声称它与线上部署逐字相同。
- 参考源码仅缓存在被忽略的 `.local/third_party/telegram-weba-src/`，未移植上游代码或依赖。该仓库使用 GPL v3；HarmonyOS 工程继续通过现有 TDLib 接入协议，不引入 WebView 客户端替代品。
- **S：源码证实**——阅读固定提交的入口、条件判断和实现。仅 S 的条目仍需线上手机尺寸实测，不能把源码文件存在当成当前账号一定可用。
- **O：主代理现场确认**——主代理在已登录 Web A 的 `page6`，`390 × 844`、touch 条件下观察到的入口或状态。本矩阵编写者未直接操作浏览器或账号，现场结论由主代理反馈。现场证据没有保存为本地截图文件，不虚构截图路径。
- **H：本工程已有运行证据**——引用当前 [STATUS.md](STATUS.md)、[DEVICE_TESTING.md](DEVICE_TESTING.md) 与主代理反馈；具体设备、版本与场景按原记录。纯领域测试不能替代服务端行为证据。
- 手机尺寸与手机浏览器不是同一条件：Web A 的 [useAppLayout][W01] 根据媒体查询判断 mobile；当前 [config.ts][W02] 的常规 mobile 宽度上限为 600 CSS px。触摸、操作系统、WebRTC、通知和屏幕共享仍有独立判断。不得把桌面 Chrome 缩窄后的能力一概标为手机平台都支持。
- 付费、管理员、群限制、隐私设置及浏览器权限均影响入口。现场有锁标记的能力只能记为「存在受限入口」，不能记为账号已可执行。

当前工程核对范围包括 `TelegramClient.ts`、`TdTypes.ts`、`ChatRepository.ts`、`ChatModels.ts`、`Index.ets`、`TelegramService.ets`、`AttachmentService.ets`、`LocalStore.ets` 与领域测试。它目前是具备真实登录、基础收发和图片/视频相册能力的客户端，距离下列完整 Web A 基线仍有较大差距。

本轮已新增消息权限查询、回复/编辑/删除/转发/复制菜单、引用定位和单图查看器。模拟器文本编辑已由 Web 同账号确认同步；收藏夹回复首次返回 400，修正 Saved Messages 的发送 topic 后，**真机回复正文及引用、单条转发到收藏夹、两次「仅为我」删除均获 Web 跨端确认**。真机还将原自测数字编辑恢复基线，Web 同步确认 true，本轮临时回复/转发消息最终计数为 0。点击引用只观察到短历史内滚动，不能计为跨页定位通过。复制未执行，未改剪贴板，也未向联系人发送；详见 [设备记录](DEVICE_TESTING.md)。

用户已在重新连接的真机完成登录；最终 134 项领域回归、SDK 26 主 HAP 构建、真机覆盖安装与启动通过，多次覆盖安装保持登录。原草稿通过 Web 恢复并经 SHA-256 布尔比对为 true，二次真机及最终编辑/图片关闭后的逐字比对也为 true。真机截图确认编辑输入在键盘上方、收起键盘及冷启动后底部黑边消失；图片打开、双击放大、拖动、Back 与完整可见关闭按钮均已验证，关闭后仍在收藏夹且草稿保留。真实两指捏合、单指加入第二指的衔接暂只有几何回归，未实测；已加载收藏夹在转发选择器置顶的独立呈现验收仍未记录。

## 已补入的现场证据

| 编号 | 主代理确认的 Web A 手机尺寸内容 | 证据边界 |
| --- | --- | --- |
| O1 | 主列表显示账号实际文件夹、归档、Story List 和新消息入口；观察到 All / Personal / Unread / Non-Contacts 等文件夹标签 | 文件夹来自账号，不应硬编码为固定四种本地筛选；不记录账号名称或会话正文 |
| O2 | 主菜单包含 My Profile、Saved Messages、Contacts、Settings、More、Add Account；More 包含 Night Mode、UI Features、Telegram Features、Report a Bug、Install App | 确认入口，未声称每个子流程执行成功 |
| O3 | Settings 包含 General Settings、Notifications、Privacy and Security、Data and Storage、Chat Folders、Language、Premium；其说明涉及 Wallpaper / Theme / Keyboard、Sounds / Calls / Badges、Last Seen / Password / Blocked Users、Media Download / Cache、Translate Messages | 说明文字也是能力指向，具体开关、权限和保存结果仍需逐项检查 |
| O4 | 收藏夹更多菜单包含 Search、Select messages、Send a Gift、Delete Chat；测试消息菜单含 Reply、Edit、Copy Text、Pin、Forward、Select、Delete；上方有标签/反应条 | 部分标签/反应入口带锁，未计为当前账号可用；删除、转发、礼物等未因看到入口而计为操作成功 |
| O5 | 输入区可见附件、emoji / sticker / GIF、完整编辑器和 AI Editor | 媒体、编辑器和 AI 的完整流程待分别验收 |
| O6 | Web A 同账号收藏夹显示模拟器上一轮发送的无个人内容测试截图；原草稿匹配可见 | **测试图片跨设备服务端同步已有 UI 证据；草稿跨设备可见且匹配。** 只记录匹配结论，不记录草稿、账号或消息正文；不扩展为所有媒体和草稿边界均通过 |
| O7 | Settings 还包含 Account（Username / Bio / Birthday）、Animations and Performance、Stickers and Emoji、Active Sessions、My Stars / Gram Earnings / Send a Gift；Data and Storage 按 Contacts / Other Private Chats / Groups / Channels 分组控制自动下载，并提供 Clear Media Cache；Privacy 可见 Blocked Users、Passcode Lock、Two-Step Verification、Auto-Delete、内容过滤；Chat Folders 可创建、编辑、拖动排序，并有受限的 Show Folder Tags | 仅记录功能标签，不记录隐私开关当前值、余额或任何账号数据；上述能力尚不能计为鸿蒙实现或已验收 |

## 状态解释与通用验收方式

「部分」表示已有具体能力，但未达到对应 Web A 行为；「缺失」表示当前源码没有用户操作到真实协议/平台能力的完整链路；「受限」表示上游自身有权限或环境条件。所有新增能力至少验证成功、取消、失败、重试、返回、切换会话及重启恢复中与其相关的路径。

发送、编辑、删除、建群和通话用明确授权的测试会话/账号与合成内容完成，普通会话和账号原有内容不作为破坏性测试材料。验收记录应包含操作、期望、实际结果及设备/版本，正文和账号标识不写进公开文档。下列「步骤」是待执行的验收用例，不代表本轮已执行。

## 会话列表、联系人与导航

| ID | Web A 基线与依据 | 当前工程状态 | 可验证验收步骤 |
| --- | --- | --- | --- |
| L01 | 主列表、头像、最后消息、未读、草稿预览、顺序和连续加载；[Chat][W03] | **部分**：真实主列表、头像、未读、排序、草稿和 `loadChats` 分页；运行证据已有基础列表 | 准备超过一页的测试会话；分页后新消息能改变正确会话顺序；返回列表不重复；空、错误、尾部均有明确表现 |
| L02 | 账号真实聊天文件夹、自定义规则、排序与受限标签；O1/O7、[SettingsFolders][W04] | **缺失**：当前「全部/未读/群组/频道」只是已加载列表上的本地筛选，不是 Telegram 文件夹 | 在 Web A 创建可撤销测试文件夹；本应用显示相同成员和顺序；编辑包含/排除规则、拖动排序后双端同步；标签按权限呈现；不把本地筛选覆盖成服务端规则 |
| L03 | Archived Chats、归档/取消归档；O1、[Archive][W05]、[Chat][W03] | **缺失**：只加载 `chatListMain`，非主列表条目会移出当前仓库 | 归档测试会话并在归档页找回；取消归档后重回主列表；归档内未读和置顶正确 |
| L04 | 会话置顶、静音时长、标已读/未读、删除/清空等会话操作；[Chat][W03] | **部分**：只有置顶切换与永久静音切换；无时长、手动未读、会话删除/清空 UI | 分别执行置顶/取消、限时静音、标未读；双端核对；删除仅对授权测试会话验证确认范围和撤销能力 |
| L05 | 联系人列表、搜索、新联系人与新私聊；O2、[NewContactModal][W06] | **部分**：读取已有联系人、本地姓名搜索、打开私聊；无新增/编辑/删除联系人 | 查找已有联系人后正确进入会话；添加授权测试联系人并双端核对；处理不存在/重复/取消，不创建伪会话 |
| L06 | My Profile、Saved Messages、主菜单和返回导航；O2、[MainMenuDropdown][W07] | **部分**：收藏夹、联系人、设置导航已有；当前账号页不能替代完整个人资料页 | 每个入口可达且返回原滚动位置；收藏夹使用当前登录用户身份；从搜索/详情/菜单返回不丢草稿 |
| L07 | 多账号添加、切换及独立缓存；O2、[AccountMenuItems][W08] | **部分实现/真机验证**：独立凭据与数据库、添加/切换、二级账户管理和头像；两个真实账户往返及冷启动恢复通过。当前仅活动账户连接，完整草稿/未读/文件/退出隔离及非活动账户通知仍待验收 | 使用两个授权测试账号切换，检查会话、草稿、未读、文件和通知隔离；退出其中一个不影响另一个 |

## 消息、输入与草稿

| ID | Web A 基线与依据 | 当前工程状态 | 可验证验收步骤 |
| --- | --- | --- | --- |
| M01 | 文本收发、发送中/失败/送达/已读，正确的用户和日期；[Message][W09] | **部分**：真实发送状态与日期；群头像、连续发言与紧凑元信息已真机对照，双勾依服务器 outbox read 更新，有协议回归；未全面验证对端阅读场景 | 两个授权测试端核对送达与阅读；离线/失败重发；不得把发送成功当已读 |
| M02 | 历史分页、打开未读位置、上下文跳转、回到最新；[Message][W09]、[MiddleSearch][W10] | **部分**：向前分页、错误/空/尾部状态、滚动到顶加载；真机点击引用后观察到原消息向上移动，仅短历史有滚动反应；跨页定位/精确锚点待验证，无完整未读跳转与搜索上下文 | 测试数百条历史、分页中切换会话、重叠页；锚点稳定、无串线；定位历史结果后仍能回到新消息 |
| M03 | 实际可见消息上报已读，前后台语义；[Message][W09] | **部分**：已实现只报当前前台视口内的已收到消息及去重；双端场景仍需验收 | 停留旧消息处收到新消息，未出现视口前不得自动清其未读；后台、返回、快速切换会话后复查另一端 |
| M04 | Reply / Quote、回复预览、跳转原消息；O4、[MessageContextMenu][W11] | **部分**：文本回复已有跨端证据；本轮补受限并发 `getRepliedMessage` 获取摘要/作者和缩略图，真实群引用原文可见，不插入旧消息，摘要保留剧透。跨页精确定位、局部 Quote 编辑仍未完成 | 核对原文、来源、缩略图与原消息不可用；引用跳转、删除及长历史锚点继续验收 |
| M05 | 编辑文本、说明和支持编辑的媒体；O4、[MessageContextMenu][W11]、[AttachmentModal][W12] | **部分，真机文本编辑已有跨端证据**：模拟器编辑与取消已验证；真机将原自测数字编辑恢复基线，Web 同步确认 true，原草稿保留，键盘输入可见。图片说明编辑、权限与结果状态、更新映射已有；未据此验证图片说明或所有权限边界，不支持替换媒体/完整富格式编辑 | 编辑自己允许编辑的消息并双端核对；取消保留旧内容；对他人/超时消息按实际权限隐藏或拒绝 |
| M06 | Forward、收藏夹转存、收件人选择；O4、[ForwardRecipientPicker][W13] | **部分，真机单条转发已有跨端证据**：转发到收藏夹后 Web 合成正文数量由 1 → 2；选择已加载会话的链路已实现，最新收藏夹置顶呈现待验收；无批量、多收件人和完整转发选项 | 转发授权测试消息到收藏夹；验证原来源/说明选项和多条顺序；取消不发送；受保护内容按权限限制 |
| M07 | 消息删除及作用范围；O4、[MessageContextMenu][W11] | **部分，真机「仅为我」已有跨端证据**：分别删除两条本轮自测消息，Web 对应数量 2 → 1 → 0；权限、范围确认与失败保留已有；未验证双方删除，无批量删除 | 测试仅本端与允许的双方删除；确认文字清楚；收到撤回后原位置消失；失败保留可恢复状态 |
| M08 | Copy Text、链接、格式、Pin/Unpin；O4、[MessageContextMenu][W11] | **部分，复制操作未执行**：长按原生消息菜单有按保存权限控制的复制文字；本轮未改剪贴板；无消息链接/富格式复制和消息置顶，现有置顶仍是会话置顶 | 长按文本复制完整多行内容；置顶测试消息并通过置顶栏定位；取消置顶后双端一致 |
| M09 | 多选、批量转发/删除；O4、[MessageSelectToolbar][W14] | **缺失** | 连续选择跨屏消息，数量准确；批量动作仅作用于已选项；返回退出选择模式，保持列表位置 |
| M10 | 反应、反应详情、收藏夹标签；O4、[MessageContextMenu][W11] | **缺失**；上游部分标签/反应功能受账号权限限制 | 添加/移除可用反应后双端一致；打开详情；带锁入口显示实际资格要求，不把受限操作伪造成功 |
| M11 | emoji、贴纸、GIF、收藏与搜索；O5、[SymbolMenu][W15] | **部分呈现**：animated emoji 保留可读表情，静态贴纸/动态缩略图和 GIF 媒体预览；完整动态贴纸、选择发送、收藏/搜索仍缺失 | 核对真实接收呈现；不得把静态缩略图写为完整动画播放通过 |
| M12 | 文本实体、链接、完整编辑器、AI Editor；O5、[Composer][W16]、[AiMessageEditorModal][W17] | **接收呈现部分实现**：原生 Span 及常见 `messageRichMessage` 区块、链接/剧透/引用/代码；真实群富内容已对照。全文加载/重试/超时有回归；发送仍是纯文本，完整富编辑/AI Editor 缺失 | 检查实体 UTF-16 偏移、嵌套与剧透，复杂区块和阅读全文继续真实验收；不得执行未信任 HTML；见 [MESSAGE_DISPLAY.md](MESSAGE_DISPLAY.md) |
| M13 | 静默发送、定时发送、对方上线时发送；[CustomSendMenu][W18] | **缺失** | 创建可撤销的测试定时消息，编辑/取消/立即发送；静默消息在接收端符合通知语义；入口随会话类型限制 |
| M14 | 草稿、回复/格式保留和跨端恢复；[Composer][W16] | **部分**：纯文字序列化保存、未改草稿不重写富属性、旧请求失败续发新版本；本地编辑后本会话不再采用其他设备新草稿；无完整富草稿编辑。本轮 Web 恢复比对为 true，新包多次覆盖保持登录，二次及最终编辑/图片关闭后的真机原草稿逐字比对均为 true | 跨端建立回复/格式草稿，仅打开再返回不能破坏属性；编辑、返回、重启后核对；注入旧请求失败且有新版本，不丢新文本或无限重试。O6 和本轮匹配记录不能覆盖全部边界 |
| M15 | 输入中状态、@提及、bot 命令与键盘；[Composer][W16] | **缺失** | 两端查看输入中状态开始/停止；选择群成员提及形成实体；测试机器人命令/按钮，不把按钮当普通不可用文字 |

## 媒体、文件与其他消息类型

| ID | Web A 基线与依据 | 当前工程状态 | 可验证验收步骤 |
| --- | --- | --- | --- |
| F01 | 图片发送、预览、说明及接收；O5/O6、[AttachMenu][W19]、[AttachmentModal][W12] | **部分且有双向跨端证据**：JPEG/PNG ≤10,000,000 字节，最多 10 项混选/预览/移除；正文草稿独立；当前聊天自动下载 ≤20 MiB 图片版本 | 已真机/Web 双向验证合成相册；URI 失效、磁盘满和极限大小仍待设备故障验收 |
| F02 | 多图/视频、分组相册、压缩与原文件、剧透、图像编辑；[AttachmentModal][W12] | **部分实现并真机验证**：最多 10 项照片/MP4/MOV 混选，TDLib 相册保持顺序、说明只在首项；两图加视频在鸿蒙/Web 双向通过。重排、分别发送、压缩质量、原文件、编辑和剧透揭示未实现 | 核对混合相册顺序、说明与逐项移除；失败/空项保留已有宿主机回归，真实断网恢复待验收 |
| F03 | 图片/视频全屏查看、前后切换、缩放、下载；[MediaViewer][W20] | **部分，核心链路真机通过**：前后浏览、图片双击/拖动、视频 AVPlayer 全屏播放/暂停/进度/静音/倍速、后台暂停及系统确认保存；正文草稿保持。视频已加入 TDLib 字节范围流式播放、未缓存定位及 B 站式基础手势，真机验证边界见 [VIDEO_PLAYER.md](VIDEO_PLAYER.md) | 连续双指、音频抢占、真实下载取消/失败、异常解码重试、保存取消待验收；详见 [MEDIA.md](MEDIA.md) |
| F04 | 任意允许的文件、音乐发送与下载管理；[AttachMenu][W19]、[AttachmentModal][W12] | **缺失**：非图片文件只显示类型文字，无文件选择/发送/打开/保存 | 发送合成 PDF、文本及音频文件；名称/大小/进度/取消/重试正确；下载后由系统合适应用打开，非法文件不静默成功 |
| F05 | 语音消息录制/取消/发送/播放；[VoiceRecordBar][W21]、[Audio][W22] | **缺失**：语音消息只有占位标签 | 允许和拒绝麦克风权限；录制、取消、预览、发送；播放进度/暂停/切后台和中断恢复正确 |
| F06 | 圆形视频消息、普通视频播放；[RoundVideoRecorder][W23]、[MediaViewer][W20] | **缺失** | 相机/麦克风授权拒绝与恢复；短视频录制/取消/发送；两端播放与前后台资源释放正确 |
| F07 | 投票、测验与结果；[PollModal][W24]、[PollResults][W25] | **缺失**：未映射为可操作内容 | 在允许投票的测试群创建投票/测验；投票、改选/撤回、查看结果、结束投票按权限工作 |
| F08 | 位置、联系人等特殊消息显示；[Location][W26]、[Message][W09] | **缺失**：位置类型文字/其他不支持标签；附件菜单未证实有原生「发送位置/联系人」入口，不将其冒充已现场确认的 Web 功能 | 对授权提供的各类型测试消息正确展示并打开对应详情；发送能力需先确认 Web 当前入口和条件后加入验收 |
| F09 | 媒体自动下载、缓存占用、清理与下载策略；O3/O7、[SettingsDataStorage][W27] | **部分实现/真机验证**：分类统计、选择性/按会话清缓存、保留期限/上限、按网络图片/视频/动图策略与流量统计；收藏夹视频缓存实际清理通过。后台清理、联系人级例外与上传暂存完整回收未完成，见 [存储管理](STORAGE_MANAGEMENT.md) | 分别调整联系人、其他私聊、群、频道的自动下载策略并验证；查看占用、断网查看已缓存内容；清理文件不损坏登录/草稿/消息索引；重开可按策略再下载 |
| F10 | 受保护内容、剧透和特殊有效期媒体；[Message][W09]、[MediaSpoiler][W28] | **部分保守处理**：不自动下载/揭示 secret 或 spoiler 图片，但没有用户主动查看流程与完整内容保护模型 | 对不同权限消息验证复制/转发/保存的可用性；剧透点击前不可见；有效期结束后不保留可继续打开的呈现 |

## 搜索、资料、群组与频道

| ID | Web A 基线与依据 | 当前工程状态 | 可验证验收步骤 |
| --- | --- | --- | --- |
| S01 | 全局聊天、频道、消息及媒体分类搜索；[LeftSearch][W29] | **缺失真实搜索**：右上角独立按钮打开原生 Search，取消/Back 保留主列表筛选与位置已在真机验证；仍只过滤已加载会话标题/最后消息摘要，联系人也仅本地匹配 | 搜索不在当前已加载列表的授权测试会话/历史消息；验证分页、清空、无结果、网络错误；不能返回仅本地子集却称全局搜索 |
| S02 | 单聊天 Search、日期/发送者及结果定位；O4、[MiddleSearch][W10] | **缺失** | 在聊天中搜索跨页测试关键词；上下条和日期定位正确；清空回原聊天，不切错会话 |
| S03 | 用户/群/频道资料、头像、简介、用户名和链接；O2、[Profile][W30] | **缺失完整详情**：只有简要聊天标题/状态与当前用户头像姓名 | 从标题和发送者进入正确详情；打开头像、复制公开链接、返回聊天；不存在/受隐私限制信息正常降级 |
| S04 | Shared Media / Files / Links / Music / GIF 等；[Profile][W30] | **缺失** | 各分类独立分页与空态；点击结果定位或打开正确媒体；删除更新后不留失效条目 |
| G01 | 新建群、频道和私聊；[NewChatButton][W31]、[NewChat][W32] | **部分**：仅已有联系人和收藏夹可开启私聊；无创建群/频道 | 用授权测试成员创建、设名称/头像、返回列表并双端验证；取消不创建；成员/名称错误可恢复 |
| G02 | 成员列表、邀请、加入申请、邀请链接；[ManageGroupMembers][W33]、[ManageInvites][W34] | **缺失** | 在测试群查看成员/分页、复制或撤销测试邀请；加入申请按管理员权限审核；普通成员不能越权 |
| G03 | 管理员、成员权限、移除/封禁、群公开性；[ManageGroupPermissions][W35]、[ManageGroup][W36] | **缺失** | 用普通成员/管理员两种角色对照菜单；保存权限后另一端实际生效；拒绝权限不能仅本地改显示 |
| G04 | 频道管理、发送与关联讨论；[ManageChannel][W37]、[ManageDiscussion][W38] | **缺失管理且发帖受限**：本工程把所有 channel 输入区视为只读，尚未区分有发帖权限的管理员 | 只读订阅者不能发；授权测试频道管理员可发帖；评论跳到正确讨论会话，返回原频道 |
| G05 | 论坛/话题、话题管理、消息线程/回复；[EditTopic][W39]、[MessageContextMenu][W11] | **缺失**：现有历史与发送均以聊天为单位，不是完整 topic/thread 模型 | 创建授权测试话题、独立草稿/未读/发送；同群不同话题不可串线；线程返回原消息位置 |
| G06 | 拉黑、举报、退出与删除会话；[SettingsPrivacyBlockedUsers][W40]、[DeleteChatModal][W41] | **缺失** | 拉黑/解除授权测试账号并双端验证；退出/删除测试群的确认范围准确；举报流程只核对入口与表单，避免无依据提交真实举报 |

## 设置、通知、通话与扩展能力

| ID | Web A 基线与依据 | 当前工程状态 | 可验证验收步骤 |
| --- | --- | --- | --- |
| P01 | 编辑个人资料、头像、公开用户名、简介及生日；O2/O3/O7、[SettingsEditProfile][W42] | **缺失**：只显示当前用户简要资料 | 修改授权测试账号资料并双端核对；取消保持原值；重名/长度/上传失败可恢复 |
| P02 | 外观、墙纸、键盘、性能/动画、贴纸/emoji 设置；O2/O3/O7、[SettingsGeneral][W43]、[SettingsMain][W58] | **部分**：浅色/深色/跟随系统，独立外观存储；真实账号跨覆盖安装/正常重启保留偏好、控制中心切深浅后即时跟随已真机验证，手势区颜色同步；无墙纸/字体等完整配置，系统定时自动变色未专门实测 | 改主题并重启验证；聊天墙纸、文字大小、输入行为改变后不影响内容；动画和贴纸播放选项实际生效；鸿蒙不照抄浏览器快捷键设置 |
| P03 | 通知声音、预览、私聊/群/频道、呼叫/角标及离线推送；O3、[SettingsNotifications][W44]、[pushNotification][W45] | **缺失平台通知链路**：会话静音不等于系统通知；只有前台轮询和消息状态 | 授权/拒绝系统通知，前台/后台/进程未显示时分别收测试消息；点击到正确会话；静音/预览/角标设置实际生效 |
| P04 | 隐私：最近上线、手机号/头像等可见性、例外名单、拉黑、内容过滤；O3/O7、[SettingsPrivacy][W46] | **缺失** | 保存测试隐私规则和例外，通过另一授权账号验证；重启后状态一致，错误不显示虚假已保存；内容过滤按账号/地区实际可用条件呈现 |
| P05 | 两步验证配置、设备会话管理、本地锁、自动删除等安全选项；O3/O7、[SettingsPrivacy][W46]、[SettingsActiveSessions][W47] | **部分鉴权**：能输入现有两步密码登录及安全存储本机密钥；不等于可管理两步密码/设备/本地应用锁 | 在明确授权的测试账号配置与撤销测试会话；验证当前会话保护和确认文案；本地锁解锁后恢复原页面；仅在合成测试会话验证自动删除及作用范围 |
| P06 | 语言、翻译消息及相关策略；O3、[SettingsLanguage][W48]、[MessageContextMenu][W11] | **缺失**：界面固定中文；无消息翻译 | 切换受支持语言、重启保存；翻译/显示原文可往返，不改消息原文；受限能力正确标识 |
| C01 | 一对一语音/视频呼叫、接听/拒绝/挂断/静音/相机；[PhoneCall][W49] | **缺失**：通话消息只有类型标签；TDLib 包存在不代表已接入音视频媒体引擎 | 两个授权测试端完成呼入/呼出、拒绝、忙线、网络中断及权限拒绝；检查音频路由、后台恢复和资源释放 |
| C02 | 群通话与视频参与者；[GroupCall][W50] | **缺失** | 测试群加入/退出、成员静音、管理员权限、多人音视频、重连；手机尺寸操作可达且不会误结束他人通话 |
| C03 | 屏幕分享；[vibecalls/utils][W51] | **缺失；Web 自身受环境限制**：上游检查 `getDisplayMedia`，不是所有手机浏览器可用 | 先记录 Web 当前环境入口是否启用；鸿蒙用平台允许的屏幕采集流程，拒绝/停止后释放采集；不以窄窗口截图推断手机 Web 可用 |
| X01 | Stories 列表、查看、回复/反应、已有 story 隐私管理；O1、[StoryViewer][W52]、[StorySettings][W53] | **缺失** | 浏览合成测试 story、前后切换、标记查看与回复/反应；尊重隐私及有效期。当前源码审查未证实创作/发布入口，不能把「能看」扩展为「能发」 |
| X02 | Premium、礼物、Stars / Gram Earnings、付费反应/收藏夹标签；O3/O4/O7、[PremiumMainModal][W54]、[MessageContextMenu][W11]、[SettingsMain][W58] | **缺失；受账号/地区/支付条件限制** | 验证权益与价格展示来自真实接口、锁定理由准确、取消不产生订单；支付仅按单独授权的测试流程验证，入口本身不算交易成功 |
| X03 | Bot、Mini App、附件 bot、内联操作；[AttachMenu][W19]、[WebAppTab][W55] | **缺失交互**：普通机器人文本可作为聊天消息出现，但无按钮/mini app 容器 | 使用授权测试 bot 验证命令、键盘、回调、返回；Mini App 权限、主题、关闭与消息发送边界正确 |
| X04 | 待办清单、富内容、AI 文本编辑、翻译语气等新增能力；[AttachMenu][W19]、[AiMessageEditorModal][W17] | **缺失；源码/账号条件需逐项确认** | 先核对现场当前账号入口及锁定条件，再以合成草稿验证预览/应用/撤销/发送；不以本项目「AI-native 开发」等同产品内 AI 功能 |
| X05 | Install App、浏览器特定快捷键/全屏等；O2、[useAppLayout][W01] | **平台映射项**：HarmonyOS 应用本身为原生安装；无需复刻 PWA 安装按钮 | 对齐用户最终能力：可安装、可启动、可返回；桌面专用键盘操作和浏览器安装文案不机械加入手机 UI |

## 与 Android / 原生端能力的边界

1. **语音视频、群通话、文件、投票、反应、Stories 浏览、多账号并非 Android 独有。** 上表已给出 Web A 的真实组件与操作路径，不得用「Web 没有」跳过这些差距。
2. **Web A 的设备设置中出现 Secret Chats 开关，不代表 Web A 本身能建立私密聊天。** [SettingsActiveSession][W56] 操作 `areSecretChatsEnabled`，其 [account API][W57] 修改指定会话的 `encryptedRequestsDisabled`。本次审查未发现 Web A 创建/发送私密聊天的运行时链路；当前对齐基线不擅自纳入 Android `SecretChatHelper` 一类原生私密聊天能力。若后续现场证明有该入口，再补精确范围。项目当前 `use_secret_chats:false` 也不能宣称支持。
3. Android 的短信自动读取/通话验证码辅助、系统通讯录导入、系统级常驻服务、小组件、分享接收器等平台集成，不因 Android 源码中存在就自动成为 Web A 手机尺寸功能。各项若另有用户要求，应单独定义鸿蒙平台目标；例如 Web A Contacts 列表不等于浏览器读了系统通讯录。
4. 屏幕共享、PWA 安装、离线推送、硬件快捷键和多窗口需要按环境判断。特别是 `isMobile` 为 true 时，上游群通话显式隐藏部分桌面全屏/视频固定控制；不能照搬桌面测试用例。
5. 位置/联系人等消息的**接收显示**与**发起发送**、Stories 的**查看**与**创作**、已有两步密码的**登录**与**设置管理**都分别验收，禁止由前者推断后者。

## HarmonyOS 实现约束与推进顺序

功能与数据语义参考 Web A，导航、返回、选择器、通知、权限、输入法和媒体资源生命周期按当前工程 SDK 的官方 ArkUI / HarmonyOS API 落地。沿用工程 [UI_GUIDELINES.md](UI_GUIDELINES.md)；页面使用 Navigation / NavDestination，列表与长历史使用合适的 List/LazyForEach，动作使用原生菜单/弹层/确认组件，媒体和文件选择继续走系统 Picker。不要为了复制 Web DOM 布局而重建浏览器外观。

建议按可独立验收的纵向功能推进，完整目标仍包含上表适用项：

1. **消息核心**：M04—M10（回复、编辑、转发、删除、多选、消息菜单、反应）连同正确权限与撤销/错误处理。
2. **查找与组织**：L02—L04、S01—S04（真实文件夹/归档、真实搜索、资料与共享媒体），避免继续增加只有外观的入口。
3. **完整媒体**：F02—F09（媒体查看器、文件、多图/视频、语音和缓存），先把文件状态/下载/上传/取消抽出可复用模型。
4. **账号与群管理**：P01—P06、G01—G06、L07；系统通知作为独立平台链路与前台轮询分开验证。
5. **通话和条件能力**：C01—C03、X01—X04，根据实际账号资格与平台环境完成，而不是用占位项冒充。

实现一行后更新其「当前状态」与独立运行证据。不能仅因为 SDK 编译或某条 mock 测试通过，就把整类功能改为已对齐；「完整对齐」要求所有适用行的验收和已知失败路径都有结果。付费/管理员/环境不满足的项应记录具体不适用原因，不能默认为通过。

## 固定版本源码索引

以下链接全部固定到同一提交，便于后续复核；文档中的 O1—O7 为独立现场记录，不与源码证据混算。

[W00]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/package.json
[W01]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/hooks/useAppLayout.ts
[W02]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/config.ts
[W03]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/components/left/main/Chat.tsx
[W04]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/components/left/settings/folders/SettingsFolders.tsx
[W05]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/components/left/main/Archive.tsx
[W06]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/components/main/NewContactModal.tsx
[W07]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/components/common/MainMenuDropdown.tsx
[W08]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/components/left/main/AccountMenuItems.tsx
[W09]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/components/middle/message/Message.tsx
[W10]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/components/middle/search/MiddleSearch.tsx
[W11]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/components/middle/message/MessageContextMenu.tsx
[W12]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/components/middle/composer/AttachmentModal.tsx
[W13]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/components/main/ForwardRecipientPicker.tsx
[W14]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/components/middle/MessageSelectToolbar.tsx
[W15]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/components/middle/composer/SymbolMenu.tsx
[W16]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/components/common/Composer.tsx
[W17]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/components/middle/composer/AiMessageEditorModal/AiMessageEditorModal.tsx
[W18]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/components/middle/composer/CustomSendMenu.tsx
[W19]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/components/middle/composer/AttachMenu.tsx
[W20]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/components/mediaViewer/MediaViewer.tsx
[W21]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/components/middle/composer/VoiceRecordBar.tsx
[W22]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/components/common/Audio.tsx
[W23]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/components/middle/composer/RoundVideoRecorder.tsx
[W24]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/components/modals/poll/PollModal.tsx
[W25]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/components/right/PollResults.tsx
[W26]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/components/middle/message/Location.tsx
[W27]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/components/left/settings/SettingsDataStorage.tsx
[W28]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/components/common/MediaSpoiler.tsx
[W29]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/components/left/search/LeftSearch.tsx
[W30]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/components/right/Profile.tsx
[W31]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/components/left/NewChatButton.tsx
[W32]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/components/left/newChat/NewChat.tsx
[W33]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/components/right/management/ManageGroupMembers.tsx
[W34]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/components/right/management/ManageInvites.tsx
[W35]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/components/right/management/ManageGroupPermissions.tsx
[W36]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/components/right/management/ManageGroup.tsx
[W37]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/components/right/management/ManageChannel.tsx
[W38]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/components/right/management/ManageDiscussion.tsx
[W39]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/components/right/EditTopic.tsx
[W40]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/components/left/settings/SettingsPrivacyBlockedUsers.tsx
[W41]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/components/common/DeleteChatModal.tsx
[W42]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/components/left/settings/SettingsEditProfile.tsx
[W43]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/components/left/settings/SettingsGeneral.tsx
[W44]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/components/left/settings/SettingsNotifications.tsx
[W45]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/serviceWorker/pushNotification.ts
[W46]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/components/left/settings/SettingsPrivacy.tsx
[W47]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/components/left/settings/SettingsActiveSessions.tsx
[W48]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/components/left/settings/SettingsLanguage.tsx
[W49]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/components/calls/phone/PhoneCall.tsx
[W50]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/components/calls/group/GroupCall.tsx
[W51]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/lib/vibecalls/utils.ts
[W52]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/components/story/StoryViewer.tsx
[W53]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/components/story/StorySettings.tsx
[W54]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/components/main/premium/PremiumMainModal.tsx
[W55]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/components/modals/browser/WebAppTab.tsx
[W56]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/components/left/settings/SettingsActiveSession.tsx
[W57]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/api/gramjs/methods/account.ts
[W58]: https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/src/components/left/settings/SettingsMain.tsx
