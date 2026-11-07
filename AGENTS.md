# HmChat 开发约定

## 接力入口

每次开始任务，先读 `docs/STATUS.md`、本文件，以及本次改动涉及的源码。`docs/STATUS.md` 记录当前进度、最后验证、已知限制和下一步；它不是凭空推断完成度的依据。随后按需读：

- `README.md`：项目范围与启动入口。
- `docs/ARCHITECTURE.md`：模块边界与数据流。
- `docs/AI_WORKFLOW.md`：证据、协作和交付规则。
- [docs/UI_GUIDELINES.md](docs/UI_GUIDELINES.md)：所有 UI 改动必读的 HDS / ArkUI 设计规范、组件映射、交互约束与逐页验收要求。
- `docs/RESPONSIVE_VALIDATION.md`：窗口断点、多设备形态与设计/实测验收矩阵。
- `docs/DEVELOPMENT.md`：DevEco 工具链、脚本与设备使用。
- `docs/TELEGRAM_SOURCE_MAP.md`、`docs/TELEGRAM_INTEGRATION.md`：上游源码依据与 TDLib 接入约束。
- `docs/ROADMAP.md`：尚未完成的能力与验收条件。

默认用中文沟通；中文正文中的引号使用「中文引号」。技术标识和代码保持原样。

## 工作循环

功能验收以用户已登录的 [Telegram Web A](https://web.telegram.org/a/) 手机尺寸为基准，完整范围见 `docs/TELEGRAM_WEB_PARITY.md`。不得把「核心聊天可用」或某一批功能完成写成全面对齐；每个能力都要记录参考入口、协议实现、鸿蒙交互和真实验收。Web 未提供或受账号权限限制的能力单独注明，不从 Android 能力表推断 Web 具有。用户明确要求 UI/UX 按鸿蒙官方推荐实现：功能结果和用户意图与 Web 一致，呈现采用官方 ArkUI 导航、菜单、弹层、选择器与系统能力。

当前阶段先完成手机单栏的真实功能和 UI/UX。用户指定阔折叠真机可用时优先未展开形态；用户拔掉真机后已授权手机模拟器继续开发验收。其他设备、展开形态和多窗口适配留到后续；不要因为规范中有未来矩阵就擅自扩展本轮范围。优先修复系统栏、官方底部导航材质、头像、消息与媒体等真实使用问题。

1. **读证据**：定位用户要求涉及的现有代码和上游固定版本，区分事实、推断与设计。协议字段以项目固定 TDLib schema 为准。
2. **做小变更**：明确修改边界和可验证的行为；保留其他 agent 或用户的改动。不为功能移植顺带重写工程、签名或工具链。
3. **跑检查**：领域逻辑先跑对应测试；ArkTS 和 Native 修改必须通过真实 SDK 编译。不要用 TypeScript 检查代替 ArkTS 编译。
4. **真机验收**：使用已连接且用户指定的真机；以 `HDC_TARGET` 显式指定目标。真机可用时优先真机；本轮用户已明确授权拔掉真机后切换手机模拟器。安装、启动、截图和交互分别记录结果。
5. **更新接力**：在 `docs/STATUS.md` 记录修改、命令、结果、未验证项与下一步。只把实际通过的步骤写为通过。

## 模块职责

| 位置 / 模块 | 职责 |
| --- | --- |
| `entry/src/main/ets/pages/Index.ets` | ArkUI 导航、界面状态、用户动作和渲染；不直接调用 TDLib C ABI。 |
| `entry/src/main/ets/components/HdsPage.ets`、`HdsSettingsRow.ets` | 共用 HDS 标题、操作菜单和设置行呈现；不接管账号、协议、路由来源或持久化。具体约束见 [UI_GUIDELINES.md](docs/UI_GUIDELINES.md)。 |
| `entry/src/main/ets/model/ChatModels.ts` | 聊天领域类型，保留消息发送状态和账号数据语义。 |
| `entry/src/main/ets/data/ChatRepository.ts` | 内存会话、消息、草稿与模式边界；本地操作不能伪造云端确认。 |
| `entry/src/main/ets/data/DemoData.ts` | 明确标注的虚构离线数据，不放真实用户数据。 |
| `entry/src/main/ets/telegram/TelegramClient.ts` | 可独立测试的 TDLib JSON 协议、认证状态、请求关联与更新归并。 |
| `entry/src/main/ets/telegram/TdTypes.ts` | TDLib 请求、响应与更新的显式类型。 |
| `entry/src/main/ets/services/TelegramService.ets` | HarmonyOS 生命周期、Native 调用、轮询与订阅适配。 |
| `entry/src/main/ets/services/CredentialVault.ets` | HarmonyOS Asset 安全存储适配，保护数据库密钥与敏感配置。 |
| `entry/src/main/ets/services/LocalStore.ets` | 演示模式 Preferences 持久化；真实消息由 TDLib 加密数据库持有。 |
| `entry/src/main/ets/services/AppearancePreferences.ets`、`WindowAppearance.ets` | 独立保存三态外观偏好，读取系统生效色并同步页面/窗口；不依赖演示快照写入或账号状态。 |
| `entry/src/main/cpp/` | Node-API 桥与 CMake；只负责受控传输，不承载 UI 或领域业务。 |
| `scripts/` | 可复现构建、安装、启动、截图、测试及第三方库构建。 |
| `docs/` | 决策、证据、操作和接力说明；变更行为时同步相关文档。 |

真实接入模块仍在迭代，具体行为和验证状态以当前源码和 `docs/STATUS.md` 为准。

## ArkTS 与 Native 约束

- 使用本机当前工程工具链的官方 HarmonyOS SDK 26 / ArkUI；已核对安装版本为 `26.0.0.105`。这是本机基线，不宣称全球最新版本。不得用 Android UI 兼容层或 WebView 包装页面替代原生应用界面。
- `.ets` 使用当前 SDK 接受的 ArkTS 子集：显式类型、声明过的模型、确定的对象结构；避免 `any`、`unknown`、动态原型与依赖 JavaScript 反射的写法。
- 可测试的纯逻辑放 `.ts`，HarmonyOS Kit 和组件生命周期留在 `.ets`。变更跨边界接口时，同时检查 `.d.ts`、Native 导出和 Preview mock。
- TDLib 的 `int64` 以字符串处理，按 schema 区分 `int53`。会话排序值不能直接转 Number。
- Native `receive()` 使用零超时和单消费者语义，立即复制 TDLib 返回数据。不得在 ArkUI 主线程做秒级阻塞接收。
- 缺少 `.so`、认证失败、不支持的认证状态必须明确呈现，禁止伪造 Ready 或静默切换到演示成功。
- 加入媒体、数据库或依赖前，核实 OHOS ABI 和动态依赖；不能把 Android `.so` 直接当 OHOS 库。

## UI 与响应式规则

- 开始任何 UI / UX 改动前，必须阅读并遵守 [独立设计规范](docs/UI_GUIDELINES.md)。已有页面也适用；新增例外须记录具体 SDK / 能力依据和替代方案，不能只因「已用原生组件」就视为采用官方样式。
- 本机 SDK 已提供相应 HDS 能力时，标准页面优先使用 UIDesignKit 的 HdsNavigation / HdsNavDestination、HdsListItemCard 及官方按钮层级；标题、返回、操作菜单、列表选择与开关由对应组件提供。保留用户意图和 Telegram 数据语义，不再用 Row、图片按钮或固定大胶囊模拟系统导航与设置行。专用媒体全屏页按沉浸场景处理，不强制套通用浮动标题栏。
- 用户已明确要求聊天详情沿用 HDS 迁移前的样式：保留既有头像、紧凑标题栏、会话操作展开区、消息与输入区，以及 Navigation / NavDestination 返回栈。不要再次以统一 HDS 样式为由替换；设置类页面继续使用 HDS。
- UI 验收必须包含首屏和滚动后的标题避让、末项/底栏/键盘可达性、浅深色对比度、页面/系统返回、草稿与选择保留；只在已连接指定设备上通过的形态记录为实测。组件选择与当前页面迁移清单持续维护在独立设计规范中，不在 AGENTS.md 重复堆放样式细节。
- 导航、会话打开与返回、未读、草稿、发送状态遵循 Telegram 核心行为；用官方 ArkUI 组件实现，不机械复制 Android 布局代码。
- 区分「使用官方基础组件」和「采用官方组件样式」。SDK 已有专用样式时优先使用，例如 API 26 底部导航使用 `Tabs.barFloatingStyle` 与系统 Symbol，不再用通用 modifier 拼接宽高、圆角和背景来冒充官方浮动底栏。视觉效果仍须真机截图验收。
- 保持界面简洁，不加入宣传口号、重复模式标签或面向开发者的实现说明。保留必要错误、连接、登录和本地模式识别，技术详情放开发文档或明确的开发者入口。
- 外观提供浅色、深色、跟随系统；偏好与实际生效颜色分开，真实账号下也必须保存并跨重启保持。系统变化不能覆盖用户固定选择。底栏保留官方玻璃材质，避免额外渐变遮罩在手势区边缘产生色差；根背景与当前页面一致。
- 按当前窗口/内容容器实际可用宽度 `vp` 响应，初始断点为 `compact < 600`、`600 <= medium < 840`、`expanded >= 840`。不要用设备型号、屏幕物理像素或「是否平板」直接决定布局。
- 手机、平板、大屏、折叠和阔折叠设备均覆盖横竖屏、分屏与窗口变化；宽屏采用会话列表与聊天主从双栏，限制聊天正文和气泡最大宽度。
- 旋转、折叠、展开和跨断点只改变布局，不重置账号、当前会话、草稿、搜索条件或滚动锚点，不重复发送请求，不把布局重建误当用户进入会话。
- 修改 UI 后必须更新响应式验收记录。设计检查与对应形态真机测试分别记录，不能以一个窗口通过推断所有形态通过。额外设备形态未验证时如实标注；物理折叠、展开等由用户在指定真机上操作后再验收。

## 脚本、设备与签名

Windows 工作副本的缓存与产物统一放在工程外的缓存根（`<cache-root>`），工程内 `.local`、`artifacts`、`.hvigor`、`entry/build`、`oh_modules`、`node_modules` 是指向该缓存根的目录联接。DevEco clean 或重新安装依赖后若联接丢失，运行 `scripts/cache-layout.ps1` 修复；不要把这些位置的实际内容提交到 Git。

优先 `scripts/doctor.sh`、`build.sh`、`install.sh`、`run.sh`、`screenshot.sh`，脚本做不到的部分才操作 DevEco UI。真机可用时优先真机。用户已于 2026-10-29 明确授权真机拔除后使用手机模拟器继续功能测试；模拟器通过不代表阔折叠真机或展开形态通过。多个设备在线必须指定 `HDC_TARGET`，不得随意选首个设备。

现有 `build-profile.json5` 含用户已经配置的签名，默认不得修改或输出其完整内容。不得泄露证书密码、私钥、签名文件、手机号、验证码、二步验证密码、API 私密配置、认证会话或消息正文。诊断只读取必要且可公开的字段。

构建期间不要并发运行另一份 Hvigor。原生依赖构建与源码工作可并行，但包装 HAP 前必须确定依赖产物已完整生成。

## 真实账号与数据

- 用户自行输入手机号、验证码和二步验证密码。未经用户明确授权，不代为请求验证码、提交验证码、登录账号或向真实联系人发消息。
- 真实账号联调优先停在可供用户自行操作的登录界面；自动化只使用虚构数据或明确授权的测试账号与动作。当前用户已要求 agent 自行测试功能，可在自己的收藏夹中使用明确的测试内容；不得向其他联系人代发，不得上传私人相册内容，测试前保存并最终恢复已有草稿。
- 演示模式与真实模式的状态、持久化和 UI 标识必须隔离；本地写入不代表云端送达。账号切换要阻止旧客户端更新污染新状态。
- 数据库加密密钥与敏感配置使用 HarmonyOS Asset 安全存储；消息数据库放应用沙箱。不要把真实消息复制到 Preferences 快照。
- 私密配置、签名、数据库、会话文件、截图中的个人信息、构建日志中的秘密均不得进入 Git。添加文件前检查 `.gitignore` 与实际内容。
- 只使用开发者自行申请的 API 配置，不内置 Telegram 官方应用或示例凭据。用户把配置写入被忽略的 `config/telegram.local.json`，无需发到聊天；`scripts/configure-telegram.sh` 生成同样被忽略的 `entry/src/main/ets/config/TelegramBuildConfig.ets`。无配置可以构建 smoke/UI 版本，但不能进行手机号鉴权；正式发布必须通过配置检查与 release guard。
- 项目计划公开源码，提交前检查暂存区和历史中的敏感文件。API 私密文件、生成配置、签名和用户数据不因开源需求而加入 Git。不得为形成提交历史而提交用户的配置。
- 每次 commit 前必须检查完整暂存区的文件清单和实际内容，确认源码、文档、测试样例、日志及图片中均无隐私或秘密；特别检查手机号、真实消息、账号标识、私人部署域名、Token、Authorization 头、API 凭据、签名和本机绝对路径。示例使用虚构数据或占位符，提交说明也不得包含敏感信息。不能仅依赖 `.gitignore` 或自动扫描；发现泄露先移出暂存区并脱敏，再重新检查，通过后才能提交。

## 协作与交付

并行 agent 必须划分文件所有权，交叉修改先沟通。共享工作目录中不运行会覆盖他人改动的 reset、clean 或大范围格式化。用户要求的功能尚未完成时继续推进，遇到依赖阻塞则记录具体缺口和已验证结果。

交付必须分别说明「源码已实现」「编译通过」「设备启动通过」「真实服务端验证通过」；截图、stub、mock 与 UI 展示不能替代真实服务端证据。

## 测试安装隔离

持有用户真实会话的设备不得运行同 bundle 的 ohosTest 安装/卸载循环。2026-10-29 的试验发现测试后安全存储与原数据库的恢复异常，尚不能用模块卸载成功推断其他账号数据安全。使用正常 signed HAP 的覆盖安装、限定 bundle 的界面操作和去敏截图验证；需要设备测试包时，另用没有用户数据的隔离实例。不得为了测试清数据库、导出密钥或让新密钥复用旧数据库目录。

## 公开发布与配图

- 公开前阅读 [PUBLIC_ASSETS.md](docs/PUBLIC_ASSETS.md) 与 [LICENSING.md](docs/LICENSING.md)。README 默认中文，README.en.md 同步更新；功能必须区分已实现、已验证与路线图。
- README 与官网只使用经过人工复核、移除非必要元数据、登记 SHA-256 的脱敏成品。原始截图和未采用设计稿不进入公开树。更新图片后同时更新 config/public-assets.json，不能把自动更新哈希当作隐私审查。
- 官网源码在 website/，使用 GitHub Pages 发布；不得把整个工程或 ignored artifacts 当作网站产物上传。不引入分析追踪、外部字体或账号数据。
- Git 安全检查读取完整 index，即使只提交部分变更也检查最终公开快照。当前初始公开为源码，不代表二进制已经满足 Telegram 服务条款和完整发行条件。
