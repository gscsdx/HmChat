# FlClashX-OHOS 勘察基线（融合进 HmChat）

- 勘察对象：`source-refs/FlClashX-ohos/`（FlClashX 的 HarmonyOS / Flutter-OHOS 子工程副本）
- 勘察日期：2026-11-05
- 勘察方式：只读源码、配置、资源清单与已构建原生库元数据；未构建、未安装、未运行设备命令、未修改签名
- 文档范围：为「把 FlClash 能力融合进 HmChat（纯 ArkTS/ArkUI 原生 Telegram 客户端）」提供可执行的移植基线
- 敏感信息：本文不记录任何证书、密码、profile、密钥、签名文件内容，也不记录真实账号、订阅链接或消息内容（勘察范围内未发现此类配置）

## 状态标记

| 标记 | 含义 |
| --- | --- |
| 【事实】 | 由本副本源码、配置、资源清单或二进制元数据直接确认 |
| 【推断】 | 由代码注释、接口契约、二进制字符串或运行架构推导，缺少对应实现文件佐证 |
| 【待确认】 | 必须在补齐上游源码、真实 SDK 编译或真机验证后才能定论 |

> 本副本不是完整 FlClashX 仓库，而是其 `ohos/` 子工程。`lib/`（Dart UI/业务）、`core/`（Go/mihomo 桥接与构建脚本）、`pubspec.yaml` 均不存在；凡是依赖这三处的结论都标为【推断】或【待确认】。

---

## 1. 结论先行

1. 【事实】这是一个 **Flutter-OHOS 宿主 + ArkTS 服务壳 + Go 内核** 的混合工程：Flutter 负责 UI 与大部分业务（`lib/`），ArkTS 只负责 VPN 扩展、回环 RPC、NAPI 桥和后台保活，Go 内核（mihomo）住在 VPN 扩展进程。
2. 【事实】该副本缺失 `lib/`、`core/`、`pubspec.yaml`，也缺失 README 引用的 `core/build_ohos.sh`；因此 **Dart 侧行为、Action 具体词表、Go 桥接源码、内核重建脚本都无法从本副本获得**，只能从二进制和接口契约反推。
3. 【事实】可独立复用的 ArkTS 文件是：`RpcProtocol.ets`、`ClashRpcServer.ets`、`ClashRpcClient.ets`、`CoreBridge.ets`、`KeepAliveManager.ets`、`vpn/ClashVpnExtensionAbility.ets`；不可直接复用的是 `EntryAbility.ets`、`pages/Index.ets`、`plugins/GeneratedPluginRegistrant.ets`、`services/ClashServiceChannel.ets`（Flutter/MethodChannel 绑定）。
4. 【事实】服务层协议是 **127.0.0.1:47471 的换行分帧 JSON-RPC，无鉴权、无 TLS、固定端口**；UI 进程先连接、连不上才启动扩展。【推断】在系统允许同机回环访问的前提下，该顺序意味着本机任意进程都可以抢占 47471 冒充内核，或连接后收到推送给所有 peer 的事件。
5. 【事实】`init` 的成功语义是「RPC 可达」而不是「Go 内核初始化成功」：扩展侧 `init` 处理器无条件返回 `'ok'`，`CoreBridge.init` 的布尔结果只写日志。这与 HmChat「禁止伪造 Ready」的约束直接冲突，融合时必须修正。
6. 【事实】`protect` 是同步阻塞契约：Go 的 socket 控制回调在 `connect()` 前阻塞等待 ArkTS `VpnConnection.protect()` 回执，超时 1500 ms；TSFN 队列容量只有 4，队列满时会丢弃 protect 请求，可能导致代理流量被自身 TUN 捕获并形成环路。
7. 【事实】`quickStart` 在扩展进程的 JS 线程上同步执行 `initClash + setState + setupConfig`，期间无法处理 protect 回执；初始化慢时会放大环路风险。头文件同时导出了回调式 `quickStart`，可作为改造入口。
8. 【事实】原生侧是 `libclash_bridge.so`（NAPI，14 个导出）→ `dlopen("libclash_core.so")` → mihomo c-shared（20 个 C 导出）。ABI 为 ELF64 little-endian / AArch64（`arm64-v8a`），内核 51,155,984 字节，`GOOS=openharmony`、`GOARCH=arm64`、`Go 1.24.5`、`-tags=with_gvisor`。
9. 【事实】`libclash_core.so` 的 Go 构建信息显示主模块为 `core v0.0.0-20261031191723-85b903ad13ea+dirty`，含本地替换 `./third_party/sing-tun`，vcs 修订 `85b903ad13ea...` 且 `vcs.modified=true`；**没有源码和构建脚本，无法履行 GPL 对应源码义务，也无法重建同版本内核**。
10. 【事实】权限方面，源码声明 `INTERNET`、`GET_NETWORK_INFO`、`ACCESS_EXTENSIONAL_DEVICE_DRIVER`、`KEEP_BACKGROUND_RUNNING`；本机 SDK 26 的 `PermissionDefinitions.json` 显示四者均为 `system_grant`/`normal`，其中 `ACCESS_EXTENSIONAL_DEVICE_DRIVER` 的 `provisionEnable=false`，**不是 ACL 权限**，与源码注释/README 所称「受限 ACL」不一致。`NOTIFICATION_CONTROLLER` 为 `system_core`/`SYSTEM`，第三方不可用，源码已移除，处理正确。

---

## 2. 工程性质与 Flutter/ArkTS 分界

### 2.1 目录与缺失件

【事实】`source-refs/FlClashX-ohos/` 根目录只有：`AppScope/`、`entry/`、`har/`、`hvigor/`、`oh_modules/`、`.hvigor/`、`.idea/`、构建配置、`README.md`、以及构建/崩溃残留文件。非构建源码仅 15 个（`.ets` / `.ts` / `.cpp` / `.h` / `.d.ts`）。

【事实】以下路径在本副本中 **不存在**：

| 路径 | 结论 | 影响 |
| --- | --- | --- |
| `lib/` | 不存在 | Dart UI、`ClashLib`、订阅/配置/节点管理、Action 构造、崩溃重启策略全部缺失 |
| `core/` | 不存在 | Go 桥接源码（`android_bride.go`、`lib.go`、`lib_android.go`）、`build_ohos.sh`、mihomo 集成与修改全部缺失 |
| `pubspec.yaml` | 不存在 | 无法确认 Dart 依赖、插件版本、构建目标与 Flutter 版本 |
| `core/build_ohos.sh` | 不存在 | 无法复现 `libclash_core.so` |

【事实】README 自身也把 `lib/` 与 `core/` 当作上级仓库目录（`README.md` L3-L4、L59-L61、L144-L157），说明本副本只包含 `ohos/` 子树。

【事实】README 的构建说明要求 `flutter build hap` 或 `hvigorw assembleHap`（`README.md` L55-L67），并列出 Dart 插件适配与待验证项（L70-L116、L159-L170）。这些内容可作为背景，但不能当作本副本已具备的实现。

### 2.2 Flutter-OHOS 宿主边界

【事实】依赖 `@ohos/flutter_ohos` 或 MethodChannel 的文件只有 4 个：

| 文件 | 关键行 | 依赖形态 | 融合结论 |
| --- | --- | --- | --- |
| `entry/src/main/ets/entryability/EntryAbility.ets` | L1、L15、L18-L22、L32-L37 | `extends FlutterAbility`，持有 `FlutterEngine`，注册插件与 Channel | 不能复用；HmChat 用自己的 UIAbility 替换 |
| `entry/src/main/ets/pages/Index.ets` | L2、L15 | `FlutterPage({ viewId })` 承载全部 UI | 不能复用；HmChat 用 ArkUI 页面 |
| `entry/src/main/ets/plugins/GeneratedPluginRegistrant.ets` | L1-L8、L20-L28 | 注册 7 个 Flutter 插件 | 整体删除 |
| `entry/src/main/ets/services/ClashServiceChannel.ets` | L5、L64-L70、L75-L92 | `MethodChannel` + `FlutterEngine.dartExecutor` | 不能直接复用；用 ArkTS 门面替代，保留其协议契约作为规格 |

【事实】`entry/src/main/ets/services/RpcProtocol.ets` L19-L20 只保留 MethodChannel 名称字符串 `com.wormhole.app/service`，本身不 import Flutter，可移植；但 HmChat 不需要该名称，建议删除该常量。

【事实】`ClashRpcClient.ets`、`ClashRpcServer.ets`、`CoreBridge.ets`、`KeepAliveManager.ets`、`ClashVpnExtensionAbility.ets` 均不 import Flutter；它们只依赖 `@kit.NetworkKit`、`@kit.AbilityKit`、`@kit.NotificationKit`、`@kit.PerformanceAnalysisKit`、`@kit.ArkTS` 和本地 NAPI 模块。

【事实】`ClashRpcClient.ets` L19-L22、`ClashServiceChannel.ets` L39-L61 的注释把「UI 进程」直接称为 Flutter 宿主；这是架构说明，不是代码依赖。【推断】把 UI 换成 ArkTS 后，RPC 客户端与事件转发模型可以原样保留，只需把 `forwardPush` 的出口从 MethodChannel 改为 ArkTS 回调/状态管理。

### 2.3 可移植性矩阵

| 模块 | 文件 | 外部依赖 | 可移植性 | 需要的改造 |
| --- | --- | --- | --- | --- |
| 协议与分帧 | `services/RpcProtocol.ets` | `@kit.ArkTS` | 高 | 增加鉴权帧、长度上限；删除 Flutter Channel 名称 |
| RPC 服务端 | `services/ClashRpcServer.ets` | `@kit.NetworkKit` | 高 | 端口改为会话协商；增加鉴权、帧上限、空闲关闭 |
| RPC 客户端 | `services/ClashRpcClient.ets` | `@kit.NetworkKit` | 高 | 增加鉴权、重连退避、请求超时与取消语义 |
| NAPI 封装 | `services/CoreBridge.ets` | `libclash_bridge.so` | 高 | 增加 invoke 超时/拒绝；初始化结果可查询；避免全局静态泄漏 |
| 后台保活 | `services/KeepAliveManager.ets` | `@kit.AbilityKit`、`@kit.NotificationKit` | 中 | 使用 HmChat 的 UIAbility 上下文；通知文案与图标替换；失败可观测 |
| VPN 扩展 | `vpn/ClashVpnExtensionAbility.ets` | NetworkKit、NotificationKit、CoreBridge、RpcServer | 中高 | 重写 homeDir/资源路径；修正权限与错误上报；接入鉴权 |
| Flutter 通道 | `services/ClashServiceChannel.ets` | `@ohos/flutter_ohos` | 低 | 用 ArkTS 门面重写；契约表见第 8 节 |
| Flutter 宿主 | `entryability/EntryAbility.ets`、`pages/Index.ets` | Flutter | 无 | 删除，HmChat 已有原生 EntryAbility |
| 插件注册 | `plugins/GeneratedPluginRegistrant.ets` | Flutter + 7 HAR | 无 | 删除 |
| 原生桥 | `cpp/clash_bridge.cpp`、`cpp/CMakeLists.txt`、`cpp/types/libclash_bridge/*` | NAPI、hilog、dl | 高 | 合并进 HmChat CMake；模块名、产物名、RPATH 调整 |
| 预编译内核 | `entry/libs/arm64-v8a/libclash_core.so` | Go runtime、libhilog、libc | 条件可移植 | 必须先解决 GPL 源码与重建；否则只能作为不可再分发的参考产物 |

### 2.4 运行架构（事实 + 推断）

【事实】README L17-L26 给出架构图，源码与之一致：

```text
Flutter (lib/) ──MethodChannel──> EntryAbility (UI 进程)
                                     │ ClashServiceChannel
                                     │ ClashRpcClient (回环 TCP)
                                     ▼
                        ClashVpnExtensionAbility (扩展进程)
                          ├─ ClashRpcServer
                          ├─ CoreBridge ──NAPI──> libclash_bridge.so ──dlopen──> libclash_core.so (mihomo)
                          └─ VpnConnection (TUN fd → CoreBridge.startTun)
```

【推断】UI 进程与 VPN 扩展进程是两个独立的 ArkTS 运行时。`vpnExtension.startVpnExtensionAbility` 由 UI 进程调用（`ClashServiceChannel.ets` L138-L149），系统在首次 `createVpnConnection().create()` 时弹出 VPN 授权对话框（`README.md` L129-L130；`ClashVpnExtensionAbility.ets` L202-L207）。扩展进程承载 Go 内核与 TUN，因此内核的 `protect` 回调、RPC 服务端、通知都在同一进程。

【事实】UI 进程的 `ClashServiceChannel` 在 `onWindowStageCreate` 时注册（`EntryAbility.ets` L29-L38），在 `onWindowStageDestroy` 时注销（L40-L44）。注销只关闭 RPC 客户端并清空 MethodChannel（`ClashServiceChannel.ets` L83-L86），不会停止 VPN 或扩展。

### 2.5 副本卫生：不要直接复制的内容

【事实】以下内容属于构建产物、IDE/本机配置或崩溃残留，不应进入 HmChat 源码树：

- `.cxx/`、`build/`（包含原构建机绝对路径、对象文件、编译缓存）
- `oh_modules/`、`.hvigor/`、`.idea/`
- `local.properties`（本机 SDK 路径）
- `Crash_450394343.dmp`、`wecode-cpp.db*`
- `entry/libs/arm64-v8a/libapp.so`（Flutter AOT）
- `entry/src/main/resources/rawfile/flutter_assets/`（Flutter 资源；其中 geo 数据见 8.8 需要单独评估）
- `har/*.har`（Flutter 与插件 HAR）

【事实】`.gitignore` L1-L9 已经忽略 `build/`、`.cxx/`、`oh_modules/`、`.hvigor/`、`.idea/`、`oh-package-lock.json5`、`libs/arm64-v8a/libclash_core.so`、`local.properties`。其中内核 `.so` 被忽略，说明原仓库并不把该二进制纳入源码分发；本副本中的 `.so` 是构建产物/参考产物。

---

## 3. 可复用 ArkTS 服务层

### 3.1 `CoreBridge.ets`：NAPI 门面

文件：`entry/src/main/ets/services/CoreBridge.ets`

【事实】顶部 `import clashBridge from 'libclash_bridge.so'`（L1），说明 ArkTS 通过 oh-package 依赖 `libclash_bridge.so` 解析到 `entry/src/main/cpp/types/libclash_bridge`（配置见 `entry/oh-package.json5` L10）。

公开接口（全部为静态成员）：

| 成员 | 行号 | 语义 | 备注 |
| --- | --- | --- | --- |
| `eventHandler` | L32 | `event`/`protect` 的转发出口 | 进程级单例，无注销 API；L31 注释称由 RPC 服务端赋值，实际在 `ClashVpnExtensionAbility.ets` L73 赋值 |
| `init(homeDir)` | L35-L42 | 注册事件 sink，调用 `initCore(homeDir)` | 返回 Go 初始化结果；仅在首次注册 sink |
| `invokeAction(actionJson)` | L45-L67 | 发 Action，返回 ActionResult 原始 JSON 字符串的 Promise | 只解析 `id` 做关联；无超时；无 id 时立即 resolve `''` |
| `quickStart(init, params, state)` | L70-L72 | 同步执行 init + setState + setupConfig | 返回错误字符串，`''` 表示成功 |
| `startTun(fd)` | L75-L77 | 把 TUN fd 交给内核 | 失败时内核可能已关闭 fd（见 4.4） |
| `stopTun()` | L79-L81 | 停止 TUN | 不销毁 VpnConnection |
| `getRunTime()` | L83-L85 | 隧道启动时间（epoch ms） | `0` 表示未启动 |
| `getAndroidVpnOptions()` | L87-L89 | 返回序列化的 `AndroidVpnOptions` | 字段见 8.6 |
| `getCurrentProfileName()` | L91-L93 | 当前配置名 | 仅用于展示 |
| `updateDns(dnsJson)` | L95-L97 | 更新 DNS | 参数为 JSON 数组字符串（d.ts L40-L41） |
| `setState(stateJson)` | L99-L101 | 更新内核状态 | 具体 schema 缺失 |
| `resetConnections()` | L103-L105 | 重置连接 | UI Channel 未暴露（见 8.2） |
| `notifyProtected(fd)` | L108-L110 | 解除 Go dialer 线程阻塞 | 与 protect 契约强绑定 |
| `shutdown()` | L112-L114 | 发送 `shutdown` Action | 结果被忽略 |

内部调度：

- 【事实】`pendingInvokes: Map<string, (result: string) => void>`（L28）按 Action `id` 关联 Promise；`sinkRegistered`（L29）保证只注册一次 TSFN。
- 【事实】`onDispatch`（L116-L151）解析 `DispatcherPayload`，`actionResult` 时按 `data.id` 查表并 resolve；`event`/`protect` 交给 `onEvent`（L144-L147）；未知类型丢弃。
- 【事实】ActionResult 信封只声明 `id? / method? / data?`（L11-L15）。`data` 既可能是字符串也可能是对象（L126）。
- 【事实】没有超时、没有取消、没有 pending 清理上限。若 Go 永不回包，Promise 永久挂起，`pendingInvokes` 永久增长。
- 【事实】`quickStart` 直接调用 NAPI 同步方法，没有 taskpool/worker 隔离（L70-L72）。

【推断】`pendingInvokes` 的键只在 `id` 为字符串时建立（L50）；Dart 侧原始协议也依赖 id 关联（L22-L25 注释）。HmChat 必须自己生成唯一 id，并给每个请求加超时与错误类型。

### 3.2 `RpcProtocol.ets`：传输协议

文件：`entry/src/main/ets/services/RpcProtocol.ets`

【事实】常量：

| 常量 | 值 | 行号 |
| --- | --- | --- |
| `RPC_PORT` | `47471` | L16 |
| `RPC_HOST` | `127.0.0.1` | L17 |
| `CHANNEL_NAME` | `com.wormhole.app/service` | L20 |
| `VPN_ABILITY_NAME` | `ClashVpnExtensionAbility` | L23 |

【事实】线格式为「一行一个 JSON 对象」：

```text
request : {"id":"<rpcId>","method":"<name>","params":<any>}
response: {"id":"<rpcId>","result":<any>} | {"id":"<rpcId>","error":"..."}
push    : {"push":"event"|"crash"|"onStarted","data":<any>}
```

（注释 L8-L11；接口 L25-L40；`encodeFrame` L44-L46。）

【事实】`ByteLineSplitter`（L83-L112）先按 `0x0A` 字节切分，再对整行做 UTF-8 解码（L114-L117）。注释 L70-L82 说明原因：按 TCP 块直接解码会把跨块的多字节 UTF-8 字符替换成 U+FFFD，曾导致 46 KB 的 `setupConfig` 负载里的代理名损坏，mihomo 报 `proxy group[0]: ... not found`。

【事实】`extractLines`（L54-L68）是纯字符串版分帧，当前未被 `ClashRpcServer`/`Client` 使用；它们用的是 `ByteLineSplitter`。

【推断】该分帧对不含换行的 UTF-8 JSON 是安全的，因为 `JSON.stringify` 会把字符串内换行转义为 `\n`。但它没有帧长度上限，恶意/异常 peer 可以持续发送无换行数据，使 `rest` 无限增长。

### 3.3 `ClashRpcServer.ets`：扩展进程服务端

文件：`entry/src/main/ets/services/ClashRpcServer.ets`

【事实】公开接口：

| 成员 | 行号 | 说明 |
| --- | --- | --- |
| `on(method, handler)` | L24-L26 | 注册异步处理器 |
| `start()` | L28-L43 | 绑定 `127.0.0.1:47471`，`family: 1`；失败返回 `false` |
| `stop()` | L45-L61 | 关闭所有连接与 server |
| `push(pushName, data)` | L64-L73 | 向所有已连接 peer 广播 |
| `attach/detach` | L75-L95 | 维护连接与每连接 splitter |
| `feed/dispatch` | L97-L129 | 分帧、JSON 解析、方法路由、响应 |
| `reply` | L131-L135 | 编码并发送响应 |

【事实】使用 `socket.constructTCPSocketServerInstance()`（L17）与 `server.listen()`（L32）。本机 SDK 26 的 `@ohos.net.socket.d.ts` 标注该函数 `@since 10`（另有 `@crossplatform [since 24]`）；源码注释「API 24」很可能指跨平台标注而不是最低 API，API 26 编译不受影响，但需以真实 SDK 为准。

【事实】连接建立后只挂 `message`/`close`/`error`（L79-L88），没有握手、认证、来源校验、速率限制或帧大小限制。

【事实】`unknown method` 返回 `{id, error}`（L113-L118）；handler 抛错时把错误 JSON 字符串化后返回（L124-L127）。

【事实】`push` 在 `!running` 时直接丢弃（L65）；对每个连接 `send`，失败仅告警（L69-L71）。

【事实】`stop()` 清空 `connections` 与 `buffers`，但不重置 `handlers`；再次 `start()` 会复用已注册的 handler 表。`onCreate` 每次都会新建 `ClashRpcServer` 实例并注册一遍（`ClashVpnExtensionAbility.ets` L48、L75、L133-L179）。

### 3.4 `ClashRpcClient.ets`：UI 进程客户端

文件：`entry/src/main/ets/services/ClashRpcClient.ets`

【事实】公开接口：

| 成员 | 行号 | 说明 |
| --- | --- | --- |
| `onPush` | L33 | 收到 `push` 时回调 |
| `onDisconnected` | L35 | 连接意外断开时回调（映射 Dart `crash`） |
| `isConnected()` | L37-L39 | `conn !== null` |
| `connect()` | L42-L53 | 幂等/单飞连接 |
| `close()` | L79-L86 | 关闭并拒绝所有 pending |
| `call(method, params?, timeoutMs=30000)` | L88-L110 | 请求-响应关联，默认 30 s 超时 |

【事实】`doConnect`（L55-L77）：

1. `constructTCPSocketInstance()`
2. 先 `bind({address:'0.0.0.0', port:0, family:1})`（L59-L60，注释称为 API 24 要求）
3. `connect({address:{127.0.0.1,47471,family:1}, timeout:10000})`（L61-L64）
4. 挂 `message`/`close`/`error`（L67-L71）

【事实】请求 id 为 `r${++seq}`（L92）；超时默认 30 s（L88），超时后删除 pending 并 reject（L96-L99）；发送失败也清理并 reject（L104-L108）。

【事实】收到帧后：含 `push` 字段的走 `onPush`（L126-L133）；否则按 `id` 找 pending，`error` 则 reject，否则 resolve `result ?? null`（L134-L146）。

【事实】`handleClose`（L149-L158）只在 `conn !== null` 时触发 `onDisconnected`；连接建立失败时不会触发（只 reject 调用方）。没有自动重连；重连由上层 `ensureExtension` 决定（见 3.5）。

### 3.5 `ClashServiceChannel.ets`：Flutter 契约（不可直接复用）

文件：`entry/src/main/ets/services/ClashServiceChannel.ets`

【事实】该类是 UI 进程的 MethodChannel 实现（L62-L70），构造参数为 `UIAbilityContext` 与 `FlutterEngine`（L67-L70）。`register()` 设置 `onPush/onDisconnected` 与 MethodChannel handler（L72-L81）。

【事实】Channel 方法契约（注释 L39-L61，实现 L151-L284）：

| 方法 | 参数 | 返回 | 超时 | 实现要点 |
| --- | --- | --- | --- | --- |
| `init` | 无 | `"ok"` 或 `""` | 默认 30 s | `ensureExtension()` 后 RPC `init`（L155-L163） |
| `invokeAction` | JSON 字符串 | ActionResult 字符串或 `""` | 60 s | 转发 RPC（L164-L174） |
| `quickStart` | `{init, params, state}` | 错误字符串，`''`=成功 | 90 s | 转发 RPC（L175-L185） |
| `getAndroidVpnOptions` | 无 | JSON 字符串或 `""` | 15 s | 转发 RPC（L186-L191） |
| `updateDns` | JSON 字符串 | `bool` | 15 s | 失败返回 `false`（L192-L197） |
| `getRunTime` | 无 | number（ms） | 15 s | 失败返回 error（L198-L203） |
| `getCurrentProfileName` | 无 | 字符串 | 15 s | 失败返回 `""`（L204-L209） |
| `start` | VpnOptions JSON 或 `{data: json}` | fd（0=失败） | 120 s | `fd>0` 时启用保活（L210-L236） |
| `stop` | 无 | `true` | 60 s | 先停保活，再 RPC `stop`；失败也返回 `true`（L237-L244） |
| `shutdown` | 无 | `true` | 60 s | 停保活、RPC `shutdown`、关闭客户端（L245-L253） |
| `updateNotificationParams` | JSON 字符串 | `null` | 15 s | 同步更新 UI 进程保活标题（L254-L269） |
| `setCrashlytics` | bool | `null` | — | v1 空实现（L270-L273） |
| `saveParams` | `{init, params, state}` | `null` | 30 s | 转发后忽略结果（L274-L280） |
| 其他 | — | `notImplemented` | — | L281-L283 |

【事实】`readOptionsJson`（L17-L37）兼容 `string`、`{data:string}`、`Map.get('data')` 三种形态，因为 Dart `Map` 到 ArkTS 可能变成 `Map`。【推断】HmChat 侧不需要这种兼容，直接传强类型对象即可。

【事实】`ensureExtension()`（L103-L136）是单飞：

1. 先 `client.connect()`；成功即返回。
2. 失败则 `startVpnExtensionAbility(want)`（L138-L149；`bundleName` 取当前 ability，`abilityName = 'ClashVpnExtensionAbility'`）。
3. 轮询 40 次、每次 250 ms（合计约 10 s）再连接。
4. 10 s 后仍失败只写 `hilog.error`，**Promise 仍然 resolve**（L135-L136）。

【事实】因此 `init` 在扩展未起来时会走 `client.call('init')` 并因 `rpc not connected` 被 catch，最终 `result.success('')`（L159-L162）；UI 得到空字符串而不是硬错误。

【事实】`startExtensionAbility` 注释明确说明 `VpnExtensionAbility` 不能用 `context.startAbility`（错误 16000002），必须用 `vpnExtension.startVpnExtensionAbility`（L145-L148）。

### 3.6 `KeepAliveManager.ets`：UI 进程长时任务

文件：`entry/src/main/ets/services/KeepAliveManager.ets`

【事实】单例（L22-L30）。公开接口：

| 成员 | 行号 | 说明 |
| --- | --- | --- |
| `get()` | L25-L30 | 获取单例 |
| `setTitle(title)` | L40-L44 | 更新通知标题（空串忽略） |
| `isRunning()` | L46-L48 | 是否持有长时任务 |
| `enable(context)` | L51-L77 | 申请 `dataTransfer` 长时任务 + 启动 60 s 进度定时器 |
| `disable(context)` | L80-L92 | 清定时器并停止长时任务 |

【事实】`enable` 使用：

- `wantAgent.WantAgentInfo`，`actionType = START_ABILITY`、`actionFlags = [UPDATE_PRESENT_FLAG]`（L58-L66）
- `backgroundTaskManager.startBackgroundRunning(context, ['dataTransfer'], agent)`（L71-L72）
- 返回的 `notificationId` 用于后续 `publishProgress()`（L73）
- 每 60 s 发布一次 `NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW`，`typeCode: 8`，`SlotType.LIVE_VIEW`，模板 `downloadTemplate`（L95-L126）

【事实】注释 L11-L20 说明：`startBackgroundRunning` 只能从 UIAbility 上下文调用，扩展上下文会返回 401；`DATA_TRANSFER` 任务约 10 分钟没有「进度 + 真实流量」会被系统回收，因此需要每分钟发布 live-view 进度。这是华为文档给出的 VPN 应用变通方案（注释引用论坛主题号）。

【事实】`disable` 先清定时器，再 `stopBackgroundRunning`，失败只告警（L89-L91）。没有监听任务被系统终止的回调。

【推断】保活任务挂在 UI 进程而不是扩展进程；如果 UI 进程被用户划掉/系统回收，长时任务可能随之结束，VPN 扩展只能依赖系统对活动 VPN 的保活。HmChat 需要决定是否把「VPN 前台服务」上移到更稳定的宿主（例如让 VPN 扩展自身满足 API 15+ 的 `backgroundModes` 声明，若 SDK 26 允许）。

### 3.7 启动/停止时序（事实汇总）

```text
UI onWindowStageCreate
  └─ new ClashServiceChannel(context, engine); register()
首次任意 Channel 调用
  └─ ensureExtension()
      ├─ client.connect() 成功 → 直接 RPC
      └─ 失败 → vpnExtension.startVpnExtensionAbility(want)
                 └─ 扩展 onCreate
                     ├─ homeDir = .../base/files
                     ├─ CoreBridge.init(homeDir) → initCore → initClashSync(29, homeDir)
                     ├─ CoreBridge.eventHandler = onCoreEvent
                     ├─ registerHandlers()
                     ├─ rpcServer.start()  (127.0.0.1:47471)
                     ├─ rpcServer.push('onStarted', '')
                     └─ updateNotification() (基础通知 id=1001)
                 └─ UI 每 250 ms 重试 connect，最多 40 次
RPC init → 'ok'
RPC start(optionsJson)
  ├─ conn = createVpnConnection(extContext)
  ├─ fd = await conn.create(buildVpnConfig(options))
  ├─ CoreBridge.startTun(fd)
  └─ UI 收到 fd>0 → KeepAliveManager.enable(UI context)
RPC stop → CoreBridge.stopTun() → conn.destroy()
RPC shutdown → stopVpn() → CoreBridge.shutdown() → rpcServer.stop()
扩展 onDestroy → push('crash','extension destroyed') → rpcServer.stop() → stopTun() → destroyVpn()
```

【事实】`onCreate` 中 `CoreBridge.init` 失败只 `hilog.error`（`ClashVpnExtensionAbility.ets` L68-L70），不会阻止 RPC server 启动，也不会通知 UI。

【事实】`onStarted` 在 `rpcServer.start()` 之后立即 push（L76-L81）；此时 UI 通常尚未连接，因此该 push 很可能丢失。UI 实际依赖 `init` 请求/响应完成握手。

### 3.8 线程/并发模型

【事实】ArkTS 侧是单 JS 线程事件循环：RPC server 的 handler、CoreBridge 的 Promise 回调、VPN 的 `onCoreEvent`、KeepAlive 的定时器都在同一线程。

【事实】C++ 侧用 `napi_threadsafe_function` 把 Go goroutine 的回调投递到 JS 线程（`clash_bridge.cpp` L82、L188-L203）。TSFN 队列容量为 4（L472-L474），投递模式为 `napi_tsfn_nonblocking`（L96、L108、L136）。

【事实】`protect` 走同步握手：Go 线程在 C++ 条件变量上等待，JS 线程调用 `conn.protect(fd)` 后通过 `notifyProtected` 唤醒（L122-L171）。详见 5.5。

【推断】因此存在两个关键并发风险：

1. `quickStart` 同步阻塞 JS 线程时，protect 回执无法及时处理，Go dialer 线程会等到 1500 ms 超时后继续，socket 可能已被 TUN 捕获。
2. TSFN 队列满（4 条）时 `actionResult`/`event`/`protect` 都会被丢弃；`protect` 被丢弃时 C++ 直接删除 pending 并返回（L136-L141），Go 线程不再等待，socket 未 protect 就继续 dial。

---

## 4. VPN 扩展

文件：`entry/src/main/ets/vpn/ClashVpnExtensionAbility.ets`

### 4.1 声明与生命周期

【事实】`export default class ClashVpnExtensionAbility extends VpnExtensionAbility`（L47）。

【事实】生命周期：

| 回调 | 行号 | 行为 |
| --- | --- | --- |
| `onCreate(want)` | L54-L83 | 计算 homeDir、初始化内核、设置事件处理器、注册 RPC handler、启动 RPC server、push `onStarted`、发布通知 |
| `onDestroy()` | L85-L91 | push `crash`、停 RPC server、`stopTun`、销毁 VpnConnection |
| `onConnect(want)` | L93-L95 | 仅日志 |
| `onDisconnect(want)` | L97-L99 | 仅日志 |

【事实】扩展在 `module.json5` 中声明为 `type: "vpn"`、`exported: false`（`entry/src/main/module.json5` L51-L58）。

### 4.2 homeDir 计算

【事实】L56-L66：

```text
extFilesDir = this.context.filesDir        // 扩展上下文：.../el2/base/haps/entry/files
hapsIdx = extFilesDir.indexOf('/haps/')
homeDir = hapsIdx > 0
  ? `${extFilesDir.substring(0, hapsIdx)}/files`   // .../el2/base/files
  : extFilesDir
```

【事实】注释解释：Dart 侧 `path_provider.getApplicationSupportDirectory()` 得到 `el2/base/files`；扩展上下文的 `filesDir` 深一层（`haps/entry/files`）。若直接用后者，内核的 `SAFE_PATHS` 允许列表会拒绝 UI 传入的路径（例如 `.../base/files/zashboard`），并弹出阻塞式「path is not subpath of home directory」对话框。

【推断】HmChat 必须把「内核 home」与「ArkTS 侧配置/缓存根」定义成同一个 `files` 根；否则会出现同样的路径拒绝和弹窗。

### 4.3 VpnConfig 构造

【事实】`VpnOptions` 接口（L23-L34）镜像 `core/state.AndroidVpnOptions`（L15 注释）：

```ts
enable: boolean
port: number
ipv4Address: string
ipv6Address: string
accessControl?: { enable, mode, acceptList, rejectList } | null
routeAddress?: string[]
bypassDomain?: string[]
dnsServerAddress: string
includePackage?: string[]
excludePackage?: string[]
```

【事实】`buildVpnConfig`（L245-L333）：

| VpnConfig 字段 | 来源 | 备注 |
| --- | --- | --- |
| `addresses` | `ipv4Address`（默认前缀 30）、`ipv6Address`（默认前缀 126） | L246-L263 |
| `routes` | `routeAddress`；为空时 `0.0.0.0/0`，有 IPv6 时加 `::/0` | L265-L276 |
| `mtu` | 固定 `1500` | L323；SDK 允许 [576,1500] |
| `dnsAddresses` | 单个 `dnsServerAddress` | L315-L318、L324 |
| `isIPv4Accepted` | 固定 `true` | L325 |
| `isIPv6Accepted` | `ipv6Address !== ''` | L326 |
| `isInternal` | `false` | L327 |
| `isBlocking` | `false` | L328 |
| `trustedApplications` | `includePackage` 或 accessControl accept 列表 | L280-L291、L329 |
| `blockedApplications` | `excludePackage` 或 accessControl reject 列表 | L280-L291、L330 |

【事实】`prefixToRoute`（L335-L351）把 `a.b.c.d/len` 拆成 `RouteInfo`：`interface: ''`、`gateway: {address:'',family:1}`、`hasGateway:false`、`isDefaultRoute: len === 0`。

【事实】`options.port` 与 `options.bypassDomain` 在文件中只出现在接口声明（L25、L30），**没有被使用**。`accessControl.mode === 'accept'` 走白名单，否则（包括空串/未知值）走黑名单（L283-L291）。

【事实】SDK 26 `VpnConfig` 明确 `trustedApplications` 与 `blockedApplications` **互斥**（`@ohos.net.vpnExtension.d.ts` L371-L388）。源码在未启用 accessControl 时可能同时来自 `includePackage` 与 `excludePackage`，两者都非空时会同时下发，违反互斥约束。【待确认】真实设备上同时下发是报错、忽略其一是还是产生非预期路由。

【事实】`isIPv6Accepted` 仅由地址字符串决定；若调用方给了 `::/0` 路由但没给 IPv6 地址，不会启用 IPv6。

### 4.4 启动、停止与 fd 所有权

【事实】`startVpn`（L182-L224）：

1. 空/非法 options 返回 `0`（L183-L193）。
2. 若已有 `vpnConnection`，先 `destroyVpn()`（L196-L200）。
3. `vpnExtension.createVpnConnection(this.context)`（L202-L204）。
4. `await conn.create(buildVpnConfig(options))` 得到 `tunFd`；异常则清空连接并返回 `0`（L206-L212）。
5. `CoreBridge.startTun(fd)`；失败则 `destroyVpn()` 并返回 `0`（L214-L221）。注释说明 fd 所有权在进入 `startTun` 时已转移，内核拒绝时可能已关闭 fd，**不要在这里重复 close**（L217-L218）。
6. 成功返回 fd（L222-L223）。

【事实】`stopVpn`（L226-L230）：先 `CoreBridge.stopTun()`，再 `destroyVpn()`。

【事实】`destroyVpn`（L232-L243）：清空引用、`tunFd=-1`、`await conn.destroy()`，失败仅告警。

【事实】`shutdown`（L158-L165）：`stopVpn()` → `CoreBridge.shutdown()` → `rpcServer.stop()`；注释说明 `VpnExtensionContext` 在 API 12 没有 `terminateSelf()`，进程由系统在空闲后回收。

【推断】`stop` 只停 TUN，不停止 RPC server（L237-L243 只调用 `stopVpn`）。因此扩展进程可以保留端口继续接受下一次 `start`；这也意味着停止后端口仍暴露。

### 4.5 protect 流程

【事实】`onCoreEvent`（L101-L131）：

- `event`：把 `msg.data` 写入 hilog（截断到 1000 字符，L106-L107），并 `rpcServer.push('event', msg.data)`（L108）。
- `protect`：取 `data.fd`（L112）；`fd <= 0` 直接返回（L113-L115）。
  - 若 `vpnConnection === null`：立即 `CoreBridge.notifyProtected(fd)`（L117-L120），让 Go 继续。
  - 否则 `conn.protect(fd).then(notifyProtected).catch(log + notifyProtected)`（L124-L129）。

【事实】注释 L121-L123 说明：Go dialer 线程停在 `TrampProtect` 等待，socket 仍打开且尚未 `connect()`，与 Android `VpnService.protect()` 的契约一致。

【事实】C++ 侧 `TrampProtect`（`clash_bridge.cpp` L127-L154）在 1500 ms 后超时并只告警；`NotifyProtected`（L156-L171）按 fd 标记 ack 并 `notify_all`。

【风险，事实推导】：

- `conn.protect` 失败时仍然 ack（L126-L129），socket 未受保护但 dial 继续，可能被自身 TUN 捕获并触发 mihomo loop guard。
- `vpnConnection === null` 时立即 ack（L117-L120），此时没有保护能力；如果 protect 在 `startVpn` 建立连接前到达，socket 会裸奔。
- fd 作为 map key；fd 被快速复用/并发同 fd 时，ack 可能错配。【待确认】实际并发概率。
- TSFN 队列满时 protect 请求被丢弃（5.5），C++ 不等待直接返回。

### 4.6 通知与后台保活

【事实】扩展自身发布基础通知：`id: 1001`、`NOTIFICATION_CONTENT_BASIC_TEXT`、标题为 `notificationTitle`（可拼 `stopText`）、正文固定 `VPN 运行中`（L353-L373）。发布失败只告警（L370-L372）。

【事实】通知标题/停止文案来自 RPC `updateNotificationParams`（L166-L172），参数 JSON 的 `title` / `stopText` 字段。UI 进程同时把 `title` 同步给 `KeepAliveManager.setTitle`（`ClashServiceChannel.ets` L254-L262）。

【事实】真正的长时任务在 UI 进程（`KeepAliveManager`），扩展不调用 `startBackgroundRunning`（文件头注释 L3-L7）。扩展注释说明扩展上下文调用会 401。

【事实】基础通知没有停止按钮（`README.md` L137），停止只能从 UI 发起。

【待确认】HmChat 是否需要在通知中提供停止动作（`WantAgent` + `NotificationActionButton`），以及 API 26 上扩展自身 `backgroundModes` 是否可用。源码注释称 API 12 的 schema 不接受 `extensionAbilities.backgroundModes`（`module.json5` L35-L42 注释），HmChat 最低 API 24，可在真实 SDK 上重新验证。

### 4.7 错误处理与静默失败

【事实】以下路径只写日志、不向 UI 传播硬错误：

| 位置 | 行号 | 行为 |
| --- | --- | --- |
| 内核初始化失败 | `ClashVpnExtensionAbility.ets` L68-L70 | 仅 `hilog.error`；RPC `init` 仍返回 `'ok'`（L135） |
| RPC server 启动失败 | L76-L80 | 仅 `hilog.error`；UI 继续轮询/失败 |
| 扩展启动失败 | `ClashServiceChannel.ets` L121-L125 | 仅日志，随后仍轮询 |
| 10 s 内连不上 | L126-L136 | 仅日志，Promise resolve |
| `init` RPC 失败 | L159-L162 | `result.success('')` |
| `invokeAction` 失败 | L169-L172 | `result.success('')` |
| `quickStart` 失败 | L180-L183 | `result.success('rpc error: ...')` |
| `start` 失败 | L231-L234 | `result.success(0)` |
| `stop` 失败 | L240-L243 | `result.success(true)` |
| `shutdown` 失败 | L248-L251 | `result.success(true)` |
| protect 失败 | VPN L126-L129 | 告警后仍 ack |
| 通知失败 | VPN L370-L372；KeepAlive L123-L125 | 仅告警 |
| KeepAlive 启用失败 | 频道 L224-L227 | 仅日志，fd 仍返回成功 |

【事实】`start` 的 fd `0` 是唯一的失败信号；`stop`/`shutdown` 无论 RPC 是否成功都向 UI 返回 `true`。

【推断】HmChat 若直接沿用，会出现「UI 显示已连接、实际内核未初始化/未保护」的假成功；必须在 ArkTS 门面层引入显式状态机与错误码，不能把 `''`/`true`/`0` 当作成功。

### 4.8 已知设备/平台限制

【事实】来自 README L132-L140 与代码注释：

| 限制 | 证据 | 影响 |
| --- | --- | --- |
| 分应用进程归属 `ResolveProcess` 未实现，返回空 | `clash_bridge.cpp` L173-L179；README L133-L135 | 无法显示「哪个应用走了代理」 |
| 快捷磁贴/桌面小组件/TV/系统代理不在范围 | README L136 | HmChat 不应承诺 |
| 通知为常驻基础样式，无停止按钮 | README L137 | 需自行补停止动作（可选） |
| `flutter_js` 等插件可能阻塞完整功能 | README L112、L138 | 融合后不涉及 Flutter 插件，但说明原功能不完整 |
| 崩溃重启通过 RPC 断连 → `crash` 推送，Dart 侧 5 次退避 | README L139-L140；`ClashRpcClient` L155-L157 | HmChat 需自己实现重启预算 |
| OHOS 不能用 VPN 配置排除自身 bundle | VPN L293-L311 | 依赖同步 `protect` 防止环路 |
| `blockedApplications` 在测试机上表现为「黑洞」，浏览器断网 | VPN L307-L309 | 分应用名单语义与 Android 不同，需真机验证 |
| homeDir 必须是 `base/files` 而非 `haps/entry/files` | VPN L56-L66 | 路径错误会导致内核拒绝与阻塞弹窗 |
| API 12 无 `VpnExtensionContext.terminateSelf()` | VPN L162-L164 | 依赖系统回收 |
| 首次 `create` 弹系统 VPN 授权 | README L129-L130 | UI 需解释并处理拒绝 |
| `trustedApplications`/`blockedApplications` 互斥 | SDK d.ts L371-L388 | 源码可能同时下发（4.3） |
| 每次 `create` 都会触发授权/路由重建 | VPN L196-L207 | 频繁启停可能打扰用户 |

---

## 5. 原生桥（NAPI → Go c-shared）

### 5.1 CMake

文件：`entry/src/main/cpp/CMakeLists.txt`

【事实】构建配置：

| 项 | 值 | 行号 |
| --- | --- | --- |
| CMake 最低版本 | 3.5.0 | L9 |
| 工程名 | `clash_bridge` | L10 |
| C++ 标准 | C++17 | L12 |
| 目标类型 | `SHARED`，源文件 `clash_bridge.cpp` | L14 |
| 额外 include | `${OHOS_STL_INCLUDE}` | L16-L18 |
| 预编译内核 | `${CMAKE_CURRENT_SOURCE_DIR}/../../../libs/arm64-v8a/libclash_core.so` | L22-L24 |
| 系统库 | `libace_napi.z.so`、`libhilog_ndk.z.so`、`libdl.so` | L26-L30 |

【事实】注释 L3-L8 说明：Go c-shared runtime 使用 initial-exec TLS，musl 只在进程启动时加载的库上允许该模型；运行时 `dlopen()` 会报 `initial-exec TLS resolves to dynamic definition`。因此 `libclash_core.so` 以 **DT_NEEDED** 方式链接进 `libclash_bridge.so`，再由 `dlopen("libclash_core.so")` 绑定到已加载实例。CMake 只写「按路径链接」，SONAME 保证 DT_NEEDED 可解析。

【事实】实际构建产物与依赖（本机 `llvm-readelf` 读取）：

```text
libclash_bridge.so
  SONAME   libclash_bridge.so
  NEEDED   libclash_core.so
  NEEDED   libace_napi.z.so
  NEEDED   libhilog_ndk.z.so
  NEEDED   libc++_shared.so
  NEEDED   libc.so
  RUNPATH  <原构建机绝对路径>/entry/libs/arm64-v8a   ← 不应保留
libclash_core.so
  SONAME   libclash_core.so
  NEEDED   libhilog_ndk.z.so
  NEEDED   libc.so
```

【事实】`libclash_bridge.so` 的输出名为 `libclash_bridge.so`（SONAME 同名），hvigor 将 CMake 产物放到 `entry/build/default/intermediates/cmake/default/obj/arm64-v8a/`，再打包到 `entry/build/default/intermediates/libs/default/arm64-v8a/`；`libclash_core.so` 作为 runtime file 从 `entry/libs/arm64-v8a/` 复制。

【事实】编译命令（`.cxx/.../compile_commands.json`）显示：

```text
clang++ --target=aarch64-linux-ohos --sysroot=<SDK>/openharmony/native/sysroot
        -D__MUSL__ -O2 -DNDEBUG -std=gnu++17 -fPIC
```

【事实】`entry/.cxx/.../hvigor/arm64-v8a/summary.cmake` 由 hvigor 注入：

```cmake
if(EXISTS .../lib/aarch64-linux-ohos/cmake/flutter_ohos/flutter_ohosConfig.cmake)
    find_package(flutter_ohos REQUIRED CONFIG)
endif()
```

【推断】这是 Flutter HAR 的构建副作用，`clash_bridge.cpp` 本身不依赖 Flutter；删除 HAR 后该注入应消失。HmChat 合并 CMake 时不应复制这段。

### 5.2 NAPI 导出（ArkTS 可见）

文件：`entry/src/main/cpp/clash_bridge.cpp`，注册表 L485-L500；类型契约 `entry/src/main/cpp/types/libclash_bridge/index.d.ts` L5-L64。

| 导出 | C++ 实现 | d.ts | 说明 |
| --- | --- | --- | --- |
| `initCore(homeDir): boolean` | L301-L323 | L12 | 重定向 stdio；`dlopen` + `registerCallbacks` + `setEventListener` + `initClashSync(29, homeDir)` |
| `invokeAction(json): void` | L325-L337 | L21 | fire-and-forget，结果走 dispatcher |
| `quickStart(init, params, state): string` | L339-L354 | L25 | 同步；`''` = ok |
| `startTun(fd): boolean` | L356-L366 | L28 | 把 fd 交给 `startTUN` |
| `stopTun(): void` | L368-L372 | L30 | 调 `stopTun` |
| `getRunTime(): number` | L374-L387 | L33 | Go 返回字符串，C++ `atol` 后 `napi_create_int64` |
| `getAndroidVpnOptions(): string` | L389-L400 | L36 | 序列化 VpnOptions |
| `getCurrentProfileName(): string` | L402-L413 | L38 | 当前配置名 |
| `updateDns(json): void` | L415-L426 | L41 | 参数为 DNS 数组 JSON |
| `setState(json): void` | L428-L439 | L43 | 更新内核状态 |
| `resetConnections(): void` | L441-L445 | L45 | 重置连接 |
| `shutdownCore(): boolean` | L447-L458 | L55 | 发 `{"id":"__core_shutdown","method":"shutdown"}`，结果忽略 |
| `notifyProtected(fd): void` | L156-L171 | L52 | 解除 protect 等待 |
| `setEventSink(sink): void` | L460-L478 | L63 | 创建 TSFN；重复设置会 abort 旧 TSFN |

【事实】NAPI 模块注册名为 `clash_bridge`（L506-L514），构造函数注册（L516-L518）。ArkTS 通过 `import clashBridge from 'libclash_bridge.so'` 使用，依赖名由 `entry/oh-package.json5` L10 提供：`"libclash_bridge.so": "file:./src/main/cpp/types/libclash_bridge"`。

【事实】d.ts 中 `invokeAction` 没有返回值；`startTun` 返回 boolean；`getRunTime` 返回 number；`setEventSink` 接收 `(payload: string) => void`。

### 5.3 Go c-shared 导出（C ABI）

文件：`entry/libs/arm64-v8a/libclash_core.h`（cgo 生成，L130-L160）。

| 导出 | 行号 | 桥是否使用 | 备注 |
| --- | --- | --- | --- |
| `registerCallbacks(invoke, event, protect, resolveProcess, releaseObject)` | L130 | 是 | 注册 5 个 C 函数指针 |
| `setEventListener(void*)` | L131 | 是 | 非空 token 才启用事件 |
| `getTraffic()` | L132 | 否 | 事件流已覆盖流量 |
| `getTotalTraffic()` | L133 | 否 | 同上 |
| `freeCString(char*)` | L134 | 是 | 释放 Go 分配的字符串 |
| `invokeAction(char* params, void* callback)` | L135 | 是 | 异步，结果回调 |
| `getConfig(char*)` | L136 | 否 | 未使用 |
| `startListener()` | L137 | 否 | 未使用 |
| `stopListener()` | L138 | 否 | 未使用 |
| `quickStart(init, params, state, callback)` | L139 | **否** | 回调式同步启动，可作为避开 JS 线程阻塞的改造入口 |
| `initClashSync(int version, char* homeDir)` | L144 | 是 | `version` 传 29 |
| `quickStartSync(init, params, state)` | L152 | 是 | 返回错误字符串 |
| `startTUN(int fd, void* callback)` | L153 | 是 | 返回 GoUint8 |
| `getRunTime()` | L154 | 是 | 返回 char* |
| `stopTun()` | L155 | 是 | — |
| `getCurrentProfileName()` | L156 | 是 | char* |
| `getAndroidVpnOptions()` | L157 | 是 | char* |
| `setState(char*)` | L158 | 是 | — |
| `updateDns(char*)` | L159 | 是 | — |
| `resetConnections()` | L160 | 是 | — |

【事实】`llvm-nm -D --defined-only` 确认上述 20 个符号均为动态导出，且 `quickStart`（L139 的回调式）确实存在（`T quickStart`），虽然 NAPI 桥当前未 dlsym 它。

【事实】`CoreApi` 结构（`clash_bridge.cpp` L50-L70）只解析 14 个符号：`registerCallbacks`、`setEventListener`、`invokeAction`、`initClashSync`、`quickStartSync`、`startTUN`、`stopTun`、`getRunTime`、`getAndroidVpnOptions`、`getCurrentProfileName`、`updateDns`、`setState`、`resetConnections`、`freeCString`（以及可选检查）。`resolve_process`/`release_object` 由回调注册。

【事实】`LoadCore`（L243-L275）要求 `invokeAction`、`startTUN`、`registerCallbacks`、`freeCString` 至少非空，否则 `dlclose` 并返回 false；其他符号为空时调用点会跳过。

### 5.4 ABI、版本与指纹

【事实】两个 `.so` 均为 ELF64、little-endian、`e_machine=0x00B7`（AArch64），即 `arm64-v8a`。

【事实】`libclash_core.so` 的 Go 构建元数据：

```text
mod   core  v0.0.0-20261031191723-85b903ad13ea+dirty
build -buildmode=c-shared
build -compiler=gc
build -tags=with_gvisor
build -trimpath=true
build CGO_ENABLED=1
build GOARCH=arm64
build GOOS=openharmony
build GOARM64=v8.0
build vcs=git
build vcs.revision=85b903ad13ea3fcb67142dae521e2479ff8cdbe0
build vcs.time=2026-10-31T19:17:23Z
build vcs.modified=true
go1.24.5（二进制内字符串）
```

【事实】依赖共 125 条 `dep`，构建信息共 138 行；含本地替换：

```text
dep github.com/metacubex/mihomo v1.19.28
=>  ./third_party/sing-tun  (devel)
=>  github.com/metacubex/utls v0.0.0-20260715025833-a77524af3a17
```

【事实】文件指纹：

| 文件 | 大小 | SHA-256 |
| --- | --- | --- |
| `entry/libs/arm64-v8a/libclash_core.so` | 51,155,984 bytes | `246e77dcaa26fca25b25ce4fb8386f2d5e36f921cd9f8c88009cd0dc9c4eb9f6` |
| `entry/build/default/intermediates/libs/default/arm64-v8a/libclash_bridge.so` | 194,808 bytes | `54f73410c6665b213f2f2be2ee8862242ba70670f305a02f5dddba6c32ef1091` |

【推断】`vcs.modified=true` + 主模块 `+dirty` + 本地 `third_party/sing-tun` 替换，说明内核不是从干净提交直接构建；即使拿到 `85b903ad13ea`，也不能保证重建出相同二进制。

### 5.5 protect 线程契约（最关键的原生约束）

【事实】`TrampProtect`（`clash_bridge.cpp` L127-L154）：

1. 进入时在 `g_protectPending[fd] = 0` 记录 pending（L130-L133）。
2. 构造 `{"type":"protect","data":{"fd":N}}`，`napi_call_threadsafe_function(..., napi_tsfn_nonblocking)`（L134-L136）。
3. 若投递失败：`free`、删除 pending、**直接返回**（L137-L141）。
4. 若投递成功：在 `g_protectCv.wait_for(1500ms)` 上等待，条件为 pending 不存在或 `acked == 1`（L143-L149）。
5. 超时：告警后继续（L150-L153）。

【事实】`NotifyProtected`（L156-L171）：读取 `fd`，把 pending 标记为 1，`notify_all`。

【事实】`napi_create_threadsafe_function` 参数：`max_queue_size = 4`（L472-L474），`napi_tsfn_nonblocking`。

【事实】`CallDispatcher`（L188-L203）把 payload 直接当 `char*`（不是结构体），`napi_create_string_utf8` 后调用 JS 回调；这是为了避免把 JSON 首 8 字节当指针导致段错误（注释 L184-L187）。

【事实】契约总结：

| 角色 | 线程 | 行为 |
| --- | --- | --- |
| Go socket-control 回调 | Go goroutine（dialer 线程） | 调用 `TrampProtect`，**阻塞**直到 ack 或 1.5 s 超时 |
| NAPI TSFN | 任意 Go 线程 → JS 线程 | 非阻塞投递，队列 4 |
| ArkTS `onCoreEvent` | 扩展进程 JS 线程 | `conn.protect(fd)`（Promise）→ `notifyProtected(fd)` |
| NAPI `notifyProtected` | JS 线程 | 标记 ack + `notify_all` |

【事实】因此：`conn.protect(fd)` 必须在 socket `connect()` 之前执行；ArkTS 的 Promise 链必须尽快 settle；任何 JS 线程长阻塞（`quickStartSync`、大 JSON 解析、同步存储）都会延迟 ack。

【建议】HmChat 应：

1. 把 protect 投递到独立 TSFN（或优先队列），容量至少 64，投递失败时阻塞重试而不是丢弃。
2. 把 ack 超时提高到 3 s，并在超时后记录可观测错误（不要静默）。
3. 将 `quickStartSync` 改为使用回调式 `quickStart` 或 NAPI async work，避免阻塞 JS 线程。
4. `notifyProtected` 失败/未知 fd 也要有计数与告警，防止 fd 复用错配。

### 5.6 `types/libclash_bridge` 包

【事实】`entry/src/main/cpp/types/libclash_bridge/oh-package.json5`：

```json5
{
  "name": "libclash_bridge.so",
  "types": "./index.d.ts",
  "version": "0.4.3",
  "description": "NAPI bridge to the FlClashX Go clash core (mihomo) for OHOS"
}
```

【事实】`index.d.ts` L66 用 `export default clashBridge as ClashBridge`；`CoreBridge.ets` L1 用默认导入。

【推断】HmChat 可以保留包名 `libclash_bridge.so`，也可以改为 `libclash_bridge`；若改名，需同步 `oh-package.json5` 依赖名、`import` 语句、d.ts 与 CMake 目标名。建议保留原名以减少差异。

---

## 6. 构建与依赖

### 6.1 oh-package 依赖

【事实】根 `oh-package.json5`：

- `modelVersion: "5.0.0"`（L2）
- `dependencies: {}`（L4）
- `devDependencies: { "@ohos/hypium": "1.0.19" }`（L5-L7）
- `overrides`（L8-L18）把 7 个插件 HAR、`@ohos/flutter_ohos`（`file:./har/flutter.har`）、`@ohos/flutter_module`（`file:./entry`）映射到本地文件

【事实】`entry/oh-package.json5`：

- `"license": "GPL-3.0"`（L7）
- 依赖（L8-L18）：
  - `@ohos/flutter_ohos: "har/flutter.har"`
  - `libclash_bridge.so: "file:./src/main/cpp/types/libclash_bridge"`
  - `device_info_plus_ohos`、`network_info_plus_ohos`、`package_info_plus_ohos`、`path_provider_ohos`、`shared_preferences_ohos`、`url_launcher_ohos`、`webview_flutter_ohos`（7 个 HAR）

【事实】`har/` 下 HAR 及大小：`flutter.har` 5.9 MB、`webview_flutter_ohos.har` 29 KB、其余 3-9 KB。

【事实】`oh-package-lock.json5` 主要只锁定 `@ohos/hypium@1.0.19`；插件依赖通过 overrides 本地文件解析。

### 6.2 build-profile / hvigor（仅结构，不含签名）

【事实】根 `build-profile.json5` 的结构：

```text
app
├─ signingConfigs        ← 存在用户签名配置，本文不记录任何字段值
├─ products[0]
│  ├─ name: "default"
│  ├─ compatibleSdkVersion: "5.0.0(12)"
│  ├─ targetSdkVersion: "5.0.0(12)"
│  ├─ runtimeOS: "HarmonyOS"
│  └─ buildOption
│     ├─ strictMode.caseSensitiveCheck: true
│     └─ nativeCompiler: "BiSheng"
├─ buildModeSet: debug / release
modules[0]
├─ name: "entry"
├─ srcPath: "./entry"
└─ targets[0]: default → products: default
```

【事实】`entry/build-profile.json5`：

```text
apiType: "stageMode"
buildOption.externalNativeOptions
├─ path: "./src/main/cpp/CMakeLists.txt"
├─ arguments: ""
├─ cppFlags: ""
└─ abiFilters: ["arm64-v8a"]
buildOptionSet.release.arkOptions.obfuscation.ruleOptions.enable: false
targets: default
```

【事实】`entry/build_profile.json5` 是同名但带下划线的副本，多一个 `ohosTest` target，`obfuscation.files` 指向 `./obfuscation-rules.txt`。有效文件通常是带连字符的 `build-profile.json5`；下划线文件属于冗余/历史文件，融合时不要复制。

【事实】根 `hvigorfile.ts` 使用 `appTasks`，`entry/hvigorfile.ts` 使用 `hapTasks`，无自定义插件（L1-L8）。`hvigor/hvigor-config.json5` modelVersion 5.0.0，dependencies/execution/logging/debugging/nodeOptions 均为空。

【事实】源码声明 SDK `5.0.0(12)`，但源码使用了：

- `socket.constructTCPSocketServerInstance()`（SDK 26 标注 since 10）
- `vpnExtension`（since 11）
- `backgroundTaskManager.startBackgroundRunning(context, string[], agent)`（注释称 API 12+）
- `notificationManager` live view / `systemLiveView`（注释按 API 12 使用）
- `vpnId` 字段未使用（since 20）

【待确认】实际构建所用 SDK 版本。`.cxx` 元数据引用本机 DevEco SDK 路径，但源码没有记录编译器/SDK 版本；HmChat 必须在 SDK 26.0.0.105 下重新编译验证，不能以本副本的 `.cxx` 通过推断。

### 6.3 融合时必须删除的 Flutter/HAR 内容

【事实/清单】

| 类别 | 路径/依赖 | 处理 |
| --- | --- | --- |
| Flutter 运行时依赖 | `@ohos/flutter_ohos`（`har/flutter.har`） | 删除依赖与 HAR |
| Flutter 模块映射 | 根 `overrides["@ohos/flutter_module"] = file:./entry` | 删除 |
| 插件 HAR | `device_info_plus_ohos`、`network_info_plus_ohos`、`package_info_plus_ohos`、`path_provider_ohos`、`shared_preferences_ohos`、`url_launcher_ohos`、`webview_flutter_ohos` | 删除依赖与 HAR |
| Flutter AOT | `entry/libs/arm64-v8a/libapp.so`（13.3 MB） | 删除 |
| Flutter 引擎 | 打包产物中的 `libflutter.so` | 删除 |
| Flutter 资源 | `entry/src/main/resources/rawfile/flutter_assets/`（46.1 MB / 33 文件） | 删除；其中 `assets/data/` 42.8 MB / 4 文件需按 8.8 评估是否迁移 |
| Flutter 页面 | `pages/Index.ets`（`FlutterPage`） | 删除/替换 |
| Flutter 宿主 | `entryability/EntryAbility.ets`（`extends FlutterAbility`） | 用 HmChat 原生 EntryAbility 替换 |
| 插件注册 | `plugins/GeneratedPluginRegistrant.ets` | 删除 |
| Flutter 通道 | `services/ClashServiceChannel.ets` | 用 ArkTS 门面替换 |
| Flutter 构建注入 | `.cxx/.../summary.cmake` 的 `find_package(flutter_ohos)` | 删除（生成物） |
| 构建/IDE 残留 | `.cxx/`、`build/`、`.hvigor/`、`oh_modules/`、`.idea/`、`local.properties` | 不复制 |
| 崩溃/调试残留 | `Crash_450394343.dmp`、`wecode-cpp.db*` | 不复制 |
| Impeller 开关 | `entry/src/main/resources/rawfile/buildinfo.json5`（`enable_impeller=false`） | 删除 |

【事实】`entry/src/main/resources/base/profile/main_pages.json` 只包含 `pages/Index`（L1-L3）；HmChat 使用自己的 `main_pages`，不要覆盖。

### 6.4 HmChat 侧合并方案

【事实】HmChat 当前原生层：

- `entry/src/main/cpp/CMakeLists.txt`：`project(harlgram)`、`add_library(entry SHARED napi_init.cpp)`、C++17、链接 `libace_napi.z.so` + `dl`（L1-L17）。
- `entry/oh-package.json5`：仅依赖 `libentry.so`（`file:./src/main/cpp/types/libentry`）。
- NAPI 模块名 `entry`，导出 `getTdlibStatus/createClient/send/receive`。
- TDLib 以 `dlopen("libtdjson.so", RTLD_NOW | RTLD_LOCAL)` 加载（`entry/src/main/cpp/napi_init.cpp` L38-L41 附近）。
- `entry/build-profile.json5`：`abiFilters: ["arm64-v8a"]`，CMake 路径同上，release strip `true`。

【建议，事实驱动】

1. **单模块、双 target**：在 HmChat 的 `entry/src/main/cpp/CMakeLists.txt` 中保留 `add_library(entry ...)`，追加 `add_library(clash_bridge SHARED clash_bridge.cpp)`；不要新建第二个 entry 模块。
2. **预编译内核放置**：把 `libclash_core.so` 放到 `entry/libs/arm64-v8a/`（HmChat 当前没有 `entry/libs`，需新建；不要复制 FlClashX 的 `libapp.so`）。
3. **链接**：`target_link_libraries(clash_bridge PUBLIC <绝对/相对路径>/entry/libs/arm64-v8a/libclash_core.so libace_napi.z.so libhilog_ndk.z.so libdl.so)`；确保 `libclash_core.so` 进入 HAP 的 `lib/arm64-v8a/`。
4. **删除 RUNPATH**：FlClashX 产物带原构建机 `RUNPATH`；新构建不要设置 rpath，依赖应用库目录解析 SONAME。
5. **模块名**：保留 `clash_bridge` 与 `libclash_bridge.so`，避免与 `entry`/`libentry.so` 冲突。
6. **类型包**：把 `cpp/types/libclash_bridge` 复制到 HmChat `entry/src/main/cpp/types/libclash_bridge`，并在 `entry/oh-package.json5` 增加 `"libclash_bridge.so": "file:./src/main/cpp/types/libclash_bridge"`（与 `libentry.so` 并列）。
7. **ABI**：HmChat `abiFilters` 已是 `arm64-v8a`；内核也只有 `arm64-v8a`。若未来加 `x86_64` 模拟器，必须提供对应内核/桥产物，不能复用 arm64。
8. **不要修改签名**：沿用 HmChat 用户签名；不复制 FlClashX 的 `build-profile` 签名段。
9. **进程隔离**：保持 VPN 扩展独立进程；不要让 TDLib 与 Go 内核在同一个进程初始化（见 9.6）。

### 6.5 SDK/API 差异与迁移注意

【事实】HmChat 示例 `build-profile.example.json5`：`targetSdkVersion: "26.0.0"`、`compatibleSdkVersion: "6.1.1(24)"`、`nativeCompiler: "BiSheng"`；FlClashX 副本声明 `5.0.0(12)`。

【推断】FlClashX 的 ArkTS 代码在 API 24+ 上应可编译，但以下点必须重新验证：

- `socket.constructTCPSocketServerInstance()`、`TCPSocketConnection` 事件签名
- `vpnExtension.VpnConnection.protect()`、`VpnConfig` 互斥字段
- `backgroundTaskManager.startBackgroundRunning` 的 string[] 重载与返回 `notificationId`
- `notificationManager` live view 模板/`typeCode: 8`
- `wantAgent` 的 `actionType/actionFlags` 新字段
- `extensionAbilities` 的 `backgroundModes`（API 15+）

【待确认】`VpnExtensionContext` 在 API 26 是否新增 `terminateSelf()`；若可用，可显式结束扩展进程，避免端口/Go runtime 残留。

---

## 7. 权限、ACL 与签名

### 7.1 源码声明

【事实】`entry/src/main/module.json5`：

- 设备类型：`["tablet", "phone", "2in1"]`（L7）
- 权限（L12-L24）：
  - `ohos.permission.INTERNET`
  - `ohos.permission.GET_NETWORK_INFO`
  - `ohos.permission.ACCESS_EXTENSIONAL_DEVICE_DRIVER`
  - `ohos.permission.KEEP_BACKGROUND_RUNNING`
- `EntryAbility.backgroundModes: ["dataTransfer"]`（L42），注释说明长时任务必须在 UIAbility 上声明（L35-L41）
- `extensionAbilities`：`ClashVpnExtensionAbility`，`type: "vpn"`，`exported: false`（L51-L58）

【事实】源码注释称 `ACCESS_EXTENSIONAL_DEVICE_DRIVER` 是「Restricted (ACL) permission required by third-party VPN apps」，并要求在签名 profile 的 ACL 段声明（L15-L18）。README L120-L127 重复该说法，并提到 `NOTIFICATION_CONTROLLER`（但 module.json5 已移除；L21-L23 注释称其为 `system_basic`，而 SDK 26 实际定义为 `system_core`/`SYSTEM`，见 7.2）。

### 7.2 用本机 SDK 26 核对权限定义

【事实】本机 SDK `openharmony/toolchains/lib/PermissionDefinitions.json`：

| 权限 | grantMode | availableLevel | availableType | since | provisionEnable |
| --- | --- | --- | --- | --- | --- |
| `ohos.permission.INTERNET` | `system_grant` | `normal` | `NORMAL` | 9 | true |
| `ohos.permission.GET_NETWORK_INFO` | `system_grant` | `normal` | `NORMAL` | 8 | true |
| `ohos.permission.KEEP_BACKGROUND_RUNNING` | `system_grant` | `normal` | `NORMAL` | 8 | true |
| `ohos.permission.ACCESS_EXTENSIONAL_DEVICE_DRIVER` | `system_grant` | `normal` | `NORMAL` | 11 | **false** |
| `ohos.permission.NOTIFICATION_CONTROLLER` | `system_grant` | `system_core` | `SYSTEM` | 8 | true |

【事实】结论：

1. 当前四个权限都不是 `system_basic`，`ACCESS_EXTENSIONAL_DEVICE_DRIVER` 也不是 ACL；`provisionEnable=false` 表示不能通过 profile 的 ACL 声明。
2. `NOTIFICATION_CONTROLLER` 是 `system_core`/`SYSTEM`，第三方应用不可用；源码删除它是正确的，不应加回。
3. 源码注释/README 的「ACL 必需」说法与 SDK 26 定义不一致，可能已过期；【待确认】旧版 SDK、华为 VPN 申请流程或特定 ACL 文档是否另有要求，必须以当前官方文档和用户签名 profile 校验。

【事实】本机 SDK `@ohos.net.vpnExtension.d.ts` 的 `createVpnConnection`/`startVpnExtensionAbility` 等 API 没有 `@permission` 标注（模块头 L17-L67、L108-L125）；VPN 授权由系统对话框触发，而不是 manifest 权限。

### 7.3 HmChat 需要新增的配置

【事实/建议】

| 配置 | 位置 | 必要性 | 说明 |
| --- | --- | --- | --- |
| `ohos.permission.INTERNET` | `entry/src/main/module.json5` | 已有 | RPC/订阅/内核出站 |
| `ohos.permission.GET_NETWORK_INFO` | 同上 | 已有 | 网络状态 |
| `ohos.permission.KEEP_BACKGROUND_RUNNING` | 同上 | **新增** | UI 进程的长时任务 |
| `ohos.permission.ACCESS_EXTENSIONAL_DEVICE_DRIVER` | 同上 | 按需 | SDK 26 定义为 normal/system_grant；是否 VPN 必需需按官方 VPN 文档复核 |
| `abilities[EntryAbility].backgroundModes: ["dataTransfer"]` | 同上 | **新增** | `startBackgroundRunning` 的前置条件 |
| `extensionAbilities[ClashVpnExtensionAbility]` | 同上 | **新增** | `type: "vpn"`、`exported: false`、`srcEntry` 指向 ArkTS 扩展 |
| `deviceTypes` | 同上 | 复核 | HmChat 当前 `phone/tablet`；FlClashX 含 `2in1`，不需要为了 VPN 加 |
| VPN 文案资源 | `entry/src/main/resources/base/element/string.json` | **新增** | 扩展描述、通知标题；不要复用 Wormhole 品牌 |
| 应用图标/通知图标 | `resources/base/media` | 复核 | 通知小图标需单色资源（若 API 要求） |

【待确认】`backgroundModes` 是否也能声明在 `extensionAbilities`（API 15+ 起支持，源码注释如此说）。若 SDK 26 允许且扩展自身持有长时任务更稳，可评估把 KeepAlive 移到扩展；否则保留在 UIAbility。

### 7.4 签名与上架

【事实】根 `build-profile.json5` 含 `signingConfigs`，本文不输出任何字段值；`entry/build-profile.json5` 不含签名段。签名属于用户本机配置，且已被 HmChat 的 `.gitignore`/示例配置隔离。

【事实】HmChat 已有自己的签名与发布流程（`docs/LICENSING.md`、`docs/RELEASE.md`），不应复制 FlClashX 的签名材料。

【结论】

1. **本地开发**：沿用 HmChat 当前 DevEco 自动签名/用户签名即可；VPN 能力不要求额外证书。
2. **ACL**：当前权限集合不需要 ACL；不要修改用户签名 profile 的 `allowed-acls`。若未来声明真正的受限权限（`availableLevel=system_basic` 且 `provisionEnable=true`），必须由用户自己的签名 profile 提供 ACL，且需华为审批。
3. **AppGallery**：VPN 类应用通常有额外资质/隐私审核要求；这是**发布者（用户）**的责任，不能由源码或本勘察替代。【待确认】华为当前对第三方 VPN 的上架政策。
4. **不得**为了测试清数据库、导出密钥、复用旧数据库目录或修改签名。HmChat 的测试隔离规则继续适用。

---

## 8. 数据与配置

### 8.1 RPC 方法表（扩展进程服务端）

【事实】`ClashVpnExtensionAbility.registerHandlers()`（L133-L179）注册了 15 个方法：

| RPC 方法 | 参数 | 返回 | 处理 | 行号 |
| --- | --- | --- | --- | --- |
| `ping` | 无 | `"pong"` | 仅用于存活探测；UI Channel 未调用 | L134 |
| `init` | 无 | `"ok"` | **无条件成功**，不检查 `CoreBridge.init` 结果 | L135 |
| `invokeAction` | Action JSON 字符串 | ActionResult 字符串 | `CoreBridge.invokeAction` | L136-L138 |
| `quickStart` | `{init, params, state}` | 错误字符串（`''`=成功） | `CoreBridge.quickStart` | L139-L142 |
| `getAndroidVpnOptions` | 无 | JSON 字符串 | `CoreBridge.getAndroidVpnOptions` | L143 |
| `updateDns` | DNS JSON 字符串 | `true` | `CoreBridge.updateDns` | L144-L147 |
| `getRunTime` | 无 | number | `CoreBridge.getRunTime` | L148 |
| `getCurrentProfileName` | 无 | 字符串 | `CoreBridge.getCurrentProfileName` | L149 |
| `resetConnections` | 无 | `true` | `CoreBridge.resetConnections` | L150-L153 |
| `start` | VpnOptions JSON 字符串 | fd（0=失败） | `startVpn` | L154-L156 |
| `stop` | 无 | `true` | `stopVpn` | L157 |
| `shutdown` | 无 | `true` | `stopVpn` + `CoreBridge.shutdown` + `rpcServer.stop` | L158-L165 |
| `updateNotificationParams` | `{title, stopText}` JSON 字符串 | `true` | 更新扩展通知 | L166-L172 |
| `setCrashlytics` | 任意 | `true` | v1 空实现 | L173 |
| `saveParams` | `{init, params, state}` | `true` | v1 空实现（注释：磁贴/小组件冷启动未接线） | L174-L178 |

【事实】`ping` 与 `resetConnections` 没有出现在 UI 的 `ClashServiceChannel` 方法表中（`ClashServiceChannel.ets` L151-L284），属于「服务端有、UI 未暴露」的方法。

【事实】`init` 的语义问题（重复强调）：`CoreBridge.init` 在 `onCreate` 已调用并可能失败（L68-L70），但 RPC `init` 仍返回 `'ok'`；UI 会把 `'ok'` 当成就绪。HmChat 必须让 `init` 返回结构化结果（`{ok, coreLoaded, homeDir, error}`），或增加 `ping` + `getVersion` 联合探测。

### 8.2 UI 侧 Channel 方法表

【事实】`ClashServiceChannel` 暴露 13 个方法（详见 3.5）：`init`、`invokeAction`、`quickStart`、`getAndroidVpnOptions`、`updateDns`、`getRunTime`、`getCurrentProfileName`、`start`、`stop`、`shutdown`、`updateNotificationParams`、`setCrashlytics`、`saveParams`。

【事实】超时：`invokeAction` 60 s、`quickStart` 90 s、`start` 120 s、`stop`/`shutdown` 60 s、`saveParams` 30 s、其余 15 s、默认 30 s（`ClashRpcClient.ets` L88）。

【推断】这些超时反映原实现的经验值：`quickStart` 与 `start` 最慢（配置解析 + TUN 建立）。HmChat 应保留较宽的超时，但必须在 UI 上显示「启动中」而不是无限等待。

### 8.3 推送表

【事实】服务端 push 名称（`RpcProtocol.ets` L11；`ClashVpnExtensionAbility.ets` L81、L87、L108；`ClashRpcClient.ets` L126-L133）：

| push | 触发 | data | 说明 |
| --- | --- | --- | --- |
| `onStarted` | 扩展 `onCreate` 启动 RPC server 后 | `''` | 早于 UI 连接，通常会丢；不能作为握手依据 |
| `event` | Go 内核事件 | Go Message JSON | 流量、日志、延迟、连接等；当前直接转发 |
| `crash` | 扩展 `onDestroy` 或客户端检测到连接断开 | 字符串原因 | 映射 Dart 的崩溃重启 |

【事实】`ClashRpcClient.onDisconnected` 由 `handleClose` 触发（L149-L158）；频道把它转成 `crash` 推送（`ClashServiceChannel.ets` L74）。

【事实】`event` 数据在扩展侧被截断到 1000 字符写入 hilog（VPN L106-L107），但推送给 UI 的是完整 `msg.data`（L108）。【推断】事件里可能含代理节点名、域名、连接元数据；日志与 UI 展示都应按隐私数据处理。

### 8.4 Action JSON 字段与关联

【事实】`CoreBridge.invokeAction`（L45-L67）：

- 入参是完整 JSON 字符串，直接传给 NAPI（L59）。
- 只解析顶层 `"id"`，且必须是字符串（L50-L51）。
- `id` 存在时把 Promise resolver 存入 `pendingInvokes`（L57）；不存在时立即 resolve `''`（L60-L65）。
- ActionResult 到达后，`onDispatch` 解析 `data`，取顶层 `id` 关联（L124-L141）。

【事实】`ActionResultEnvelope` 接口只声明 `id? / method? / data?`（L11-L15）；`data` 可以是对象或字符串（L126）。

【推断】Action 的完整形态为：

```json
{ "id": "<唯一字符串>", "method": "<动作名>", "params": <任意 JSON> }
```

依据：

- `invokeAction` 的入参是 Action JSON，且按 `id` 关联（L45-L67）。
- ActionResult 信封有 `id` / `method`（L11-L15）。
- 注释称该模型镜像 Dart 的 `callbackCompleterMap`（L22-L25）。

【待确认】`params` 的具体 schema、`method` 的完整词表、ActionResult 的 `data` 结构，必须从缺失的 `core/lib.go` / `core/lib_android.go` / Dart `ClashLib` 获取。不能仅凭二进制字符串确定。

### 8.5 Action 方法词表（二进制证据，语义待确认）

【事实】对 `libclash_core.so` 做 ASCII 扫描，以下字符串存在（可能是方法名、配置键或日志文本，不能据此断言全部是 Action 方法）：

```text
getConfig, getTraffic, getTotalTraffic, startListener, stopListener,
getRunTime, getAndroidVpnOptions, getCurrentProfileName, updateDns,
resetConnections, initClash, setState, quickStart, invokeAction,
getStatus, getExternalProvider, updateExternalProvider, shutdown,
getProxies, getVersion, deleteProfile, healthCheck, changeMode, getMode,
setupConfig, getScript, getConnections, updateProfile, getGroups,
testDelay, closeConnections, setProxyGroup, restart, ping, setProfile,
getNetwork, getProxy, getRules, getProviders, updateGeo, getHomeDir,
getLogs, getRuleProviders, updateRuleProvider
```

【事实】以下候选未在二进制中找到（不代表不存在，可能被拆分/压缩/大小写不同）：

```text
changeProxy, getMemory, getDevices, getProfile, saveScript, selectProxy,
getConfigPath, clearLogs, getPlugin, saveParams, updateNotificationParams,
setCrashlytics, onStarted
```

【推断】`setProxyGroup`、`setProfile`、`updateProfile`、`deleteProfile`、`getProxies`、`getGroups`、`testDelay`、`healthCheck`、`getConnections`、`closeConnections` 等构成「配置/节点/组/延迟/连接」操作面；HmChat 需要这些能力来实现订阅与节点 UI，但必须先从 core 源码确认参数与返回。

### 8.6 VpnOptions JSON（字段事实）

【事实】`ClashVpnExtensionAbility.ets` L15 注释：「Mirrors core/state.AndroidVpnOptions JSON tags」；接口 L23-L34 给出字段：

| 字段 | 类型 | 使用 | 说明 |
| --- | --- | --- | --- |
| `enable` | boolean | 未直接使用 | 可能由 Dart 侧决定是否启动 |
| `port` | number | **未使用** | 可能用于本地 mixed 端口，但 OHOS TUN 配置不需要 |
| `ipv4Address` | string（`addr/prefix`） | 使用 | 默认前缀 30 |
| `ipv6Address` | string（`addr/prefix`） | 使用 | 默认前缀 126；空串表示关闭 IPv6 |
| `accessControl` | object | 使用 | `{enable, mode, acceptList, rejectList}`；`mode==='accept'` 走白名单，否则黑名单 |
| `routeAddress` | string[] | 使用 | 为空则默认全局路由 |
| `bypassDomain` | string[] | **未使用** | 可能由内核侧处理，OHOS 侧忽略 |
| `dnsServerAddress` | string | 使用 | 单个 DNS |
| `includePackage` | string[] | 使用 | 映射到 `trustedApplications` |
| `excludePackage` | string[] | 使用 | 映射到 `blockedApplications` |

【推断】`getAndroidVpnOptions` 返回的 JSON 由 Go 内核根据当前配置生成；HmChat 应把它当作「内核建议的 TUN 参数」，但必须在 ArkTS 侧做字段校验与默认值兜底，不能直接把 `undefined`/空串传给 `VpnConfig`。

### 8.7 配置/订阅/节点原本由 Dart 侧管理（推断）

【推断依据】

- README L3-L4：最大化复用 `lib/` 下全部 Dart 代码。
- `ClashServiceChannel` 的契约只提供「初始化、Action、快速启动、VPN 参数、DNS、运行时间、配置名、启动/停止、通知参数、保存参数」等原语（L39-L61），没有订阅、节点、分组、规则、延迟测试的专用方法。
- 这些能力只能通过通用 `invokeAction` 完成（L164-L174）。
- `quickStart {init, params, state}` 与 `saveParams {init, params, state}` 暗示 Dart 侧持有初始化参数、运行参数与状态快照（L175-L185、L274-L280）。
- `GeneratedPluginRegistrant` 注册了 `path_provider` 与 `shared_preferences`（L25-L26），说明 Dart 侧使用应用支持目录与偏好存储。
- `README.md` L139-L140 提到 Dart 侧 `ClashLib._handleCrashRestart` 的 5 次退避预算。

【推断】原 Dart 侧大致承担：

1. 订阅 URL 的保存、拉取、解析、定时更新与失败重试。
2. 配置（YAML/JSON）生成、profile 列表、当前 profile 切换、删除/重命名/排序。
3. 节点/代理组模型、选择节点、延迟测试、健康检查、批量测速。
4. 规则/规则提供者/外部提供者的展示与更新。
5. Action 的构造与 id 生成、ActionResult 分发、事件流解析（流量、日志、连接）。
6. VPN 启停编排、通知文案、崩溃重启策略、后台保活。
7. geo 数据/资源文件的部署。
8. UI 呈现（Flutter 页面）。

【待确认】以上具体实现均在缺失的 `lib/` 中，无法核对字段、文件格式、更新策略与错误语义。HmChat 不能假定这些行为已经存在。

### 8.8 HmChat 需要补的 ArkTS 逻辑

【建议】按 HmChat 现有模块职责（`AGENTS.md`）放置，不直接把 Flutter 页面翻译成 ArkUI：

| 新模块（建议路径） | 职责 | 依赖 | 备注 |
| --- | --- | --- | --- |
| `services/clash/ClashRpcProtocol.ets` | RPC 常量/类型/分帧 + 鉴权帧 + 帧上限 | `@kit.ArkTS` | 从 `RpcProtocol.ets` 移植；端口改为会话协商 |
| `services/clash/ClashRpcServer.ets` | 扩展进程 RPC 服务端 | `@kit.NetworkKit` | 从原文件移植；增加鉴权/限流/空闲关闭 |
| `services/clash/ClashRpcClient.ets` | UI 进程 RPC 客户端 | `@kit.NetworkKit` | 从原文件移植；增加重连退避、鉴权、请求超时 |
| `services/clash/ClashCoreBridge.ets` | NAPI 封装 | `libclash_bridge.so` | 从 `CoreBridge.ets` 移植；增加超时/错误类型/状态查询 |
| `services/clash/ClashVpnExtensionAbility.ets` | VPN 扩展 | NetworkKit/NotificationKit + 上面三者 | 从原文件移植；修正 homeDir/错误上报/鉴权 |
| `services/clash/ClashKeepAlive.ets` | 长时任务 + 通知 | AbilityKit/NotificationKit | 从 `KeepAliveManager.ets` 移植 |
| `services/clash/ClashService.ets` | UI 侧门面，替代 `ClashServiceChannel` | 上面的客户端 | 暴露 `connect/start/stop/status/profiles/actions/events` 等强类型 API；不暴露裸 JSON |
| `services/clash/ClashProfileStore.ets` | profile/订阅/节点元数据持久化 | Preferences/文件/Asset | 订阅 URL/密钥放 Asset；普通元数据放沙箱文件；禁止写日志 |
| `services/clash/ClashConfigBuilder.ets` | 生成内核配置与 VpnOptions | `ClashProfileStore` | 具体 schema 待 core 源码确认 |
| `services/clash/ClashActionFactory.ets` | Action id/参数构造与校验 | `ClashRpcProtocol` | 统一 id 前缀、超时、取消 |
| `services/clash/ClashEventDecoder.ets` | 解析 `event` 流 | `ClashRpcProtocol` | 限制单事件大小；流量只保留聚合值 |
| `services/clash/ClashAssetInstaller.ets` | geo 数据/规则资源部署 | `@kit.CoreFileKit` | 见下方 geo 说明 |
| `pages/settings/clash/*.ets` | 连接开关、配置列表、订阅管理、节点选择、日志（脱敏） | ArkUI/HDS | 遵循 `docs/UI_GUIDELINES.md` |
| `model/ClashModels.ets` | 强类型模型 | 无 | 与 TDLib 模型隔离 |

【事实】FlClashX 的 Flutter 资源包含 4 个 geo 数据文件，总计 42.8 MB：

| 文件 | 大小 |
| --- | --- |
| `flutter_assets/assets/data/ASN.mmdb` | 12,290,045 bytes |
| `flutter_assets/assets/data/GeoIP.dat` | 19,131,704 bytes |
| `flutter_assets/assets/data/geoip.metadb` | 9,226,542 bytes |
| `flutter_assets/assets/data/GeoSite.dat` | 4,202,493 bytes |

【推断】mihomo 通常从工作目录读取 `GeoIP.dat`、`GeoSite.dat`、`geoip.metadb`、`ASN.mmdb`；Dart 侧很可能在首次启动时把这些文件从 `flutter_assets` 复制到应用支持目录。HmChat 应：

1. 把 4 个文件放进 `entry/src/main/resources/rawfile/clash/`（或按发行策略按需下载）。
2. 首次启动复制到与 core home 相同的 `files/` 根。
3. 通过 Action/配置显式指定 geo 路径（若 core 支持），避免依赖当前工作目录。
4. 记录文件版本与 SHA-256，更新订阅/规则时不要重复复制 42.8 MB。
5. 若选择按需下载，必须提供离线兜底与失败提示。

【待确认】core 期望的确切文件名、目录与配置键；`zashboard` 路径（VPN L61 注释）说明还有 Web 面板资源，但本副本未包含完整 zashboard 站点（仅 `flutter_assets/assets/images/icons/zashboard.svg`）。

---

## 9. 安全与合规风险

### 9.1 固定回环端口 47471 且无鉴权（高）

【事实】

- 服务端绑定 `127.0.0.1:47471`（`ClashRpcServer.ets` L31-L32；`RpcProtocol.ets` L16-L17）。
- 没有任何 auth/token/nonce/verify 关键字（全目录扫描为空）。
- UI 的连接顺序是「先连 47471，失败才启动扩展」（`ClashServiceChannel.ets` L112-L136）。
- 服务端向所有已连接 peer 广播事件（L64-L73）。
- 任意方法都可被调用，包括 `invokeAction`、`start`、`stop`、`shutdown`、`updateDns`、`getAndroidVpnOptions`（L133-L179）。

【风险】

1. **端口抢占/冒充**：本机其他应用可先监听 47471。UI 首次 `client.connect()` 会连到攻击者，攻击者可返回伪造的 `init: "ok"`、伪造 `getRunTime`/`getCurrentProfileName`/ActionResult，诱导 UI 显示已连接；还可接收 UI 发来的 `start` 参数（VpnOptions）与 `invokeAction`（可能含配置/节点）。
2. **事件窃听**：攻击者连接服务端后可收到 `event` 推送，可能包含代理节点、域名、连接元数据。
3. **未授权控制**：攻击者可调用 `stop`/`shutdown` 中断 VPN，或调用 `updateDns`/`invokeAction` 改变内核状态。
4. **端口冲突**：另一个实例/应用占用 47471 时，扩展 `start()` 失败，UI 可能连到错误服务。
5. **无帧上限**：无换行的大帧可使 `ByteLineSplitter.rest` 持续增长，造成内存压力。

### 9.2 `init` 伪成功（高）

【事实】如 8.1 所述，RPC `init` 无条件返回 `'ok'`；`CoreBridge.init` 失败仅日志。UI 无法区分「扩展 RPC 起来了」与「Go 内核加载/初始化成功」。

【风险】违反 HmChat 的「缺少 `.so`、认证失败、不支持状态必须明确呈现，禁止伪造 Ready」约束；用户会看到连接成功但无流量。

### 9.3 protect 超时/丢弃导致流量环路（高）

【事实】5.5 已说明：TSFN 队列 4、非阻塞投递、1.5 s 超时；protect 失败仍 ack。

【风险】代理出站 socket 未 protect → 被自身 TUN 捕获 → mihomo loop guard 拒绝 → 连接失败/断网；日志中会出现 `reject loopback` 类错误。

### 9.4 `quickStart` 阻塞 JS 线程（高）

【事实】`CoreBridge.quickStart` 同步调用 NAPI（L70-L72），`quickStartSync` 在 Go 侧同步执行 `initClash + setState + setupConfig`（头文件 L146-L152）。RPC handler 直接在 JS 线程执行（`ClashVpnExtensionAbility.ets` L139-L142）。

【风险】配置大（注释提到 46 KB setupConfig）时阻塞数百 ms 到数秒；期间 protect 无法 ack，所有出站 socket 等待 1.5 s 后裸奔；UI 也会感到卡顿（若在同一进程）。

### 9.5 事件与日志隐私（中）

【事实】`event` 完整转发给 UI（VPN L108）；扩展把事件 JSON 截断 1000 字符写入 hilog（L106-L107）；`core.log` 通过 `dup2` 把 stdout/stderr 重定向到 `<home>/logs/core.log`（`clash_bridge.cpp` L285-L299）。

【风险】日志/事件可能包含节点名、域名、IP、订阅相关标识；进入公开 artifacts、崩溃报告或截图会泄露。HmChat 已有「截图/日志去敏」规则，需扩展到 Clash。

### 9.6 与 TDLib 原生库共存（中）

【事实】HmChat 主进程已经：

- `libentry.so` NAPI 模块名 `entry`（`entry/src/main/cpp/napi_init.cpp` 注册表与 `nm_modname="entry"`）。
- `dlopen("libtdjson.so", RTLD_NOW | RTLD_LOCAL)`（同文件 L38-L41 附近）。

【事实】Clash 侧：

- NAPI 模块名 `clash_bridge`。
- `libclash_bridge.so` 以 DT_NEEDED 依赖 `libclash_core.so`（Go runtime、initial-exec TLS）。
- `dlopen("libclash_core.so", RTLD_NOW | RTLD_GLOBAL)`（`clash_bridge.cpp` L245）。
- `libclash_bridge.so` 依赖 `libc++_shared.so`。

【风险】

1. **进程体积/启动**：Go runtime + mihomo（51 MB，含 gVisor、sing-tun、quic、wireguard 等）加载到主进程会显著增加内存与启动时间；TDLib 也是重库。
2. **符号污染**：`RTLD_GLOBAL` 把 `libclash_core.so` 的符号暴露给整个进程；Go c-shared 导出名（如 `freeCString`）可能与 TDLib/其他库冲突。建议改为 `RTLD_LOCAL`（`dlsym` 已按 handle 查找，见 L235-L241），并验证 Go runtime 是否需要全局符号。
3. **TLS**：Go `initial-exec TLS` 要求启动时加载；把 `libclash_core.so` 作为主进程的 DT_NEEDED 会影响所有启动路径（包括不启用 VPN 的普通聊天）。**建议保持 VPN 扩展独立进程**，主进程不链接/不加载内核。
4. **libc++ ABI**：桥与 HmChat 都使用 SDK 的 `libc++_shared.so`；若内核用不同 SDK/NDK 构建，可能出现 ABI 不匹配。必须用同一 SDK 26 工具链重建。
5. **崩溃隔离**：Go 内核 panic/abort 若在主进程会杀掉 Telegram 客户端；独立扩展进程可隔离。

### 9.7 GPL 与源码缺失（阻断级）

【事实】第 10 节详述：`libclash_core.so` 是 GPL-3.0 的 mihomo 衍生二进制，但本副本没有 `core/` 源码、没有 `build_ohos.sh`、没有 `third_party/sing-tun`、主模块 `+dirty`。HmChat 是 GPL-3.0-or-later，许可证兼容，但**分发二进制必须提供对应源码**；当前无法做到。

### 9.8 ACL / 上架限制（中）

【事实】SDK 26 显示当前权限均非 ACL；没有需要用户 profile `allowed-acls` 的项。VPN 上架可能有额外资质/审核要求（待确认）。不要把「无 ACL」误解为「无审核」。

### 9.9 缓解建议（按优先级）

| 优先级 | 措施 | 具体做法 | 验收 |
| --- | --- | --- | --- |
| P0 | RPC 鉴权 | UI 生成 32 字节随机 token；通过 `Want.parameters` 传给扩展（SDK 26 支持 API 22+ 的首次启动参数；已运行时的 token 轮换需另行设计）或写入应用沙箱文件；扩展在 `onCreate` 读取；首帧必须是 `{"method":"auth","params":{"token":"..."}}`，常数时间比较；失败立即断开并记录 | 未鉴权连接无法调用任何方法/收推送 |
| P0 | 端口不可预测 | 每次会话随机高位端口（或 port 0 + 沙箱文件回传实际端口），替代固定 47471；UI 从同一通道获取端口 | 端口冲突可恢复；攻击者无法预知 |
| P0 | `init` 真结果 | `init` 返回 `{coreLoaded, homeDir, version, error}`；UI 状态机只有在 `coreLoaded && ping` 后才显示「已连接」 | 删除 `.so` 时 UI 明确报错，不显示 Ready |
| P0 | protect 可靠 | 独立 TSFN（容量 ≥64）、阻塞重试、3 s 超时、失败计数；将 `quickStart` 改为回调式 `quickStart` 或 NAPI async work | 压测下无 `reject loopback`；protect 超时为 0 |
| P1 | 帧上限/限流 | 单帧 ≤1 MB；连接数上限（如 4）；每连接请求速率限制；超限断开 | 无换行大帧被拒绝，内存不增长 |
| P1 | 停止即收敛 | `stop`/`shutdown` 同步停止 RPC server（或空闲 30 s 自动停），释放端口；扩展无引用时 `terminateSelf`（若 API 支持） | 停止后端口关闭，重启可恢复 |
| P1 | 事件最小化 | `event` 只向已鉴权 peer 推送；UI 只解析必要字段；日志脱敏/轮转；`core.log` 不进入公开 artifacts | 日志无节点名/域名/订阅 URL |
| P1 | 进程隔离 | VPN 扩展独立进程；主进程不链接 `libclash_core.so`；`RTLD_LOCAL`；唯一 NAPI 模块名 | 普通聊天启动不加载内核；内核崩溃不影响 TDLib |
| P2 | 崩溃重启预算 | UI 记录扩展崩溃次数，最多 5 次指数退避（对齐原 Dart 行为），超出后显示手动重试 | 连续崩溃不会无限重启 |
| P2 | 通知停止动作 | 需要时在基础通知加 `WantAgent` 停止按钮；不要在扩展上下文申请长时任务 | 通知可停止，任务不被系统提前回收 |
| P2 | 构建卫生 | 删除 RUNPATH、strip 符号、记录 SHA-256、`go version -m` SBOM、固定 SDK/Go 工具链 | 产物可复现、无本机路径 |
| P0（合规） | GPL 源码包 | 见第 10 节：补齐 FlClashX/core/mihomo/sing-tun 源码与脚本，随二进制提供 | 发布前法务/清单检查通过 |

---

## 10. 许可证与第三方声明

### 10.1 已能确认的许可证事实

【事实】

- `entry/oh-package.json5` L7 声明 `"license": "GPL-3.0"`。
- 本副本 **没有** `LICENSE`、`COPYING`、`NOTICE` 文件；根目录也没有。
- 15 个源码文件（`.ets`/`.ts`/`.cpp`/`.h`/`.d.ts`）中未发现 `GPL`/`Copyright`/`SPDX`/`License` 头（扫描为空）。
- 唯一的许可证相关资源是 `entry/src/main/resources/rawfile/flutter_assets/NOTICES.Z`（129,136 bytes），它是 Flutter 生成的第三方通知压缩包；解压首段是 Chromium BSD 许可，随后是 Dart 包通知。它**不能**替代 mihomo、FlClashX 适配层或 Go 依赖的通知。
- README 没有许可证章节，只描述架构、构建、插件适配与限制。

【事实】HmChat 自身：`LICENSE` 是 GPL v3 全文；`THIRD_PARTY_NOTICES.md` 声明项目自有代码为 **GPL-3.0-or-later**，并按组件登记来源与许可副本；`docs/LICENSING.md` 规定发布 HAP 时需提供对应源码、许可全文、构建脚本与版本哈希。

【结论】GPL-3.0 与 GPL-3.0-or-later 兼容；融合不存在许可证方向冲突，但**来源与对应源码义务**是阻断项。

### 10.2 缺失项（待补）

【待补】

1. FlClashX 上游仓库与精确提交（本副本无 `.git`，无法确认；二进制内 `vcs.revision=85b903ad13ea3fcb67142dae521e2479ff8cdbe0` 只能作为线索）。
2. FlClashX 的 `LICENSE` 全文与版权人（`entry/oh-package.json5` 只写 `GPL-3.0`，没有版权行）。
3. `core/` 的 Go 桥接源码（`android_bride.go`、`lib.go`、`lib_android.go`、`dns_*.go`）。
4. `core/build_ohos.sh` 与 Go/OHOS 工具链版本、编译参数。
5. `third_party/sing-tun` 的本地修改 diff（二进制显示以 `./third_party/sing-tun (devel)` 替换）。
6. mihomo v1.19.28 的精确上游 commit（模块版本/h1 不等于 Git commit）。
7. 125 个 Go 依赖的许可证文本与 SBOM（可用 `go version -m`/二进制构建信息生成，但需逐项核对）。
8. Flutter NOTICES 中与本次移植无关的条目可删除；保留的 Dart 包条目需与实际残留资源一致。
9. geo 数据（ASN.mmdb、GeoIP.dat、geoip.metadb、GeoSite.dat）的来源、版本、许可与更新方式。
10. 字体/图片/图标（`Twemoji.Mozilla.ttf`、`JetBrainsMono-Regular.ttf`、FlClash 图标与头像）的来源与再分发许可；若不复用 UI，应删除。
11. Wormhole/FlClashX 名称与图标商标使用边界。

### 10.3 二进制 SBOM（已提取）

【事实】`libclash_core.so` 的 Go 构建信息包含 125 条依赖，关键项：

| 模块 | 版本 | 备注 |
| --- | --- | --- |
| `github.com/metacubex/mihomo` | `v1.19.28` | 主内核；上游项目声明 GPL-3.0，需以对应版本 LICENSE 复核 |
| `github.com/metacubex/sing` | `v0.5.7` | 协议库 |
| `github.com/metacubex/sing-tun` | `v0.4.21` → 本地 `./third_party/sing-tun (devel)` | **有本地修改，源码缺失** |
| `github.com/metacubex/sing-quic` | `v0.0.0-20260527143057-68e10a6afdc3` | QUIC |
| `github.com/metacubex/sing-shadowsocks` / `sing-shadowsocks2` / `sing-vmess` / `sing-shadowtls` / `sing-mux` | 见构建信息 | 协议插件 |
| `github.com/metacubex/gvisor` | `v0.0.0-20251227095601-261ec1326fe8` | gVisor 网络栈（`-tags=with_gvisor`） |
| `github.com/metacubex/quic-go` | `v0.59.1-0.20260606115121-0662b57ad5bf` | fork |
| `github.com/metacubex/utls` | `v1.8.7` → `v0.0.0-20260715025833-a77524af3a17` | 替换 |
| `github.com/metacubex/wireguard-go` / `tailscale-wireguard-go` | 见构建信息 | WireGuard |
| `github.com/metacubex/bbolt` | `v0.0.0-20260706163408-d4ec34ad7c48` | 本地数据库 |
| `gopkg.in/yaml.v3` | `v3.0.1` | 配置解析 |
| `google.golang.org/protobuf` | `v1.34.2` | 协议 |
| `github.com/metacubex/smux` | `v0.0.0-20260105030934-d0c8756d3141` | 多路复用 |
| `github.com/metacubex/restls-client-go` | `v0.1.8` | 协议 |
| `github.com/gaukas/godicttls` | `v0.0.4` | uTLS 辅助 |

【事实】构建标签 `with_gvisor`、`CGO_ENABLED=1`、`GOOS=openharmony`、`GOARCH=arm64`、`GOARM64=v8.0`、`-trimpath=true`；Go 1.24.5。

【推断】GPL/版权清单至少需覆盖：mihomo 及其 125 个模块、Go runtime（BSD-3-Clause）、OHOS NDK 的 libc++（Apache-2.0 with LLVM Exceptions，HmChat 已有 LLVM 通知）、hilog/libc（系统库，不随包分发）。具体每个模块的许可证必须逐项读取其 LICENSE，不能凭模块名推断。

### 10.4 再分发义务（若 HmChat 发布含内核的 HAP）

【义务】

1. **完整对应源码**：GPL-3.0 要求提供二进制对应的完整源码，包括 mihomo、FlClashX 的 `core` 桥接层、`third_party/sing-tun` 修改、构建脚本、编译选项与必要补丁；仅给上游链接不充分。
2. **许可与版权通知**：随 HAP/发行文档提供 GPL 全文、mihomo 与各依赖的版权/许可、HmChat 的 GPL-3.0-or-later 声明、修改说明。
3. **安装信息**：GPL-3.0 对 User Products 的安装信息要求；至少提供可重建步骤、工具链版本、ABI、依赖哈希。
4. **不得只分发 `.so`**：当前 `.gitignore` 已忽略 `libclash_core.so`，说明原仓库也未把二进制作为源码分发；HmChat 若提交二进制，必须同时提交可重建源码与脚本。
5. **商标/品牌**：不得使用 Wormhole/FlClashX 名称、图标或作者身份暗示官方；HmChat 使用自有品牌。
6. **AppGallery/隐私**：VPN 权限、订阅 URL、节点信息属于敏感数据；隐私政策需说明本地处理、是否上传、日志保留。

### 10.5 HmChat 落地行动

【建议】

1. 在 `THIRD_PARTY_NOTICES.md` 增加一行「FlClashX-OHOS 适配层」，固定上游 URL/commit、GPL-3.0、修改说明、对应源码位置。
2. 增加「mihomo v1.19.28 + 125 Go 模块」SBOM 表（或链接到生成的 `sbom/clash-core.json`），并逐项附许可证全文到 `entry/src/main/resources/rawfile/licenses/clash/`。
3. 增加 `docs/integration/clash-source-provenance.md`（后续任务），记录：
   - FlClashX commit `85b903ad13ea...`
   - `core` 主模块 `+dirty` 的具体 diff
   - `third_party/sing-tun` diff
   - mihomo 上游 commit
   - Go 1.24.5 / OHOS Go 工具链 / SDK 26 版本
   - 构建命令、环境变量、产物 SHA-256
4. `scripts/` 增加 `package-clash-source.sh`（生成源码包）与 `verify-clash-licenses.sh`（检查通知/哈希/SBOM）。
5. 发布前在 `docs/LICENSING.md` 的「将来分发 HAP 时」清单中增加 Clash 内核项；未补齐前不得发布含内核的 HAP。
6. 若短期无法补齐源码，**不要分发** `libclash_core.so`；可先做不含内核的 UI/协议原型（但不得宣称 VPN 可用）。

---

## 11. 融合路线与验收

### 11.1 分阶段路线

| 阶段 | 目标 | 前置 | 产出 | 验收 |
| --- | --- | --- | --- | --- |
| P0 合规 | 补齐 FlClashX/core/mihomo/sing-tun 源码、构建脚本、许可证 | 用户提供上游仓库/授权 | 源码包、SBOM、通知 | 能重建同 ABI `.so`；清单完整 |
| P1 服务层 | 移植 5 个无 Flutter 的 ArkTS 文件 + 鉴权/错误状态机 | P0（可先用现有 `.so` 做原型） | `services/clash/*` | 宿主机单测 + SDK 26 编译 |
| P2 原生桥 | 合并 CMake、打包双 `.so`、验证 protect | P1 | `libclash_bridge.so` + `libclash_core.so` | 真机 `dlopen`、`startTun`、protect 无环路 |
| P3 VPN | 扩展声明、权限、保活、通知 | P2 | `ClashVpnExtensionAbility` | 真机授权弹窗、启停、后台存活 |
| P4 数据/UI | profile/订阅/节点/Action/事件/设置页 | P3 + core action schema | ArkTS 服务 + HDS 页面 | 真实订阅（用户授权）启停与节点切换 |
| P5 验收 | 稳定性、隐私、发布 | P4 | 验收记录 | 功能/真机/合规分别记录 |

### 11.2 文件映射（建议）

| FlClashX 源 | HmChat 目标 | 处理 |
| --- | --- | --- |
| `entry/src/main/ets/services/RpcProtocol.ets` | `entry/src/main/ets/services/clash/ClashRpcProtocol.ets` | 移植 + 鉴权 + 帧上限 |
| `entry/src/main/ets/services/ClashRpcServer.ets` | `.../clash/ClashRpcServer.ets` | 移植 + 鉴权/限流/空闲关闭 |
| `entry/src/main/ets/services/ClashRpcClient.ets` | `.../clash/ClashRpcClient.ets` | 移植 + 重连/鉴权/超时 |
| `entry/src/main/ets/services/CoreBridge.ets` | `.../clash/ClashCoreBridge.ets` | 移植 + 状态查询/超时 |
| `entry/src/main/ets/services/KeepAliveManager.ets` | `.../clash/ClashKeepAlive.ets` | 移植 + 通知品牌/停止动作 |
| `entry/src/main/ets/vpn/ClashVpnExtensionAbility.ets` | `entry/src/main/ets/vpn/ClashVpnExtensionAbility.ets` | 移植 + homeDir/错误/鉴权 |
| `entry/src/main/ets/services/ClashServiceChannel.ets` | `entry/src/main/ets/services/clash/ClashService.ets` | 重写为 ArkTS 门面 |
| `entry/src/main/cpp/clash_bridge.cpp` | `entry/src/main/cpp/clash_bridge.cpp` | 移植 + 异步 quickStart/protect 队列 |
| `entry/src/main/cpp/CMakeLists.txt` | 合并进 `entry/src/main/cpp/CMakeLists.txt` | 双 target |
| `entry/src/main/cpp/types/libclash_bridge/*` | `entry/src/main/cpp/types/libclash_bridge/*` | 复制 + 更新签名 |
| `entry/libs/arm64-v8a/libclash_core.so` | `entry/libs/arm64-v8a/libclash_core.so` | 仅在 P0 完成后 |
| `entry/libs/arm64-v8a/libclash_core.h` | 参考文件（不参与编译） | 保留为 ABI 文档 |
| `entry/src/main/resources/rawfile/flutter_assets/assets/data/*` | `entry/src/main/resources/rawfile/clash/*` | 4 个 geo 文件迁移 |
| Flutter 页面/插件/资源 | 不迁移 | 删除 |

### 11.3 验收清单

【必须逐项记录】

**源码/编译**

- [ ] 不复制任何签名、`build-profile` 签名段、`local.properties`、`.cxx`、`build/`、`oh_modules`
- [ ] 删除所有 Flutter/HAR 依赖与资源（6.3）
- [ ] `entry/oh-package.json5` 只保留 `libentry.so` + `libclash_bridge.so`
- [ ] CMake 双 target 在 SDK 26 编译通过（真实 SDK，不用 TypeScript 检查替代）
- [ ] `libclash_bridge.so` 与 `libclash_core.so` 都进入 HAP `lib/arm64-v8a/`
- [ ] 无 RUNPATH 指向本机路径；无 `libapp.so`/`libflutter.so`

**设备/功能**

- [ ] 首次启动弹出系统 VPN 授权；拒绝后 UI 明确显示未授权
- [ ] `start` 返回真实 fd；`stop` 后 TUN 关闭、流量恢复
- [ ] `protect` 压测 10 分钟无 `reject loopback`；保护失败有错误计数
- [ ] 后台 10 分钟以上不被系统回收（或明确记录被回收行为）
- [ ] 通知正确显示；停止后通知消失
- [ ] 扩展崩溃后 UI 检测 `crash`，5 次退避后停止自动重启
- [ ] 未鉴权连接无法调用方法、无法收推送
- [ ] 端口冲突/被占用时 UI 显示明确错误，不连到陌生服务
- [ ] `init` 失败（例如临时移走 `.so`）时 UI 不显示 Ready

**数据/隐私**

- [ ] 订阅 URL/节点密码不写日志、不进 Preferences 明文、不进截图
- [ ] `core.log` 脱敏/轮转；公开 artifacts 不含真实节点/域名
- [ ] 配置/订阅删除后无残留（沙箱文件、缓存、日志）
- [ ] geo 文件版本/SHA-256 有记录

**合规**

- [ ] `THIRD_PARTY_NOTICES.md` 有 FlClashX/mihomo/SBOM 条目
- [ ] `rawfile/licenses/` 有 GPL 与各依赖全文
- [ ] 源码包可重建同 ABI `.so`
- [ ] 未补齐前不发布含内核的 HAP

**回归**

- [ ] TDLib 聊天、登录、消息收发、媒体、草稿不受影响
- [ ] 主进程不加载 `libclash_core.so`；普通启动时间/内存无明显回归
- [ ] UI 遵循 `docs/UI_GUIDELINES.md` 与 `docs/RESPONSIVE_VALIDATION.md`
- [ ] 手机单栏、未展开形态优先；展开/多设备后置并如实标注

### 11.4 待确认问题（必须回到上游源码/真机）

1. `core/lib.go` 的 Action 方法完整词表、`params` schema、ActionResult `data` 结构。
2. `core/state.AndroidVpnOptions` 的精确 JSON 字段与默认值；`port`/`bypassDomain` 的真实用途。
3. `quickStart {init, params, state}` 的 schema 与 config 文件路径约定。
4. `saveParams` 原本是否用于磁贴/小组件冷启动；HmChat 是否需要。
5. `setupConfig` 是读取路径还是直接接收 YAML/JSON；geo 路径如何指定。
6. `initClashSync` 的 `version=29` 含义；升级内核时是否需要变更。
7. mihomo v1.19.28 的精确 commit 与 `third_party/sing-tun` diff。
8. FlClashX 上游仓库/commit/许可证全文。
9. 125 个 Go 模块的许可证清单与通知文本。
10. 4 个 geo 文件的来源版本、许可、更新策略。
11. API 26 是否允许 `extensionAbilities.backgroundModes`；`VpnExtensionContext.terminateSelf()` 是否存在。
12. `trustedApplications`/`blockedApplications` 同时下发的真实行为；分应用名单语义。
13. 固定端口 47471 在目标设备上的可连接范围（是否仅本应用/是否所有应用）。
14. 华为 AppGallery 对第三方 VPN 的资质与隐私要求。
15. Flutter `NOTICES.Z` 中哪些条目在删除 Flutter 资源后仍需保留。

---

## 附录 A：证据索引

| 主题 | 文件 | 行号 |
| --- | --- | --- |
| 混合架构说明 | `README.md` | L3-L4、L8-L26 |
| 构建/插件/限制 | `README.md` | L55-L67、L70-L116、L129-L140、L144-L170 |
| Flutter 宿主 | `entry/src/main/ets/entryability/EntryAbility.ets` | L1、L15、L18-L22、L29-L44 |
| Flutter 页面 | `entry/src/main/ets/pages/Index.ets` | L2、L13-L22 |
| 插件注册 | `entry/src/main/ets/plugins/GeneratedPluginRegistrant.ets` | L1-L8、L20-L28 |
| MethodChannel 契约 | `entry/src/main/ets/services/ClashServiceChannel.ets` | L39-L61、L67-L92、L151-L284 |
| 单飞启动/轮询 | 同上 | L103-L149 |
| RPC 常量 | `entry/src/main/ets/services/RpcProtocol.ets` | L16-L23 |
| RPC 帧格式 | 同上 | L8-L11、L25-L46 |
| UTF-8 分帧 | 同上 | L70-L117 |
| RPC 服务端 | `entry/src/main/ets/services/ClashRpcServer.ets` | L17-L135 |
| RPC 客户端 | `entry/src/main/ets/services/ClashRpcClient.ets` | L24-L166 |
| NAPI 门面 | `entry/src/main/ets/services/CoreBridge.ets` | L28-L160 |
| 保活 | `entry/src/main/ets/services/KeepAliveManager.ets` | L8-L126 |
| VPN 生命周期 | `entry/src/main/ets/vpn/ClashVpnExtensionAbility.ets` | L47-L99 |
| homeDir | 同上 | L56-L66 |
| RPC handler 表 | 同上 | L133-L179 |
| VpnConfig | 同上 | L245-L351 |
| protect | 同上 | L101-L131；`clash_bridge.cpp` L122-L171 |
| 通知 | 同上 | L353-L373 |
| CMake | `entry/src/main/cpp/CMakeLists.txt` | L1-L30 |
| NAPI 导出 | `entry/src/main/cpp/clash_bridge.cpp` | L485-L518 |
| dlopen/回调 | 同上 | L243-L275、L82-L203 |
| protect 契约 | 同上 | L113-L171 |
| stdio 重定向 | 同上 | L285-L299 |
| C ABI | `entry/libs/arm64-v8a/libclash_core.h` | L130-L160 |
| d.ts | `entry/src/main/cpp/types/libclash_bridge/index.d.ts` | L5-L66 |
| 权限/扩展声明 | `entry/src/main/module.json5` | L12-L24、L42、L51-L58 |
| 依赖 | 根 `oh-package.json5` | L1-L18 |
| 依赖 | `entry/oh-package.json5` | L7-L18 |
| 构建结构 | 根 `build-profile.json5` | products/buildModeSet/modules（不含签名值） |
| 原生构建 | `entry/build-profile.json5` | L1-L26 |
| hvigor | 根/entry `hvigorfile.ts`、`hvigor/hvigor-config.json5` | 全文 |
| 忽略规则 | `.gitignore` | L1-L9 |
| 崩溃/调试残留 | 根目录 `Crash_450394343.dmp`、`wecode-cpp.db*` | — |
| 权限定义 | 本机 SDK `openharmony/toolchains/lib/PermissionDefinitions.json` | 对应权限条目 |
| VPN API | 本机 SDK `openharmony/ets/api/@ohos.net.vpnExtension.d.ts` | L108-L125、L283-L388 |
| Socket API | 本机 SDK `openharmony/ets/api/@ohos.net.socket.d.ts` | `constructTCPSocketServerInstance`（since 10） |

## 附录 B：文件清单与指纹

【事实】非构建源码 15 个：

```text
entry/src/main/ets/entryability/EntryAbility.ets
entry/src/main/ets/pages/Index.ets
entry/src/main/ets/plugins/GeneratedPluginRegistrant.ets
entry/src/main/ets/services/ClashRpcClient.ets
entry/src/main/ets/services/ClashRpcServer.ets
entry/src/main/ets/services/ClashServiceChannel.ets
entry/src/main/ets/services/CoreBridge.ets
entry/src/main/ets/services/KeepAliveManager.ets
entry/src/main/ets/services/RpcProtocol.ets
entry/src/main/ets/vpn/ClashVpnExtensionAbility.ets
entry/src/main/cpp/CMakeLists.txt
entry/src/main/cpp/clash_bridge.cpp
entry/src/main/cpp/types/libclash_bridge/index.d.ts
entry/src/main/cpp/types/libclash_bridge/oh-package.json5
entry/libs/arm64-v8a/libclash_core.h
```

【事实】资源与二进制：

| 项 | 大小/数量 |
| --- | --- |
| `libclash_core.so` | 51,155,984 bytes；SHA-256 `246e77dcaa26fca25b25ce4fb8386f2d5e36f921cd9f8c88009cd0dc9c4eb9f6` |
| `libclash_bridge.so`（构建产物） | 194,808 bytes；SHA-256 `54f73410c6665b213f2f2be2ee8862242ba70670f305a02f5dddba6c32ef1091` |
| `libapp.so` | 13,304,736 bytes（应删除） |
| `flutter_assets/` | 46.1 MB / 33 文件（应删除；geo 4 文件 42.8 MB 单独评估） |
| `har/` | 8 个 HAR；`flutter.har` 5.9 MB |
| Go 依赖 | 125 条 `dep`；构建信息 138 行 |
| Go 版本 | 1.24.5；`GOOS=openharmony`、`GOARCH=arm64`、`GOARM64=v8.0`、`-tags=with_gvisor` |
| 内核主模块 | `core v0.0.0-20261031191723-85b903ad13ea+dirty` |
| vcs | `85b903ad13ea3fcb67142dae521e2479ff8cdbe0`，2026-10-31T19:17:23Z，modified=true |

【说明】以上指纹用于识别本副本的参考产物，不代表 HmChat 最终发布产物；P0 重建后必须重新记录。

---

## 附录 C：本勘察的边界声明

【事实】本文没有：

- 构建、安装、运行设备命令或修改签名
- 读取/输出证书、密码、profile、密钥内容
- 输出真实账号、订阅链接、消息内容（源码副本中未发现此类配置）
- 修改 `source-refs/FlClashX-ohos/` 下任何文件

【事实】本文只写入了 `docs/integration/flclash-baseline.md`。

【待确认】本勘察基于静态源码与二进制元数据；所有涉及真实设备行为、真实订阅、真实 VPN 授权、后台保活、分应用路由、AppGallery 审核的结论都必须通过后续真机与发布流程重新验证。