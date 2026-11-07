# Telegram Android 源码阅读与鸿蒙映射

核验日期：2026-10-29。本文记录已经阅读的官方源码及迁移设计，不代表对应功能已经全部实现。当前交付范围以项目 README 和验证记录为准。

## 参考版本

- 官方仓库：[DrKLO/Telegram](https://github.com/DrKLO/Telegram)。
- 阅读基线：[3de37c8cfb039452be7398909461da6288babf15](https://github.com/DrKLO/Telegram/commit/3de37c8cfb039452be7398909461da6288babf15)。提交说明为「update to 13.1.1 (7237)」，提交日期为 2026-10-25。
- 下列源码链接固定到该提交，后续 agent 可以复查同一版本，避免 master 变化造成理解偏差。

## 已阅读的主链路

| Android 源码 | 实际观察 | HarmonyOS NEXT 对应设计 |
| --- | --- | --- |
| [DialogsActivity.java](https://github.com/DrKLO/Telegram/blob/3de37c8cfb039452be7398909461da6288babf15/TMessagesProj/src/main/java/org/telegram/ui/DialogsActivity.java#L286) | 会话页继承 BaseFragment；使用 RecyclerListView 和 DialogsAdapter；加载入口在 `loadDialogs`，长按入口支持会话操作。 | 使用 ArkUI List、独立会话行组件与显式筛选状态；保留未读、置顶、静音、草稿等产品语义。不要把整个 Activity 机械翻译成一个巨型 .ets。 |
| [ChatActivity.java](https://github.com/DrKLO/Telegram/blob/3de37c8cfb039452be7398909461da6288babf15/TMessagesProj/src/main/java/org/telegram/ui/ChatActivity.java#L372) | 聊天页面聚合消息历史、消息单元和输入栏；约第 7858 行创建 ChatActivityEnterView；ChatActivityAdapter 负责消息视图。 | ArkUI 聊天页组合消息列表、气泡和输入栏；聊天状态从数据层获得，页面不负责协议、数据库或网络重试。 |
| [MessagesController.java](https://github.com/DrKLO/Telegram/blob/3de37c8cfb039452be7398909461da6288babf15/TMessagesProj/src/main/java/org/telegram/messenger/MessagesController.java#L144) | 控制层分别提供历史加载、会话加载、加载结果处理、服务端更新处理；关键入口为 `loadMessages`、`loadDialogs`、`processLoadedDialogs`、`processUpdates`。 | 定义聊天领域模型和仓储边界；本地演示仓储与真实 Telegram 仓储分别实现。在线仓储把 TDLib 更新转换为应用状态，避免界面直接依赖原始 JSON。 |
| [ConnectionsManager.java](https://github.com/DrKLO/Telegram/blob/3de37c8cfb039452be7398909461da6288babf15/TMessagesProj/src/main/java/org/telegram/tgnet/ConnectionsManager.java#L360) | `sendRequest` 将 TLObject 请求下沉至 native 方法；JNI 入口约在第 1001 行之后。 | 不保留 Android JNI 绑定；通过鸿蒙 Node-API 绑定独立的 TDLib C 接口。 |
| [ConnectionsManager.cpp](https://github.com/DrKLO/Telegram/blob/3de37c8cfb039452be7398909461da6288babf15/TMessagesProj/jni/tgnet/ConnectionsManager.cpp#L1951) | 原生实现处理连接数据、请求调度、数据中心初始化和客户端初始化。 | 协议层交给 TDLib；避免自行重写 MTProto 加密、密钥交换、重连和更新差分。 |
| [MessagesStorage.java](https://github.com/DrKLO/Telegram/blob/3de37c8cfb039452be7398909461da6288babf15/TMessagesProj/src/main/java/org/telegram/messenger/MessagesStorage.java#L16924) | `getDialogs` 读取本地数据，并把结果交给控制层；Android 版本包含自己的存储封装。 | 演示数据使用本地存储；真实账号的会话与消息数据库由 TDLib 管理。不要把演示数据结构当作完整 Telegram 数据库。 |
| [SendMessagesHelper.java](https://github.com/DrKLO/Telegram/blob/3de37c8cfb039452be7398909461da6288babf15/TMessagesProj/src/main/java/org/telegram/messenger/SendMessagesHelper.java#L4425) | 发送入口与媒体发送准备逻辑分开，涉及文本、文档、音频和图片。 | 首先完成文本发送状态机，再分别接入媒体选择、上传、进度、取消和失败恢复。 |

以上是根据源码结构作出的迁移设计判断；并非 Telegram 官方对鸿蒙版本的架构建议。阅读覆盖关键入口与相关调用位置，不宣称逐行审计整个 Android 仓库。

## 迁移边界

Android 源码用于理解功能与交互：会话列表、未读计数、消息状态、草稿、收藏、归档和联系人。Android View、Activity、RecyclerView、JNI 与 Gradle 构建链不能直接成为 HarmonyOS NEXT 的 ArkUI 应用。

本项目的目标结构是：

```text
ArkUI 页面与组件
        ↓ 用户动作 / 可观察状态
聊天领域模型与仓储接口
        ├─ 本地演示实现：可离线验证交互，明确标注演示状态
        └─ Telegram 实现：认证、更新归并、聊天和消息映射
                   ↓ JSON 请求 / 更新
              鸿蒙 Node-API 桥
                   ↓ C ABI
                  TDLib
                   ↓
             Telegram 服务端
```

下列内容必须明确区分：

- 「本地发送」只代表消息写入本地演示数据；不能显示成服务端已送达。
- 「Native 桥可加载」只代表 ArkTS 与 C++ 链路可用；不能显示成 Telegram 已连接。
- 「TDLib 可创建实例」不代表已登录；只有收到服务端认证就绪状态后才能进入真实账号模式。
- 「模拟器通过」不能替代真机上的网络、后台、通知和安全存储验证。

## 功能推进顺序与验收证据

| 阶段 | 功能闭环 | 必须保存的证据 |
| --- | --- | --- |
| 原生壳 | 会话列表 → 聊天 → 本地输入与持久化；搜索与筛选 | 构建退出码、HAP 路径、设备启动结果、核心页面截图 |
| 协议引擎 | OHOS ABI 的 TDLib 动态库 → Node-API → 认证状态更新 | 固定源码提交、构建命令、ELF 架构、动态依赖、运行结果 |
| 账号 | 参数 → 手机号 → 验证码 → 可选二次密码 → Ready | 去敏后的状态迁移记录；不保存手机号、验证码、密码、会话密钥 |
| 云端消息 | 加载会话 → 历史分页 → 发送文本 → 收到新消息 | 两端实测、失败处理、重启恢复、读状态同步 |
| 完整客户端 | 媒体、通知、后台、群组权限、频道等 | 按特性建立独立验收清单，逐项标记已验证或待实现 |

## 来源与分发记录

Android 仓库的 [LICENSE](https://github.com/DrKLO/Telegram/blob/3de37c8cfb039452be7398909461da6288babf15/LICENSE) 提供 GPL v2 全文；已检查的 [ChatActivity.java 文件头](https://github.com/DrKLO/Telegram/blob/3de37c8cfb039452be7398909461da6288babf15/TMessagesProj/src/main/java/org/telegram/ui/ChatActivity.java#L1-L6) 明确为 GPL v2 或更高版本（GPL-2.0-or-later），版权 Nikolai Kudashov。第三方目录仍须逐项核对，不能将整个 Android 依赖树统称为同一许可。当前本工程将 Android 作为架构和行为参考，未直接复制 Java / JNI 实现。若后续复制或翻译其中实现，应在对应文件注明来源、原作者、上游提交和改动，并保留许可材料；分发时按所使用代码的许可证提供相应源代码。项目自有代码的 GPL-3.0-or-later 授权及实际依赖清单见 [LICENSING.md](LICENSING.md) 与 [第三方通知](../THIRD_PARTY_NOTICES.md)。

项目使用独立名称 HmChat。Telegram 官方 [创建客户端说明](https://github.com/DrKLO/Telegram/blob/3de37c8cfb039452be7398909461da6288babf15/README.md) 要求开发者申请自己的 API ID、避免冒充官方应用、避免使用标准官方图标。代码许可证与 Telegram API 使用条款是不同的约束，接入说明见 [TELEGRAM_INTEGRATION.md](TELEGRAM_INTEGRATION.md)。

## 给后续 AI agent 的阅读规则

1. 修改具体行为前，先定位上表中对应入口；需要更多上下文时按固定提交拉取文件。
2. 先写输入、输出和失败状态，再改 UI；协议字段以固定 TDLib schema 为准。
3. 把观察、推断、实现与验证分开记录；没有运行证据的步骤不能标记完成。
4. 上游更新必须同时更新源码提交、schema 适配与回归记录，不能只替换 .so。
