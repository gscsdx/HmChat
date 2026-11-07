# UI 与交互规范

本规范来自用户对原生、简洁、Telegram 核心行为及多形态适配的要求。它定义实现和验收目标，不代表这些目标已全部实测通过；实际覆盖见 [响应式验收记录](RESPONSIVE_VALIDATION.md)。

当前先验证手机单栏功能。真机可用时优先真机；用户已明确授权拔掉真机后使用手机模拟器继续测试，结果分开记录。多形态设计目标继续保留，但没有对应真机或用户尚未物理展开设备时，明确标记未验证，不能推断通过。

## 必须遵守的 HDS 组件与交互基线

本文件是项目唯一的常规界面设计入口，由 [AGENTS.md](../AGENTS.md) 强制引用；已有页面、新增页面与修复都适用。依据本机已安装 SDK 26.0.0.105 的官方声明和对应设备实测，不将「HDS 推荐」写成所有场景必须浮动，也不宣称 SDK 版本代表全球最新规范。

| 场景 | 本项目采用的官方能力 | 不继续采用的手工替代 |
| --- | --- | --- |
| 常规根页、设置和表单子页 | UIDesignKit HdsNavigation，统一 MINI 标题、返回和操作菜单 | 用 Row + 图片按钮拼整条导航栏 |
| 聊天详情与返回栈 | 同一 NavPathStack 上的 Navigation / NavDestination，沿用用户指定的原聊天标题栏 | 换样式时重建账号、会话、输入或导航状态 |
| 设置值、跳转行和开关 | HdsListItemCard，SuffixTextAndArrow / SuffixSwitch | 固定字号、文本箭头、独立拼接假系统开关行 |
| 普通分组长文 | ArkUI List / ListItemGroupStyle.CARD，正文自适应高度 | 对长文使用固定高度 CARD 行造成裁切 |
| 主操作、次要操作、文本操作 | ButtonStyleMode.EMPHASIZED / NORMAL / TEXTUAL | 每项都用强调色、固定圆角大按钮 |
| 搜索 | 官方 Search、取消/清空能力 | TextInput + 图片模拟 Search |
| 单选/多选 | 官方 Radio / Checkbox，选择与动作分开 | 用字符勾号模拟选择控件 |
| 消息上下文、常规更多操作 | Menu / MenuItem 或 promptAction.showActionMenu；聊天详情按用户要求保留原操作展开区 | 除已记录的聊天例外外，不用正文按钮模拟菜单 |
| 确认、选择目标、文件与媒体 | 官方确认框、Sheet、系统 Picker、ContentCover | 自制同类系统流程或在换样式时自动执行操作 |
| 底部主导航 | 已验证的 API 26 Tabs.barFloatingStyle + 系统材质/Symbol | 手工宽度、圆角和渐变模拟浮动底栏 |
| 全屏媒体与播放器 | 官方覆盖层、Image / AVPlayer / Slider 与原生手势 | 给沉浸媒体机械套设置页标题栏 |

官方入口：[HdsNavigation](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/ui-design-hdsnavigation)、[HdsNavDestination](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/ui-design-hdsnavdestination)、[HdsListItemCard](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/ui-design-hdslistitemcard)。API 可用性以本机 SDK 的正式声明为准；HDS 导航/列表能力均在当前 API 24 最低版本范围内，不为样式提高最低版本。新 API 仍须单独核验。

标准页面共用 HdsPage 标题容器，设置值共用 HdsSettingsRow；共用组件负责原生样式，不接管账号、请求、页面来源或持久化。常规内容从 MINI 标题栏下方布局，浮动/滚动内容必须显式避让标题、系统栏、键盘和底部导航。聊天详情按用户 2026-11-01 最新要求保留原紧凑标题栏、头像与操作展开区，使用原 Navigation / NavDestination，不套 HDS 浮动标题；保留消息 Scroller 和草稿；Cover 与 Sheet 继续绑定到不同节点。HDS 自定义 Symbol 必须使用语义 icon_primary 等颜色，以免深色标题栏出现黑色返回图标。

每轮交付逐页标注「已改源码」「SDK 编译」「指定设备启动/交互」「真实云端行为」；不因某一个页面使用 HDS 就推断全应用达标。当前设备范围仍是用户指定手机未展开形态；登录中的隐私输入不能为视觉验收代填，持有真实账号的设备不能退出、清数据或装 ohosTest 来制造截图。

## 功能基准与原生呈现

用户于 2026-10-29 明确指定：完整功能对齐已登录同一账号的 Telegram Web A 手机尺寸，UI/UX 采用鸿蒙官方推荐。首轮参考视口为 390 × 844 CSS px，开启 mobile/touch；这是参考网页的尺寸，不是鸿蒙 vp 断点或阔折叠验收尺寸。

功能清单与逐项证据维护在 [Web A 功能对齐矩阵](TELEGRAM_WEB_PARITY.md)。真实账号文件夹、归档、服务器搜索、消息操作、媒体、详情、设置等都属于对齐范围，不能用硬编码筛选或不可操作的入口冒充已实现。每项以用户可完成的操作和结果验收，受群权限、Premium 或浏览器能力限制的入口应明确区分。

| 用户意图 | 鸿蒙呈现原则 |
| --- | --- |
| 打开聊天、详情、搜索及返回 | 官方 Navigation / NavDestination 与 NavPathStack；聊天详情保留用户指定的原样式，返回恢复来源、搜索和阅读位置。 |
| 操作一条消息 | 官方长按菜单；操作随服务端权限变化，加载失败可重试，不猜测编辑/撤回权限。 |
| 回复、编辑 | 输入栏上方简洁上下文条；取消恢复原草稿，编辑内容与普通草稿隔离，失败保持输入。 |
| 选择转发目标 | 官方 Sheet 与 Search / List；明确所选会话，保留发送失败和重试状态。 |
| 删除、撤回等有影响的操作 | 官方确认框准确区分「仅为自己删除」与「为所有人删除」；不能把收到 TDLib 请求当作完成。 |
| 选图、文件、权限、分享 | 优先官方系统选择器和授权流程，不重复实现系统已有的完整界面。 |
| 搜索、设置与空状态 | 保留用户所需的动作与结果，不把协议、实现进度或开发说明放进日常界面。 |

Web 页面和原生应用的截图、消息及草稿均属于私有联调产物，只进入忽略目录；公开矩阵只记录功能标签、测试步骤和去敏结论。

图片预览使用官方 Image、[PinchGesture](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-arkui/arkui-ts/ts-basic-gestures-pinchgesture.md) / PanGesture / TapGesture 与 [bindContentCover](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-arkui/arkui-ts/ts-universal-attributes-modal-transition.md)。预览退出只关闭覆盖层，保持原会话和草稿；缩放/拖动以图片实际等比尺寸约束，避免移动到整屏看不到图片的位置。预览打开不自动分享、上传或复制图片。

本机真机联调确认：Sheet 与 ContentCover 必须绑定到不同真实组件节点。两者同节点时曾出现 Modal 创建后立即移除；[对应版本引擎的 CloseSheet](https://github.com/openharmony/arkui_ace_engine/blob/OpenHarmony-6.0-Release/frameworks/core/components_ng/pattern/overlay/overlay_manager.cpp#L5533) 在不存在 Sheet 时会按目标节点删除 Modal。当前 Sheet 绑定根节点，图片 Cover 绑定 NavDestination，已实测打开和关闭。不要合并回同节点。

全屏图片控件按当前窗口 TYPE_SYSTEM 避让区定位；真机上的 Cover 从窗口 y=0 布局，需要为内容加实际顶部内边距，不能用固定状态栏高度，也不能重复扣已经避让的底部。窗口背景在 loadContent 成功后设置，回前台重应用；导航栏颜色 API 不足以保证手势区背景，根背景单独扩展 SYSTEM/BOTTOM，输入布局继续 RESIZE。

## 官方原生界面

底部三个主入口使用 `Tabs` / `BottomTabBarStyle`。API 26 使用专用 `barFloatingStyle`，宽度、圆角由组件提供；按用户要求，`barBottomMargin` 从默认 28vp 调为 12vp，使底栏下移 16vp，真机验证与手势区的间距。材质使用 `systemMaterial` 接口的 `ULTRA_THIN`，不覆盖为固定百分比宽度或手工大胶囊。`maskColor` 明确透明，移除浮动栏背后的大面积渐变灰雾，防止其在系统手势区上缘突然结束；这不改变玻璃本体，也不使用整体 opacity 降低图标可读性。图标使用系统 `message / person_2 / gearshape` 及对应填充选中态，保留原生标签、字号与布局。依据为[官方浮动栏定义与示例 24](https://github.com/openharmony/docs/blob/f41b9345badd47c7ab0c263344cd7f4b5a549afb/zh-cn/application-dev/reference/apis-arkui/arkui-ts/ts-container-tabs.md#floatingtabbarwidth)与本机 SDK 26；普通底部 Tab 没有文档保证的常驻选中背板，不把 SubTab 的 BOARD 样式混称为底部默认样式。

工程最低版本保持 API 24，通过 `AttributeModifier<TabsAttribute>` 内的运行时判断才调用 API 26 浮动接口；低版本回退官方基础底栏模糊样式。`Tabs.index` 使用双向绑定，防止主题/资源更新将用户当前入口重置。底部内容已有滚动留白，不能因浮动样式让最后一项无法滚到可点击区域。

外观使用「跟随系统、浅色、深色」三态，设置行显示当前选择，原生菜单切换；偏好与实际生效的深浅色分开。跟随系统时使用 `COLOR_MODE_NOT_SET` 与 `ThemeColorMode.SYSTEM`，通过 `uiAppearance.getDarkMode()` 读取系统配置，避免从已被应用覆盖的 `context.config.colorMode` 推断系统颜色。配置变化、回前台及主窗口 `WINDOW_ACTIVE` 获焦时重新同步，覆盖控制中心收回但应用未切前后台的情况；另外通过官方 Environment → AppStorage 渲染事件接收颜色变化信号，必须先注册 envProp，再创建监听组件，不能直接混用 ArkUI 与 AbilityKit 数值相反的颜色枚举。固定选择不随系统改变。页面根背景按当前页同步到底部安全区，聊天/联系人用 surface，设置用 pageBackground，不用三键导航栏颜色 API 代替手势区背景。

本机当前已安装并用于本工程的 SDK 为 API 26、平台 `26.0.0`、组件版本 `26.0.0.105`，依据本机 `ets/oh-uni-package.json` 核验。这是当前工具链基线，不对外宣称全球最新 SDK。

应用界面使用官方 ArkUI / ArkTS，优先当前 SDK 的布局、列表、文本输入、导航和无障碍能力。禁止用 Android UI 兼容层、嵌入 Android 页面或 WebView 包装应用主体。原生 C++ / TDLib 负责协议，与选择原生 ArkUI 界面并不冲突。ArkUI 定位见 [华为官方介绍](https://developer.huawei.com/consumer/cn/arkui/)。

新增 API 需同时核对本机声明和工程兼容版本。不要为了调用一个新组件而擅自提高最低系统版本；必要时采用同一官方框架中的兼容实现。官方推荐的 HdsNavigation / NavPathStack 用于管理页面栈，但组件选择不能改变用户可观察的导航语义。[官方导航说明](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/ui/arkts-navigation-jump.md)

## Telegram 核心行为

以 [源码映射](TELEGRAM_SOURCE_MAP.md) 的固定版本为依据，保留以下行为：

- 会话列表是主要入口，选择会话进入对应聊天；返回恢复此前列表筛选和位置。
- 聊天列表不常驻搜索框，右上角使用独立的系统搜索图标按钮。点击后显示官方 Search 并聚焦；搜索期间隐藏底栏，取消或系统返回恢复原列表的筛选与滚动位置。从结果进入聊天再返回时保留搜索词与结果位置，不自动再弹键盘。联系人搜索独立，不随会话搜索改动。
- 会话行以头像、标题、最后消息、时间及必要状态为核心，不重复展示相同身份或模式说明。
- 置顶、静音、未读、草稿和消息发送状态有清楚语义，真实模式由服务器更新确认。
- 进入可见聊天后才执行与阅读相关的动作；离开、后台或切换到不可见栏后，不把未查看的新消息标已读。
- 输入草稿按会话保存；发送失败保留文本，不能因返回或重排丢失。
- 宽屏将同一会话列表与聊天呈现为主从双栏，切换宽窄不创建第二套账号或聊天状态。

参考官方行为不等于直接复制 Android View、布局代码、图标或品牌身份。HmChat 保留独立应用名称。

搜索实现需区分入口与数据能力：当前仅匹配已加载会话的标题/最后消息摘要，滚到结果尾部继续加载会话，仍不等于服务器全局消息搜索。主列表保留挂载，数据不受搜索词过滤，搜索期间固定其键盘出现前的高度；结果使用独立 Scroller，避免取消时因重建或 RESIZE 改变原列表位置。底栏通过 `barModifier.visibility` 显式切换 Hidden/Visible；正常与搜索状态均不叠加渐变遮罩，不覆盖官方浮动尺寸或材质。

## 简洁文案与状态

正常页面只保留帮助用户识别位置、内容和下一步操作的信息。删除宣传口号、装饰性副标题、重复模式标签和开发实现说明；例如「连接每一份热爱」「AI-native 架构」「ArkUI + C++ 引擎」不属于日常会话页面。

已登录设置页的个人卡片只显示头像与身份，不另放独立「账号信息」按钮。未登录的离线预览仍保留必要的登录入口。

本地模式仍需一个清楚的识别入口或简短标识，不能因为精简而让示例会话被误认为真实账号。无需在标题、每条会话和输入框下重复整段演示免责声明。消息状态如「本地」「发送失败」在确有意义的位置保留。

连接中、断网、认证失败、缺少应用配置、无权限和保存失败等必要状态必须可见。错误说明优先回答用户下一步如何处理；路径、SDK、ABI 和构建命令放到开发者入口或文档。普通登录使用手机号和验证码，不要求普通使用者申请应用 API 身份。

未实现的按钮应隐藏或禁用并在需要时给出简短原因，不制造可以成功完成操作的错觉。空状态使用简单的操作提示，不做宣传页。无障碍描述表达按钮动作，不堆叠内部技术名词。

## 以窗口可用 vp 为布局输入

响应式宽度来自当前窗口内的可用内容容器，单位为 `vp`。媒体查询要显式标注 `vp`，不依赖无单位时的像素默认值；也可通过布局尺寸回调或 Window API 观察变化。官方媒体查询支持根据尺寸变化更新布局。[官方媒体查询说明](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-v5/arkts-layout-development-media-query-V5)

本机 SDK 中已核对 `onAreaChange`、Window 的 `getWindowProperties()` / `windowSizeChange` 及 `UIContext` 对应单位转换接口。优先使用当前 UIContext 的单位转换，避免不同窗口密度下使用错误上下文。尺寸监听须解除订阅。

| 项目初始断点 | 宽度范围 | 期望表现 |
| --- | --- | --- |
| compact | `width < 600 vp` | 单栏列表或聊天；返回层级清楚，输入框始终可操作。 |
| medium | `600 <= width < 840 vp` | 过渡布局，可使用较窄会话栏的紧凑双栏；如果聊天或列表无法保持可操作宽度，退回栈式单栏。 |
| expanded | `width >= 840 vp` | 主从双栏；左侧会话列表，右侧所选聊天或简单选择提示。 |

这些是项目初始决策，不声称是所有鸿蒙应用必须使用的官方断点。修改断点时同步边界测试，至少检查 `599/600` 和 `839/840 vp`。宽度取连续值时以 `< 600`、`< 840` 比较，不通过四舍五入制造边界抖动。

## 内容宽度与操作区域

会话栏宽度受上下限约束，不能在大屏上无限扩张；聊天正文在宽面板内保持可读的最大内容宽度。气泡以内容为基础设置最大宽度，不能将短句拉成整屏色块。发送方和接收方对齐关系在各断点一致。

登录表单、设置和弹窗也要限制内容宽度，宽屏中居中或位于明确的详情栏。字体使用 `fp` 并适配系统字体缩放，布局间距与尺寸使用 `vp`。长名称、长 URL、大字号、空列表和失败消息都要能完整操作，不能靠缩小字体隐藏溢出。

尊重状态栏、手势区、挖孔、窗口装饰和软键盘。输入栏不能被键盘遮挡，列表可见区域随键盘调整；不能把键盘出现误判为离开会话。折叠区域若存在不可交互部分，应依据平台报告避让，不硬编码某个设备折痕坐标。

## 旋转、折叠、分屏的连续性

手机、平板、大屏、折叠和阔折叠分别作为测试分类，同一设备可因横屏、分屏或展开落在不同宽度类。代码不允许通过型号字符串判断单栏或双栏。

布局变化前后保留：当前账号与认证阶段、所选会话、输入草稿、搜索条件、会话列表滚动位置、消息列表可见消息锚点。滚动锚点应优先关联稳定消息 ID，尺寸变化后重新定位同一内容，不能固定回到顶部或底部。

宽窄切换不会重复登录、加载客户端或发送消息；若聊天仍可见，不因临时组件销毁重复触发阅读操作。只有用户从其他会话主动进入、主动滚动到底部等明确行为决定滚动跟随策略。具体用例与证据格式见 [RESPONSIVE_VALIDATION.md](RESPONSIVE_VALIDATION.md)。

## 消息展示必须保留数据语义

消息验收不能只看「收到一个字符串」。先检查固定 schema 的 `messageText`/`messageRichMessage`、格式实体、转发来源、回复、服务消息和媒体数据；通用占位必须记录具体 content type，避免把协议解析缺失误判为样式问题。`messageRichMessage` 是区块树，不得扁平化后丢掉所有结构或用 WebView 执行内容。

同发送者连续消息减少重复姓名和间隔；组尾头像、系统消息、转发、回复、说明与元信息分别保留角色。短句按内容收缩，媒体遵循宽高比，相册不得以奇数空白格代替排版；时间尽量随正文末行或叠加在无说明媒体上。双勾取服务器已读语义；剧透正文和回复摘要均不得自动揭示。

每次修改消息展示，应在同一授权账户下对照 Web 手机尺寸中的真实群消息，并用合成素材测试可写操作。原始群截图不得公开；结果区分解析/单元测试、编译、真机呈现与服务端操作。最近基线与限制见 [MESSAGE_DISPLAY.md](MESSAGE_DISPLAY.md)。

## 存储与下载设置

存储管理采用原生 DataPanel 环形统计、Checkbox 分类选择、Toggle 开关及系统确认/选项弹层。清理前说明作用范围，完成后显示 TDLib 实际释放量；数据库、账号与上传暂存不混入可删除媒体类别。设置行使用独立的响应式组件属性，避免将变化中的开关/摘要作为普通 Builder 值冻结。保存中阻止重复提交，失败恢复已保存值并给出可重试错误。默认保留缓存，不能为了统计页面演示主动清理用户文件。

## 视频播放器的移动端手势

以移动端 B 站式意图组织原生播放器：单击显隐、双击播放/暂停、水平滑动预览/提交定位、长按临时 2 倍速/松手恢复原选定倍速；保留可发现的进度、倍速和前后 30 秒按钮。暂停时长按不能偷偷启动播放，定位后恢复用户原先的播放/暂停意图，退后台后回来保持暂停。

控制栏贴播放器容器底部、低干扰渐变；拖动反馈居中、临时倍速提示在上方。用 Stack 的实际子项对齐/满容器覆盖层定位，不把通用 align modifier 当成底部锚定。按钮使用系统 Symbol 与原生 Slider/弹层。缓冲中的目标进度与已确认时钟分开，不能让旧 timeUpdate 把用户刚拖动的预览拉回。所有「通过」以真机 native seekDone/speedDone、画面/时钟推进和手势复验为准。

## 既有页面 HDS 迁移范围（2026-10-31—2026-11-01）

| 页面/区域 | 本轮源码调整 | 验收边界 |
| --- | --- | --- |
| 聊天列表 | 共用 HdsPage，官方新建/搜索图标入口，Tabs / SubTabBarStyle 筛选 | 主列表与搜索结果分别保持原 Scroller / 状态，底栏仍为已验证浮动 Tabs |
| 联系人 | 共用 HdsPage、官方 Search | 头像、在线状态、真实联系人语义保留 |
| 设置与外观入口 | HdsPage + HdsSettingsRow / HdsListItemCard | 外观仍用官方三选项菜单，偏好不重置 |
| 账户管理 | HdsPage、HDS 添加账户行 | 不为视觉验收切换或新增真实账号 |
| 账号就绪与认证页 | HdsPage、官方按钮层级，保留原生 TextInput / 国家地区 Sheet | 已登录就绪页可实测；手机号/验证码/密码流程不代为提交，不能把就绪页验收当成所有认证阶段通过 |
| 关于与欢迎页 | 关于采用 HdsPage；欢迎保留启动品牌场景并使用官方主操作按钮 | 品牌启动页不机械增加返回按钮 |
| 存储、自动下载、网络用量 | HdsPage；设置值用 HDS 行，开关用 SuffixSwitch | 不为演示清缓存、重置网络计数或修改原有自动下载策略 |
| 聊天详情 | 按用户最新要求恢复迁移前的头像、紧凑标题栏、会话操作展开区和 Navigation / NavDestination；移除 HDS 标题的额外顶部避让 | 保留消息 Scroller、草稿、回复/编辑与媒体；其他设置页的 HDS 调整继续保留 |
| 转发目标 Sheet | 保留系统 Sheet / Search / List，使用官方 Radio 和主操作按钮 | 选择与最终转发分开，不向其他联系人代发测试内容 |
| 图片/视频与播放器 | 保留独立 ContentCover、窗口避让、系统选择器和既有原生播放器手势 | 沉浸场景不套普通设置页外壳；Cover 与 Sheet 必须继续使用不同宿主节点 |

消息气泡、相册、用户头像等 Telegram 领域呈现继续由专用组件承担，使用官方基础布局和手势；它们不是通用设置行，不为套用 HdsListItemCard 而丢失回复、剧透、说明、时间、未读或真实发送状态。迁移状态、实际截图与逐项结果以 STATUS.md / RESPONSIVE_VALIDATION.md 为准。
