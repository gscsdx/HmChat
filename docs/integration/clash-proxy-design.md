# HmChat 网络代理（mihomo 内核融合）技术设计

| 项目 | 内容 |
| --- | --- |
| 特性目录 | `.codeartsdoer/specs/clash-proxy-integration/` |
| 设计版本 | v1（初版，待评审） |
| 编写日期 | 2026-11-05 |
| 需求输入 | `docs/integration/clash-proxy-spec.md`（132 条 EARS，六态状态机） |
| 证据输入 | `docs/integration/harlgram-baseline.md`、`docs/integration/flclash-baseline.md`、`docs/integration/flclash-core-lib-baseline.md`、`source-refs/FlClashX/OHOS-DELIVERY.md` |
| 只读核对 | `entry/src/main/ets/pages/Index.ets`、`services/TelegramService.ets`、`services/MediaNetworkMonitor.ets`、`cpp/CMakeLists.txt`、`module.json5`、`scripts/ci/verify-hap.py`、`tests/transpile.mjs`、`tests/ci-package.test.mjs`、`components/HdsPage.ets`、`components/HdsSettingsRow.ets` |
| 目标工具链 | 本机 HarmonyOS SDK 26.0.0.105（`targetSdkVersion 26.0.0`、`compatibleSdkVersion 6.1.1(24)`、`nativeCompiler BiSheng`、`arm64-v8a`） |
| 适用范围 | 手机单栏、未展开形态优先；其他形态设计保留、验收另行记录 |
| 文档性质 | 只描述架构、接口、数据与流程；**不含源码、不修改签名/构建配置、不含任何凭据** |

> 事实分级沿用基线：**【事实】** 直接读到的源码、配置、SDK 声明或二进制元数据；**【推断】** 由事实组合出的工程判断，未编译/未上机；**【待确认】** 只能通过真机、固定 TDLib schema、上游源码或商店政策关闭的项。
>
> 本文对上游 `core/` 的 Action 协议只采用已核对的事实：`Action {id, method, data}`、`ActionResult {id, method, data, code}`、`changeProxy {group-name, proxy-name}`、`asyncTestDelay {proxy-name, test-url, timeout}`、`setupConfig` 的 `data` 是 `SetupParams` JSON（`config` 为 `RawConfig`，规则键是 `"rule"`）、`getConfig` 的 `data` 是文件路径、`quickStart(init, params, state)` 对应 `InitParams`/`SetupParams`/`CoreState`、`getProxies` 后由 ArkTS 派生组。任何基线未确认的方法名与字段一律不使用。

---

## 0. 设计摘要

1. **形态**：单 `entry` 模块、双进程。UI 进程继续承载 ArkUI 与 TDLib；新增 `VpnExtensionAbility`（`type: "vpn"`）承载 RPC 服务端、NAPI 桥、Go mihomo 内核与 TUN。主进程**不链接、不加载** `libclash_core.so`。
2. **通信**：UI 与扩展之间使用本机回环 NDJSON RPC，端口由 `bind(0)` 随机分配，token 由 UI 生成并通过应用私有沙箱的一次性会话文件交接（`Want.parameters` 只带 nonce 与文件名），首帧必须鉴权，帧上限 1 MiB，连接数 ≤4，停止即关闭监听端口。
3. **protect 可靠性**：独立 TSFN（容量 ≥64）、非阻塞投递失败后阻塞重试（上限 3 s）、ack 等待 3 s、投递/回执失败计数；持续失败判定 `protect_degraded` 并主动停止 TUN，避免流量环路。所有内核调用不阻塞 ArkTS 主线程（`quickStart` 改为异步 NAPI）。
4. **OHOS 事实**：TUN 无条件 gVisor、MTU 夹紧 1420、`homeDir` 必须是 `.../el2/base/files`、扩展上下文 `filesDir` 深一层需按 `/haps/` 截断、TUN fd 的 `fstat()` 返回 EACCES（由 vendored sing-tun 的 channel endpoint 补丁解决）、扩展进程禁止 import `contacts`/`geo`/`audio`/`camera`/`call`/`sim`/`sms`、长时任务只能由 UIAbility 申请 `dataTransfer`。
5. **数据与安全**：订阅 URL 只进 Asset（别名 `harlgram.proxy.v1`），完整 YAML 与节点凭据只进应用沙箱 `files/profiles/*.yaml`；Preferences（`harlgram_proxy_v1`）只存非敏感元数据；延迟值只在内存；日志字段白名单 + 轮转；`external-controller` 默认关闭。
6. **交付**：`libclash_bridge.so` 与 `libclash_core.so` 同时进入 HAP `libs/arm64-v8a/`；`verify-hap.py` 与 `tests/ci-package.test.mjs` 同步；GPL 对应源码未补齐前只允许本机调试、不得分发。

---

## 1. 范围与判定标准

### 1.1 本设计覆盖

- 需求 §7.1–§7.14 的全部 132 条 EARS 到技术组件、接口、状态与验证方式的映射（见 §17 追溯矩阵）。
- 新增模块的职责边界、文件清单、依赖方向与可测性划分。
- 进程内/进程间并发模型、RPC 鉴权与端口协商、protect 线程契约。
- VPN 扩展声明、`VpnConfig` 构造、授权、通知、保活、错误码。
- 订阅/本地 YAML 导入、配置生成、节点派生、选择、测速与持久化。
- 代理页信息架构、HDS 组件、状态文案、响应式与返回语义。
- 与 TDLib / 媒体策略 / 回环视频的兼容方案。
- 构建、打包、门禁、许可证与 S1–S5 分期。

### 1.2 明确不做（与需求 §3 一致）

规则编辑、逐应用名单 UI、TUN 栈切换、配置备份导出、桌面磁贴/小组件/系统全局代理、Flutter/WebView 包装、修改签名与 `bundleName`、非 `arm64-v8a` ABI、展开/多窗口专项验收、云端订阅托管、替代商店合规审查。

### 1.3 完成判定

- **可用门槛**：SDK 26 编译通过 + 设置入口/返回 + 首次授权 + 启停闭环 + 内核缺失不伪造 Ready。
- **MVP 门槛**：可用门槛 + protect/后台/鉴权 + 订阅/节点/测速 + 真实回归。
- **可分发门槛**：MVP + 全部合规维度（许可全文、来源记录、可重建、发布阻断）。
- **证据分层**：源码、编译、设备启动、真实服务端四类证据分别记录，任一通过不替代其他。

---

## 2. 约束到设计决策

### 2.1 P0 不变量（违反即不得宣称完成）

| 编号 | 不变量 | 设计落点 |
| --- | --- | --- |
| P0-1 | 禁止伪造 Ready：只有「内核初始化成功 + TUN fd 有效 + 路由/DNS 下发成功」三重证据齐全才进入 `connected` | §3.3、§7.5 |
| P0-2 | 主 Telegram 进程不加载内核库 | §4.1、§6.1、§13.1 |
| P0-3 | RPC 必须鉴权、端口不可预测、不得固定 47471 | §5.1–§5.5 |
| P0-4 | protect 必须可靠：有界队列、阻塞重试、超时可见、失败不静默 | §6.4、§7.6 |
| P0-5 | 订阅 URL、节点凭据不进入 Preferences 明文、日志、截图、公开产物 | §8.5、§8.6、§13.5 |
| P0-6 | GPL 对应源码未补齐前不发布含内核 HAP | §13.6 |
| P0-7 | 代理状态与 `telegram.ready`/连接状态完全独立 | §3.3、§8.1、§12.1 |

### 2.2 硬约束映射

| 需求约束 | 设计决策 |
| --- | --- |
| C1 禁止伪造 Ready | 六态状态机 + 三重证据 + `hello.coreLoaded` 结构化返回；任何 `''`/`true`/`0` 不作为唯一成功信号（§3.3、§9.1） |
| C2 主进程不加载内核 | 内核只由扩展进程的 `libclash_bridge.so` 以 DT_NEEDED 引入；UI 只依赖 ArkTS RPC 客户端（§6.1） |
| C3 RPC 安全 | 每次会话新 token + `bind(0)` + 首帧鉴权 + 帧/连接/速率上限（§5） |
| C4 protect 可靠 | 独立 TSFN、容量 64、3 s 重试、3 s ack、失败计数与降级处置（§6.4） |
| C5 敏感数据 | Asset + 沙箱文件 + 字段白名单日志 + 统一脱敏（§8.5、§8.6） |
| C6 不破坏 TDLib | 独立进程；媒体网络判定改用底层物理网络；回环视频专项验证（§12） |
| C7 编译与许可 | 真实 SDK 26 编译；双库入包；门禁同步；GPL 门禁（§13） |
| C8 手机单栏优先 | 代理页作为设置二级页，内容最大宽度约束，跨断点不重置状态（§11） |
| C9 扩展模块禁用 | 扩展侧文件级隔离；网络类型经 RPC 向 UI 请求（§4.1、§7.2） |
| C10 不改签名 | 只新增 `module.json5` 声明与代码；不触碰 `signingConfigs`（§13.7） |
| C11 上游缺 `core/`/`lib/` | 设计只引用已核对的 Action 事实；未知字段标【待确认】（§16） |

### 2.3 OHOS 平台事实在设计中的体现

| 事实 | 设计含义 |
| --- | --- |
| TUN 无条件 `gVisor`，`system` 栈会静默丢 TCP | 配置中 `tun.stack` 写 `gvisor`；不提供栈切换 UI；FAQ 不承诺 system 栈 |
| 对接 MTU 夹紧 1420、GSO/RecvMsgX/SendMsgX 关闭 | `VpnConfig.mtu = 1420`，与内核一致，避免接口 MTU 与内核假设不一致 |
| VpnService fd `fstat()` 返回 EACCES，`dup()` 亦失败 | 必须保留 vendored `third_party/sing-tun` 的 channel endpoint 补丁与 `pumpStop`；不得用未经补丁的 `libclash_core.so` |
| `homeDir` 必须是 `.../el2/base/files` | 扩展 `filesDir` 为 `.../el2/base/haps/entry/files`，按 `/haps/` 截断后再拼 `/files`；ArkTS 配置根与内核 home 完全一致 |
| 扩展进程不得 import `contacts`/`geo`/`audio`/`camera`/`call`/`sim`/`sms` | 扩展侧禁止 import `TelegramService`、`MediaNetworkMonitor`、`@kit.TelephonyKit`；网络类型经 RPC 获取 |
| 长时任务只能由 UIAbility 申请（扩展调用返回 401） | `KeepAlive` 放 UI 进程；扩展只发基础通知 |
| `DATA_TRANSFER` 需「进度 + 真实流量」 | 每 60 s 发布实况窗进度；停止时立即取消 |
| `trustedApplications` 与 `blockedApplications` 互斥 | 任一时刻只下发其中一个；「仅 HmChat」只填 `trustedApplications = [自身 bundle]`，绝不填 `blockedApplications` |

---

## 3. 总体架构

### 3.1 进程与线程模型

```text
┌────────────────────────── UI 进程（HmChat，EntryAbility） ──────────────────────────┐
│ ArkUI 线程（单 JS 事件循环）                                                            │
│   pages/Index.ets ──（page='proxy'）──> components/ProxyPage.ets                       │
│        │                                                                               │
│        └─ services/clash/ClashService.ets（UI 侧唯一门面）                              │
│             ├─ model/ClashStateMachine.ts（纯逻辑 reducer，无 Kit 依赖）                │
│             ├─ ClashProfileStore.ets（Preferences + Asset + 沙箱文件元数据）             │
│             ├─ ClashSubscriptionFetcher.ets（NetworkKit http，限时/限体积）              │
│             ├─ ClashConfigBuilder.ets（getConfig → patch → SetupParams）                │
│             ├─ ClashRpcClient.ets（NDJSON 客户端，鉴权/超时/重连/退避）                  │
│             └─ ClashKeepAlive.ets（UIAbility dataTransfer + 60 s 实况窗）                │
│                                                                                        │
│ TDLib 轮询（60 ms setInterval，≤64 条/12 ms）                                           │
│   services/TelegramService.ets → telegram/TelegramClient.ts → libentry.so → libtdjson.so │
│   services/MediaNetworkMonitor.ets（改为识别并跳过 BEARER_VPN）                          │
└───────────────────────────────────┬───────────────────────────────────────────────────┘
        Want{nonce, sessionFile} 启动/唤醒  │  127.0.0.1:<随机端口> NDJSON + 首帧鉴权
                                           ▼   ▲  state / event / fault 推送
┌────────────────────────── VPN 扩展进程（:vpn，ClashVpnExtensionAbility） ───────────────┐
│ ArkTS 线程                                                                              │
│   ClashVpnSession.ets                                                                    │
│     ├─ vpnExtension.createVpnConnection(context) → VpnConfig → fd                       │
│     ├─ ClashRpcServer.ets（bind 0、鉴权、帧上限、限流、空闲关闭）                        │
│     ├─ ClashCoreBridge.ets → libclash_bridge.so（NAPI，nm_modname="clash_bridge"）       │
│     │      ├─ init/quickStart 走 napi_async_work（不阻塞 JS 线程）                        │
│     │      ├─ action 请求/响应按 id 关联（超时、上限 256）                                │
│     │      ├─ event TSFN（容量 64，nonblocking，满则计数丢弃）                            │
│     │      └─ protect TSFN（容量 64，nonblocking + 5 ms 退避重试 ≤3 s）                  │
│     └─ Notification（基础文本，不含 URL/域名/凭据；长时任务只在 UI 进程）                     │
│                                                                                        │
│ 原生层                                                                                   │
│   libclash_bridge.so ── DT_NEEDED ──> libclash_core.so（Go mihomo，c-shared）             │
│     Go goroutines：配置应用、出站 dialer、DNS、健康检查、provider、日志                    │
│     Go 回调：protect（阻塞等待 ack）、event（非阻塞投递 TSFN）                            │
│                                                                                        │
│ TUN：vpn-tun（gVisor，MTU 1420，地址 172.19.0.1/30，DNS 172.19.0.2）                     │
└─────────────────────────────────────────────────────────────────────────────────────────┘

数据流（上/下行）
  应用 socket ─> TUN(vpn-tun) ─> gVisor ─> mihomo 隧道 ─> 代理节点 ─> 目标
  代理自身出站 socket ─> Go dialer ─> protect(fd) ─> VpnConnection.protect ─> 绕过 TUN
```

**线程约束**

| 执行体 | 允许的阻塞 | 禁止 |
| --- | --- | --- |
| UI ArkTS 线程 | 只允许短时 JSON 解析（≤1 MiB）与 UI 更新 | 任何同步 NAPI 内核调用、同步 HTTP、秒级循环 |
| 扩展 ArkTS 线程 | 只允许短时 JSON 编解码、`conn.protect()` Promise 派发 | `quickStartSync` 同步调用、TDLib 相关初始化、同步文件大拷贝 |
| NAPI async work 线程 | `initClashSync`、回调式 `quickStart`、文件 stat/读取 | 触碰 JS 对象（只能通过 TSFN 回投） |
| Go goroutines | dialer 在 `protect` 上等待 ≤3 s | 依赖 JS 线程完成长任务才能继续 |

### 3.2 关键时序

**开启（首次授权）**

```text
用户点击开关
 → UI 校验：存在生效配置且节点数 > 0；否则保持 unconfigured
 → UI 生成 token(32B)+nonce(16B)，原子写 <files>/proxy/session/req-<nonce>.json（0600）
 → vpnExtension.startVpnExtensionAbility(Want{nonce, sessionFile})（不是 startAbility）
 → 扩展 onCreate/onConnect：读 req → bind 127.0.0.1:0 → 写 ack-<nonce>.json{port,pid,bootId,proto}
 → UI 轮询 ack ≤10 s（250 ms）→ 连接 → 首帧 auth（5 s 内）→ hello
 → hello 返回 {coreLoaded, coreVersion, capabilities}；coreLoaded=false → failed(core_missing)，不请求 VPN 授权
 → core.init（异步 initClash {home-dir, version:29}）→ getIsInit=true
 → core.quickStart（SetupParams）→ 空错误串 = 成功；非空 = failed(config_invalid)
 → vpn.options（Action getAndroidVpnOptions）→ ArkTS 校验字段 → 构造 VpnConfig
 → tun.start：conn.create(VpnConfig) → 系统授权弹窗
     ├─ 用户拒绝 → failed(auth_denied)，关闭连接，不建立 TUN
     └─ fd>0 → startTun(fd) → true → getRunTime>0 → connected
 → UI 通知 KeepAlive.enable(dataTransfer)（仅在 connected 后）
```

**停止**

```text
用户关闭 → tun.stop
 → 扩展：stopTun()（内核停止隧道）→ conn.destroy()（释放 TUN）
 → 关闭所有 RPC 连接 → 关闭监听端口 → 删除 session 文件 → 通知文案「已停止」
 → UI：KeepAlive.disable() → 状态 stopped（资源未释放则 failed/stopped_with_warning）
 → 扩展保持空闲 60 s 后 core shutdown；若 API 26 支持 terminateSelf 则结束进程
```

**应用配置 / 切换配置**

```text
已连接时切换 profile：
 → UI 保存当前 SetupParams 快照（内存）→ 状态 preparing（reason=apply）
 → getConfig(<profilePath>)（Action，data=路径）→ RawConfig JSON
 → patch（§10.3）→ setupConfig({config, selected-map, test-url})
 → 成功：恢复 connected（节点按 selected-map）；失败：重放旧 SetupParams，回滚 connected 或 failed
```

**节点切换**

```text
点击节点 → changeProxy {group-name, proxy-name} → code=0 且 error 为空 → 更新 selectedMap 与标记
          → 失败 → 标记回滚 + 用户可见原因
          → 运行中不默认 closeConnections（新连接生效），TDLib 旧连接由自然重连迁移【待确认】
```

**测速**

```text
单节点：asyncTestDelay {proxy-name, test-url, timeout:5000} → 返回 Delay JSON 或 delay 事件
        value=-1 失败；value=0 加载中；超时按 timeout+2 s 客户端兜底
批量：并发 4（可配 4–8），逐批派发，可取消；结果只进内存 DelayMap
```

**事件**

```text
Go emitEvent(ActionResult{method:"message", data:{type, data}})
 → NAPI event TSFN → 扩展 ArkTS 过滤/聚合 → RPC push {push:"event"|"state"|"fault"}
 → UI ClashEventDecoder：仅接受白名单字段；traffic 1 Hz 聚合；delay 去重；log 仅错误级
```

### 3.3 运行状态机与三重证据

状态集合与文案严格对齐需求 §6.1：`unconfigured`、`unauthorized`、`preparing`、`connected`、`stopped`、`failed`。

| 状态 | 用户文案 | 视觉语义 | 允许动作 |
| --- | --- | --- | --- |
| `unconfigured` | 「尚未导入配置」/「导入订阅或本地配置后即可开启」 | 中性 | 导入、查看说明；开关禁用 |
| `unauthorized` | 「未获得 VPN 授权」/「系统未允许 HmChat 建立 VPN 连接」 | 警示 | 重试授权、关闭 |
| `preparing` | 「正在启动代理…」/「正在应用配置」 | 进行中 | 取消、查看详情 |
| `connected` | 「已连接」+ 实际生效节点名 | 成功（唯一允许成功色） | 关闭、切换节点 |
| `stopped` | 「已停止」 | 中性 | 开启、管理配置 |
| `failed` | 「启动失败」+ 分类原因 + 下一步 | 错误 | 重试、修正配置、查看详情 |

**三重证据（缺一不可）**

| 证据 | 来源 | 判定 |
| --- | --- | --- |
| E1 内核就绪 | `core.init` 返回 `initialized=true` 且 `getIsInit=true`；`quickStart` 返回空错误串；可选 `loaded` 事件 | 失败 → `failed(core_init_failed/config_invalid)` |
| E2 TUN 就绪 | `conn.create` 返回 `fd>0`；`startTun(fd)` 返回 true；`getRunTime()>0` | 失败 → `failed(tun_create_failed/tun_start_failed)` |
| E3 路由就绪 | `conn.create` 成功即代表系统接受地址/路由/DNS；扩展回传 `routeReady=true` | 失败 → `failed(tun_route_failed)` |

「RPC 可达」「扩展进程已启动」「`init` 返回 `ok`」「内核版本可读」都不是三重证据的一部分。

**迁移表（与需求 §6.2 对齐）**

| 起点 | 事件 | 终点 | 守卫 |
| --- | --- | --- | --- |
| `unconfigured` | 导入成功 | `stopped` | 配置有效、节点数>0 |
| `unconfigured` | 请求开启 | `unconfigured` | 无配置：拒绝并提示 |
| `stopped` | 请求开启且配置有效 | `preparing` | 无进行中的启停 |
| `preparing` | E1+E2+E3 | `connected` | 同一 `epoch` |
| `preparing` | 授权被拒 | `unauthorized` | 记录 `auth_denied` |
| `preparing` | 任一证据失败/60 s 超时 | `failed` | 携带错误码 |
| `preparing` | 用户取消 | `stopped` | 资源释放完成后落状态 |
| `connected` | 用户关闭 | `stopped` | 停止收敛完成 |
| `connected` | 系统撤销/进程回收/断连 | `unauthorized` 或 `failed` | 依原因，不得停留 |
| `unauthorized` | 重试并授权 | `preparing` | 重新走完整流程 |
| `failed` | 手动重试 | `preparing` | 重置崩溃计数 |
| 任意 | 应用重启 | `stopped` 或 `unconfigured` | 探测扩展 + 配置存在性；禁止恢复 `connected` |

实现约束：

- 状态机为纯 `.ts` reducer（`model/ClashStateMachine.ts`），输入为「事件 + 现状 + 守卫事实」，输出为新状态或拒绝记录；非法迁移必须拒绝并计数，不允许 UI 直接写状态。
- 每次启停/配置应用使用单调递增 `epoch`；扩展/客户端回传的事件必须携带 `epoch`，旧 epoch 事件丢弃。
- `enabledIntent` 只是用户意图，不参与状态推导；重启后必须通过 `hello` + `getRunTime` + 配置存在性重建。
- `failed` 必须至少包含 `errorCode` 与可执行建议；`unknown` 不是长期状态，只作为最后一次兜底分类。

### 3.4 边界与不变量

1. **进程边界**：`services/clash/` 与 `ets/vpn/` 只通过 RPC 通信；扩展不得 import UI 侧模块；UI 不得 import NAPI 桥。
2. **文件边界**：任何路径必须规范化后位于 `.../el2/base/files` 内；扩展只接受 profileId → 自行拼路径，不接受 UI 传来的任意路径。
3. **状态边界**：代理状态、TDLib 状态、VPN 授权状态分别建模，字段不复用。
4. **凭据边界**：UI 内存中只在导入/更新窗口短暂持有订阅正文；扩展只读 YAML 文件，不读 Asset。
5. **生命周期边界**：扩展可被系统回收；UI 不得假设扩展常驻，必须能重建会话。

---

## 4. 模块与文件清单

### 4.1 新增/修改文件总表

| 路径 | 进程 | 职责 | 主要依赖 | 纯 `.ts` 可测 |
| --- | --- | --- | --- | --- |
| `entry/src/main/ets/model/ClashModels.ts` | 双端共享（仅类型/纯函数） | Profile、ProxySettings、ProxyNode、ProxyGroup、DelayMap、ProxyRuntimeSnapshot、错误枚举、RPC 信封类型 | 无 Kit | **是** |
| `entry/src/main/ets/model/ClashStateMachine.ts` | UI（逻辑） | 六态 reducer、非法迁移拒绝、epoch 守卫、证据聚合 | `ClashModels` | **是** |
| `entry/src/main/ets/model/ClashProfileRules.ts` | UI（逻辑） | URL 校验与脱敏摘要、名称清洗、selectedMap 合并、内容 hash 判定 | `ClashModels` | **是** |
| `entry/src/main/ets/model/ClashConfigPatch.ts` | 扩展（逻辑） | `RawConfig` patch 白名单与最小 DNS/TUN 注入、`rule` 键保证、SetupParams 组装 | `ClashModels` | **是** |
| `entry/src/main/ets/model/ClashProxyCatalog.ts` | 扩展/UI（逻辑） | `getProxies` 结果解码、组派生、叶子解析（深度 16）、节点可用性判定 | `ClashModels` | **是** |
| `entry/src/main/ets/model/ClashRedaction.ts` | 双端（逻辑） | 统一脱敏：URL→域名摘要、删除 userinfo/query、截断前先脱敏、节点名哈希化 | 无 Kit | **是** |
| `entry/src/main/ets/services/clash/ClashRpcProtocol.ets` | 双端 | 帧常量、NDJSON 编解码、字节级 UTF-8 分帧、帧上限、错误码 | `@kit.ArkTS` | 协议纯函数部分可放 `.ts`（见下） |
| `entry/src/main/ets/services/clash/ClashRpcProtocol.ts` | 双端 | 分帧器/编码器纯实现（便于宿主机测试） | 无 Kit | **是** |
| `entry/src/main/ets/services/clash/ClashRpcServer.ets` | 扩展 | `bind(0)` 监听、鉴权首帧、连接/速率/帧限制、空闲关闭、推送 | NetworkKit、`ClashRpcProtocol` | 否 |
| `entry/src/main/ets/services/clash/ClashRpcClient.ets` | UI | 连接 ack 端口、鉴权、请求关联、超时、重连退避、断线回调 | NetworkKit、`ClashRpcProtocol` | 否 |
| `entry/src/main/ets/services/clash/ClashSessionFiles.ets` | 双端 | 会话 req/ack 文件原子读写（0600）、nonce 校验、过期清理 | `@kit.CoreFileKit` | 否（路径规则可测） |
| `entry/src/main/ets/services/clash/ClashCoreBridge.ets` | 扩展 | NAPI 封装：init/quickStart/action/startTun/stopTun/notifyProtected；超时与错误类型 | `libclash_bridge.so` | 否 |
| `entry/src/main/ets/services/clash/ClashVpnSession.ets` | 扩展 | VpnConnection 生命周期、VpnConfig 构造、fd 所有权、保护状态 | vpnExtension、`ClashCoreBridge` | 否（VpnConfig 构造规则可测） |
| `entry/src/main/ets/services/clash/ClashEventDecoder.ets` | 扩展+UI | 内核事件 → 最小字段；流量聚合；delay 去重；日志级别过滤 | `ClashModels`、`ClashRedaction` | 部分可测 |
| `entry/src/main/ets/services/clash/ClashService.ets` | UI | UI 唯一门面：start/stop/applyProfile/selectNode/probeDelay/refresh/import/delete/status/events | 上述客户端与服务 | 否 |
| `entry/src/main/ets/services/clash/ClashProfileStore.ets` | UI | Asset 订阅 URL、Preferences 元数据、沙箱文件原子替换、删除清理 | Asset、Preferences、CoreFileKit | 否（映射逻辑可测） |
| `entry/src/main/ets/services/clash/ClashSubscriptionFetcher.ets` | UI | HTTP 拉取、UA、重定向、超时、体积上限、响应头白名单、临时文件 | NetworkKit http | 否（策略可测） |
| `entry/src/main/ets/services/clash/ClashConfigBuilder.ets` | UI | `getConfig` → patch → `SetupParams`；scope/state 组装 | `ClashConfigPatch`、`ClashService` | 部分可测 |
| `entry/src/main/ets/services/clash/ClashAssetInstaller.ets` | 扩展 | geo 四件套首次复制与 SHA-256 校验、版本文件 | CoreFileKit | 否 |
| `entry/src/main/ets/services/clash/ClashKeepAlive.ets` | UI | `dataTransfer` 长时任务、60 s 实况窗进度、停止清理 | backgroundTaskManager、notificationManager、wantAgent | 否 |
| `entry/src/main/ets/vpn/ClashVpnExtensionAbility.ets` | 扩展 | 扩展入口：onCreate/onConnect/onDestroy、handler 注册、通知 | 上述扩展模块 | 否 |
| `entry/src/main/ets/services/clash/ClashDiagnostics.ets` | 双端 | 状态迁移环形缓冲（≤256 条）、计数、去敏导出 | `ClashRedaction` | 部分可测 |
| `entry/src/main/ets/components/ProxyPage.ets` | UI | 代理页容器与三段内容；HdsPage/HdsListItemCard | HDS、`ClashService` | 否 |
| `entry/src/main/ets/components/ProxyRows.ets` | UI | 状态卡、配置行、节点行、延迟徽标、错误详情 | ArkUI | 否 |
| `entry/src/main/ets/pages/Index.ets` | UI | 新增 `page='proxy'`、入口行、`closeProxy()`、根背景、系统返回 | 现有结构 | 否（路由决策可测） |
| `entry/src/main/cpp/clash/clash_bridge.cpp` | 扩展 | NAPI 桥：符号解析、TSFN、protect 握手、异步 init/quickStart | libace_napi、libhilog、dl | 否 |
| `entry/src/main/cpp/clash/CMakeLists.txt` 片段（合并进 `cpp/CMakeLists.txt`） | 构建 | 双 target、DT_NEEDED 链接、无 RUNPATH | CMake | 否 |
| `entry/src/main/cpp/types/libclash_bridge/{oh-package.json5,Index.d.ts}` | 构建/类型 | NAPI 类型契约 | 无 | 否 |
| `entry/libs/arm64-v8a/libclash_core.so` | 扩展 | mihomo 内核（构建产物，忽略提交） | Go 工具链 | 否 |
| `entry/src/main/resources/rawfile/clash/licenses/*.txt` | 包 | 内核与依赖许可全文 | 无 | 否 |
| `entry/src/main/resources/rawfile/clash/geo/{GeoIP.dat,GeoSite.dat,geoip.metadb,ASN.mmdb}` | 包 | 首启部署的 geo 数据（约 42.8 MB） | 无 | 否 |
| `entry/src/main/module.json5` | 构建 | 新增 VPN 扩展声明、`KEEP_BACKGROUND_RUNNING`、`backgroundModes` | 无 | 否 |
| `entry/src/main/resources/base/profile/backup_config` | 构建 | 排除代理配置/日志/geo | 无 | 否 |
| `scripts/build-clash-core.sh` | 构建机 | 固定工具链构建内核、`-X version`、`-buildvcs=false`、指纹记录 | Go、OHOS NDK | 否 |
| `scripts/package-clash-source.sh` | 构建机 | GPL 对应源码包与 SBOM | tar、go | 否 |
| `scripts/ci/verify-hap.py` | 门禁 | 新增双库与许可白名单、SONAME/NEEDED/RUNPATH 检查 | Python | 否 |
| `tests/ci-package.test.mjs` | 测试 | 同步库/许可夹具 | node:test | 是（宿主机） |
| `tests/clash/*.test.mjs` | 测试 | 状态机、URL 校验、组派生、patch、脱敏、分帧 | node:test | **是** |
| `tests/transpile.mjs` | 测试 | 新增 6 个纯 `.ts` 白名单 | TypeScript | 否 |

### 4.2 依赖方向（禁止反向依赖）

```text
pages/Index.ets
  → components/ProxyPage.ets
      → services/clash/ClashService.ets
          → ClashRpcClient.ets → ClashRpcProtocol.ts
          → ClashProfileStore.ets / ClashSubscriptionFetcher.ets / ClashConfigBuilder.ets
          → model/ClashStateMachine.ts → model/ClashModels.ts
          → ClashKeepAlive.ets

vpn/ClashVpnExtensionAbility.ets
  → services/clash/ClashVpnSession.ets
      → ClashCoreBridge.ets → libclash_bridge.so
      → ClashRpcServer.ets → ClashRpcProtocol.ts
      → ClashAssetInstaller.ets
      → model/ClashConfigPatch.ts / ClashProxyCatalog.ts / ClashRedaction.ts

禁止：services/clash/** 与 ets/vpn/** → services/TelegramService.ets / MediaNetworkMonitor.ets / 任何 TelephonyKit
禁止：UI 侧 import libclash_bridge.so
```

### 4.3 `Index.ets` 的改动点（设计级，实施时一次完成）

| 位置 | 改动 | 说明 |
| --- | --- | --- |
| `@State page`（L67 附近） | 新增取值 `'proxy'` | 不新增底部 Tab |
| `windowBackground()`（L351-355） | 条件加入 `page === 'proxy'` | 与 `storage` 同组返回 `pageBackground()`，避免手势区色差 |
| `settingsBody()`「数据与存储」分组（L2230-2234） | 在「存储管理」后插入「网络代理」`HdsSettingsRow`，摘要来自 `proxySummary()` | 与现有入口同构 |
| `openProxy()`（`openAbout` 附近 L1106） | `persistDraft()`；若在聊天则 `leaveChat()`；`page='proxy'` | 与 `openAbout` 同构 |
| `closeProxy()` | `page='home'; currentTab=2; syncNavigation()` | 返回设置页而非会话列表 |
| `goBack()`（L922-938）或 `onBackPress`（L268 附近） | 增加 `page==='proxy'` 分支转 `closeProxy()` | 系统返回与页面返回一致 |
| `build()` 分支（L2409 附近） | `else if (page==='proxy') { ProxyPage({ ... }) }` | 放在 `storage` 之后 |
| 订阅 | `ClashService` 单例由 `Index` 持有并传入 `ProxyPage`（`@Prop`/回调） | 避免页面重建导致会话重建 |

### 4.4 `module.json5` 改动（设计级）

| 项 | 值 | 依据 |
| --- | --- | --- |
| `requestPermissions` | 追加 `ohos.permission.KEEP_BACKGROUND_RUNNING`（`normal`/`system_grant`） | UI 进程长时任务前置 |
| `requestPermissions` | `ACCESS_EXTENSIONAL_DEVICE_DRIVER` 是否保留/新增 | 【待确认】SDK 26 定义为 `normal`，但 VPN 准入实际靠系统授权弹窗 |
| `abilities[EntryAbility]` | 追加 `backgroundModes: ["dataTransfer"]` | `startBackgroundRunning` 前置；必须配在 UIAbility |
| `extensionAbilities` | 追加 `{name:"ClashVpnExtensionAbility", srcEntry:"./ets/vpn/ClashVpnExtensionAbility.ets", type:"vpn", exported:false}` | 与现有 `EntryBackupAbility` 并列 |
| `deviceTypes` | 保持 `phone/tablet` | 不为 VPN 增加 `2in1` |

> 不新增 `MANAGE_VPN`：本机 SDK 26 中为 `system_basic`/`SYSTEM`，第三方应用不应声明；VPN 准入由系统授权弹窗触发。

### 4.5 构建/门禁改动点

| 文件 | 改动 | 原因 |
| --- | --- | --- |
| `entry/src/main/cpp/CMakeLists.txt` | 追加 `clash_bridge` target，DT_NEEDED 链接 `libclash_core.so`，链接 `libace_napi.z.so`/`libhilog_ndk.z.so`/`dl`，不设 RUNPATH | 双 NAPI 模块，内核仅在扩展加载 |
| `entry/oh-package.json5` | 追加 `"libclash_bridge.so": "file:./src/main/cpp/types/libclash_bridge"` | ArkTS 解析 NAPI 模块 |
| `scripts/ci/verify-hap.py` | `LIBRARIES` 加 `libclash_bridge.so`、`libclash_core.so`；`LICENSES` 加内核与依赖许可；新增 SONAME/NEEDED/RUNPATH 检查 | HAP 门禁 |
| `tests/ci-package.test.mjs` | 同步 `libraries`/`licenses` 夹具；新增「缺失内核库必须失败」用例 | 门禁自测 |
| `tests/transpile.mjs` | 追加 `model/ClashModels.ts`、`ClashStateMachine.ts`、`ClashProfileRules.ts`、`ClashConfigPatch.ts`、`ClashProxyCatalog.ts`、`ClashRedaction.ts`；`services/clash/ClashRpcProtocol.ts` | 宿主机测试 |
| `.gitignore` | 确认 `/entry/libs/*/*.so` 已忽略；新增 `artifacts/clash-*` | 二进制与源码包不提交 |

---

## 5. RPC 与进程通信

### 5.1 会话建立与凭据交接

**端口**：扩展每次会话 `bind({address:'127.0.0.1', port:0, family:1})`，由系统分配，绑定后断言 `port !== 47471` 且 `1024 ≤ port ≤ 65535`。旧固定端口 47471 永久禁用。

**token 生成**：UI 使用 `@kit.CryptoArchitectureKit` 的随机源生成 32 字节（256 bit）token，编码为 64 位小写十六进制；nonce 16 字节（32 hex）。token 只存在于 UI 内存、会话 req 文件与扩展内存，不写入 Preferences、日志、通知或 Want 参数。

**交接文件**（应用私有沙箱，两进程同属一个应用）：

```text
<files>/proxy/session/req-<nonce>.json   { "proto":1, "token":"<64hex>", "nonce":"<32hex>", "issuedAt":<epochms>, "ttlMs":15000 }
<files>/proxy/session/ack-<nonce>.json   { "proto":1, "port":<0-65535>, "pid":<int>, "bootId":"<16hex>", "ready":true }
```

规则：

1. UI 先删除同名旧文件，再写临时文件 `req-<nonce>.json.tmp` → `rename` 为正式文件（原子替换）；文件权限 `0600`，目录 `0700`。
2. `Want.parameters` 只携带 `{ clashSessionNonce, clashSessionFile }`（文件名为相对名，不是绝对路径）；不携带 token/端口。
3. 扩展 `onCreate`/`onConnect` 读取 req：校验 `nonce` 与文件名一致、`issuedAt` 未过期；不合法则删除并拒绝。
4. 扩展 `bind(0)` 成功后写 ack；随后**不删除 req**，直到鉴权成功才删除（避免 UI 重试时丢失）。
5. UI 轮询 ack（250 ms × 40 = 10 s）；读不到则 `failed(rpc_unavailable)`，不无限等待。
6. 每次启停/配置应用都生成新 nonce 与新 token；旧 token 立即失效。
7. 停止、崩溃、超时清理：删除 `req-*`/`ack-*`，目录为空。

**扩展已运行时的再握手**：UI 调 `startVpnExtensionAbility` 会触发 `onConnect(want)`；扩展在此关闭旧监听（先向旧连接推送 `fault{code:"session_rotated"}`）、清理旧会话、按新 nonce 重新 `bind(0)` 并写 ack。旧客户端收到 `session_rotated` 后不再重连，由 UI 以新 ack 建连。这样端口与 token 每次会话都变化（REQ-090）。

**失败语义**：端口绑定失败（`EADDRINUSE` 等）→ 重试 3 次（每次 100 ms 退避）；仍失败 → ack 写 `{ready:false, errorCode:"rpc_bind_failed"}`，UI 显示「内部服务连接失败」。

### 5.2 帧格式与上限

| 项 | 值 | 说明 |
| --- | --- | --- |
| 线格式 | 一行一个 UTF-8 JSON 对象，`0x0A` 结束 | 与上游一致；`JSON.stringify` 会转义字符串内换行 |
| 请求 | `{"id":"<string>","method":"<string>","params":<object>}` | `id` 形态 `u-<session8>-<seq>` 或 `e-<session8>-<seq>` |
| 响应 | `{"id":"...","result":<any>}` 或 `{"id":"...","error":{"code":"...","message":"..."}}` | 错误码为字符串枚举，不是自由文本 |
| 推送 | `{"push":"state"|"event"|"fault","data":<object>}` | 无 `id` |
| 单帧上限 | 1,048,576 字节 | 超限：立即断开并计数，不继续读 |
| 分帧方式 | 字节级按 `0x0A` 切分，再整行 UTF-8 解码 | 禁止按 TCP 块直接解码（跨块 UTF-8 会损坏） |
| 缓冲上限 | 未成帧缓冲 ≤1 MiB；超过即断开 | 防止无换行大帧导致内存增长 |
| 最大连接数 | 4 | 超限拒绝新连接（不排队） |
| 速率限制 | 每连接 50 req/s，突发 100；全局 200 req/s | 超限返回 `rate_limited`，连续 3 次断开 |
| 空闲超时 | 30 s 无请求/推送则关闭连接 | 降低端口暴露面 |
| 待响应上限 | 每客户端 256；每服务端 512 | 超限拒绝新请求 |

### 5.3 鉴权

- **首帧唯一允许的方法**是 `auth`；在 5 s 内未收到合法 auth → 断开，计数 `authTimeout`。
- `auth.params = { token, nonce, proto }`；扩展校验 `nonce` 与本次会话一致、`token` 长度 64、`proto === 1`。
- 比较使用常数时间算法（逐字节 XOR 累积，不短路）；失败 → `error{code:"auth_failed"}` → 立即断开，记录原因码（不记录 token）。
- 鉴权成功后返回 `{proto, sessionId, pid, bootId, serverTime}`；`sessionId` 为随机 16 hex，不含 token。
- 未鉴权连接：不能调用任何方法、不能收到任何推送；`push` 只向已鉴权连接发送。
- 旧 token 再用：连接可建立，但 auth 失败并计数 `staleToken`。

### 5.4 RPC 方法表（本项目自定义，不是 mihomo Action）

| 方法 | 参数 | 返回 | 默认超时 | 语义 |
| --- | --- | --- | --- | --- |
| `auth` | `{token,nonce,proto}` | `{proto,sessionId,pid,bootId,serverTime}` | 5 s | 首帧；失败即断开 |
| `hello` | `{}` | `{coreLoaded,coreVersion,capabilities:{tun,protect,asyncStart},homeDirKind:"files"}` | 5 s | 只读探测；不加载内核、不请求授权 |
| `core.init` | `{homeDirKind:"files"}` | `{initialized,isInit,version}` | 30 s | 异步 `initClash {home-dir, version:29}` |
| `core.quickStart` | `{init,params,state}` | `{error:string}`（空=成功） | 120 s | 回调式异步 `quickStart` |
| `core.action` | `{action:{id,method,data}}` | `ActionResult` 原样结构 | 按方法（下表） | 唯一 Action 通道；扩展校验 method 白名单 |
| `tun.start` | `{scope:"global"|"harlgramOnly", state:CoreState}` | `{fd,startedAt,evidence:{coreReady,tunReady,routeReady},options}` | 120 s | 构造 VpnConfig、create、startTun |
| `tun.stop` | `{}` | `{stopped,released:{tun,rpc},warnings:[]}` | 30 s | 停止 TUN 并收敛端口 |
| `vpn.options` | `{}` | `VpnOptions`（已校验） | 10 s | `getAndroidVpnOptions` + 字段兜底 |
| `notification.update` | `{title,text}` | `{updated}` | 5 s | 基础通知；文案不含凭据 |
| `diagnostics.snapshot` | `{}` | `{protect:{attempts,failures,timeouts,lastCode},session:{epoch,uptimeMs},counters}` | 5 s | 脱敏计数 |
| `session.shutdown` | `{}` | `{closed}` | 30 s | 停止全部、`shutdown` Action、关闭监听 |

**`core.action` 的 method 白名单**（仅这些允许从 UI 发起）：`getProxies`、`changeProxy`、`asyncTestDelay`、`healthCheck`、`getConfig`、`validateConfig`、`setupConfig`、`updateConfig`、`getConnections`、`closeConnections`、`getCoreVersion`、`getTraffic`、`getTotalTraffic`、`resetTraffic`、`getRunTime`、`getCurrentProfileName`、`getAndroidVpnOptions`、`getIsInit`、`setState`、`shutdown`、`startLog`、`stopLog`、`getMemory`、`forceGc`。其余一律拒绝 `method_not_allowed`。

**Action 超时表**：

| Action | 超时 | 备注 |
| --- | --- | --- |
| `getProxies` | 15 s | 大配置可能较慢 |
| `changeProxy` | 15 s | 仅 Selector 组允许 |
| `asyncTestDelay` | `timeout + 2 s`（默认 7 s） | 单节点 |
| `healthCheck` | 30 s | 批量结果走 delay 事件 |
| `getConfig` | 20 s | 20 MB 级配置留余量 |
| `validateConfig` | 30 s | YAML 解析 |
| `setupConfig` | 60 s | 应用配置 |
| `getConnections` | 15 s | 仅诊断/可选 |
| `getCoreVersion` | 5 s | — |
| `shutdown` | 10 s | — |

### 5.5 超时、断线与崩溃预算

- **请求超时**：客户端按方法超时 reject；超时后从 pending 表移除并发送 `cancel` 语义（不再等待响应）；迟到的响应按 `id` 丢弃。
- **断线检测**：TCP `close`/`error` 立即触发 `onDisconnected`；UI 状态机收到 `linkLost`：
  - 若当前为 `connected` → 先转 `preparing(reason="reconnect")`，不立刻 `failed`。
  - 重连预算：最多 5 次，退避 `1,2,4,8,16 s`（上限 16 s）；成功且稳定 60 s 后清零。
  - 预算耗尽 → `failed(extension_crashed)`，停止自动重连，仅保留手动重试。
- **扩展崩溃**：`onDestroy` 推送 `fault{code:"extension_destroyed"}`；若来不及推送，由连接断开推断。
- **自动重连不得重复授权**：重连只重建 RPC 会话；若发现 TUN 已不存在（`getRunTime()` 为 0），必须回到 `preparing` 并重新走 `tun.start`（系统可能再次弹授权【待确认】）。
- **单飞**：UI 侧 `startInFlight`/`stopInFlight` 保证同一时刻最多一个启停操作；重复点击合并为最后一次明确意图。

### 5.6 停止收敛

`tun.stop` 的执行顺序与失败处理：

1. `stopTun()`（内核停止隧道；失败也继续）。
2. `conn.destroy()`（系统释放 TUN；失败记 warning）。
3. 关闭所有 RPC 连接（先推送 `state{stopped}`）。
4. 关闭监听 socket；断言端口不再监听。
5. 删除 `req-*`/`ack-*`/`sessionId` 内存态。
6. 返回 `{stopped:true, released:{tun, rpc}, warnings:[...]}`；任一释放失败 → `stopped_with_warning`，UI 明确提示「已停止，但存在未释放资源」。

停止后 60 s 内无新会话：执行 `shutdown` Action（释放内核）→ 若 SDK 26 提供 `terminateSelf()` 则结束扩展进程；否则等待系统回收。再次开启必须重新 `core.init`。

### 5.7 推送与事件最小化

| 推送 | 频率 | 字段 | 禁止 |
| --- | --- | --- | --- |
| `state` | 状态变化时 | `{state,epoch,errorCode?,activeNodeName?,startedAt?,scope}` | 不含路径、URL、token、域名 |
| `event` | 由内核事件驱动 | `type ∈ {loaded, delay, traffic, log}`；`delay{name,url,value}`；`traffic{up,down}`（1 Hz 聚合）；`log{level,code}` | 不转发 `request`/连接明细；不转发原始 JSON |
| `fault` | 异常时 | `{code,detailCode,count}` | 不含堆栈与敏感参数 |

- `log` 默认只推送 `error`/`warning` 的**分类码**；调试级别只在开发者入口开启。
- 事件对象不落盘；UI 侧只保留聚合值与最后 N 条分类计数。
- 节点名可以推送给 UI（界面需要展示），但不得写入日志/诊断导出；导出时节点名哈希化（`ClashRedaction`）。

### 5.8 安全失败语义

- 任何 RPC 错误都必须是**结构化错误码** + 用户可读建议，不允许返回空串/`true`/`0` 表示失败。
- `hello.coreLoaded=false` 是硬失败：UI 直接 `failed(core_missing)`，不请求 VPN 授权。
- `auth` 失败、端口绑定失败、帧超限、限流：均记录计数与原因码，不记录内容。
- 诊断快照只含计数、状态、错误码、版本；不含配置文本。

---

## 6. NAPI / Go 桥改造

### 6.1 双 target 与链接模型

**现状【事实】**：`entry/src/main/cpp/CMakeLists.txt` 只有 `entry` 一个 target（`napi_init.cpp`），链接 `libace_napi.z.so` 与 `dl`；`entry/libs` 当前不存在。

**设计**：保留 `entry`，追加 `clash_bridge`，一个 `externalNativeOptions.path` 覆盖两个 target。

| 项 | 设计值 | 理由 |
| --- | --- | --- |
| target 名 | `clash_bridge` | 与 `libclash_bridge.so`、`nm_modname="clash_bridge"` 一致 |
| 源文件 | `clash/clash_bridge.cpp` | 与新目录一致，避免污染 TDLib 桥 |
| 标准 | C++17，禁用编译器扩展 | 与现有 target 一致 |
| 内核链接 | `target_link_libraries(clash_bridge PRIVATE ${NATIVERENDER_ROOT_PATH}/../../../libs/${OHOS_ARCH}/libclash_core.so)` | 生成 `DT_NEEDED libclash_core.so` |
| 系统库 | `libace_napi.z.so`、`libhilog_ndk.z.so`、`dl` | NAPI、日志、`dlopen` |
| RUNPATH | **不设置** | 禁止指向构建机绝对路径；依赖应用库目录解析 SONAME |
| 输出 | `libclash_bridge.so`（SONAME 同名） | 与 `libentry.so` 并列 |
| 内核 SONAME | 构建时 `-Wl,-soname,libclash_core.so` | 保证 `DT_NEEDED` 可解析 |
| ABI | `arm64-v8a`（`OHOS_ARCH` 来自工具链） | 本轮唯一 ABI；变量名待构建日志确认【待确认】 |

**为什么必须是 DT_NEEDED【事实】**：Go c-shared runtime 使用 initial-exec TLS；musl 只允许进程启动时加载的库使用该模型，运行时 `dlopen()` 会报 `initial-exec TLS resolves to dynamic definition`。因此 `libclash_bridge.so` 必须以 `DT_NEEDED` 依赖内核，再由 `dlopen("libclash_core.so")` 绑定到已加载实例（`dlsym` 按 handle 查找）。**不得**改为运行时首次 `dlopen` 内核。

**加载位置**：`clash_bridge` 只在 VPN 扩展进程被 import；UI 进程的 `libentry.so` 不链接、不依赖内核。

### 6.2 NAPI 导出（ArkTS 可见）

| 导出 | 签名 | 线程模型 | 说明 |
| --- | --- | --- | --- |
| `initCore(homeDir)` | `(string) => boolean` | 同步（短） | 仅注册回调、`setEventListener`、`initClashSync(29, homeDir)`；失败返回 false 并记录 `core_init_failed` |
| `initCoreAsync(homeDir)` | `(string) => Promise<CoreInitResult>` | `napi_async_work` | 推荐路径；避免长初始化阻塞 JS 线程 |
| `quickStartAsync(init, params, state)` | `(string,string,string) => Promise<string>` | `napi_async_work` + 回调式 `quickStart` | **不使用** `quickStartSync`；返回值空串=成功 |
| `invokeAction(json)` | `(string) => void` | 异步回调 | fire-and-forget；结果经 dispatcher/TSFN 回投 |
| `startTun(fd)` | `(number) => boolean` | 同步（短） | fd 所有权转移给内核；失败时内核可能已关闭 fd，不重复 close |
| `stopTun()` | `() => void` | 同步（短） | 仅停止 TUN，不销毁 VpnConnection |
| `getRunTime()` | `() => number` | 同步（短） | epoch ms；`0` 表示未启动 |
| `getAndroidVpnOptions()` | `() => string` | 同步（短） | 内核建议的 TUN 参数 JSON |
| `getCurrentProfileName()` | `() => string` | 同步（短） | 仅展示 |
| `updateDns(json)` | `(string) => void` | 同步（短） | 可选；MVP 不调用 |
| `setState(json)` | `(string) => void` | 同步（短） | `CoreState` |
| `shutdownCore()` | `() => boolean` | 同步（短） | 发 `shutdown` Action；结果非 UI 关键 |
| `notifyProtected(fd)` | `(number) => void` | 同步（短） | 解除 Go dialer 等待 |
| `getProtectStats()` | `() => string` | 同步（短） | `{attempts,failures,timeouts,dropped,lastFd}`，用于诊断 |
| `setEventSink(callback)` | `((payload:string)=>void) => void` | 创建 TSFN | 只允许设置一次；重复设置先释放旧 TSFN |

**d.ts 约束**：不暴露裸对象/`any`；入参统一 JSON 字符串或显式标量；`Promise` 结果使用显式接口。`types/libclash_bridge/oh-package.json5` 的 `name` 必须是 `libclash_bridge.so`。

### 6.3 TSFN 设计

| TSFN | 容量 | 投递模式 | 满时策略 | 用途 |
| --- | --- | --- | --- | --- |
| event | 64 | `napi_tsfn_nonblocking` | 计数 `eventDropped++`，丢弃并告警（不阻塞 Go） | `event`（delay/traffic/loaded/log） |
| actionResult | 256 | `napi_tsfn_nonblocking` | 计数 `resultDropped++`；对应请求按超时失败 | Action 响应 |
| protect | 64 | `napi_tsfn_nonblocking` + 5 ms 退避重试 | 重试至 3 s；仍失败 → `protectDropped++`，再过 3 s 超时后返回 | protect 握手 |

**为什么分开**：上游单一 TSFN 容量 4，protect 与 event/actionResult 争用；队列满会导致 protect 被丢弃，Go 直接放行未保护 socket，形成环路。分离后 protect 有独立容量与优先级语义（先投 protect，再投 event）。

**payload 形态**：一律 UTF-8 JSON 字符串（`char*`），不要传结构体指针；`napi_create_string_utf8` 后调用 JS 回调，避免把 JSON 前 8 字节当指针。

### 6.4 protect 线程契约与可靠性

**契约【事实】**：Go dialer 在 socket `connect()` 之前进入 `TrampProtect`，阻塞等待 ArkTS 调用 `VpnConnection.protect(fd)` 后回执；上游 1500 ms 超时、失败仍 ack、队列 4。

**设计**：

```text
Go dialer goroutine
  └─ protect(fd)
       ├─ protectPending[fd] = 0
       ├─ 投递 {type:"protect", data:{fd}} 到独立 protect TSFN
       │    ├─ 成功 → 等待 ack，≤3000 ms
       │    └─ 队列满 → 5 ms 退避重试，总预算 3000 ms
       │         └─ 仍失败 → dropped++，记录 lastCode=queue_full
       └─ 超时/失败 → timeouts++；**仍调用 notifyProtected(fd)** 解除阻塞（避免 Go 永久卡死）

扩展 ArkTS 线程
  ├─ 收到 protect → vpnConnection.protect(fd)
  │    ├─ 成功 → notifyProtected(fd)
  │    ├─ 失败 → failures++，记录 lastCode=protect_rejected → notifyProtected(fd)
  │    └─ vpnConnection 为空（尚未建立）→ 立即 failures++ → notifyProtected(fd)
  └─ Promise 链不允许 await 其他慢操作
```

**关键规则**：

1. `fd <= 0` 的 protect 请求直接拒绝并计数，不得 ack 成功。
2. `fd` 作为 map key 必须带「会话 epoch」与「代次」，避免 fd 快速复用时 ack 错配；`notifyProtected` 对未知 fd 计数 `unknownFd++`。
3. protect 失败不是「静默放行」：`getProtectStats` 记录 attempts/failures/timeouts/dropped；扩展在 `state`/`diagnostics` 中上报。
4. **降级判定**：连续 3 次 protect 失败，或 60 s 内失败 ≥5 次，或失败率 >1% 且 attempts ≥100 → `protect_degraded`：
   - 立即停止 TUN（防止环路），状态转 `failed(protect_degraded)`；
   - UI 文案「网络保护异常，已停止代理」+ 建议「重试或重启应用」；
   - 不自动无限重试。
5. 首次失败只提示「网络保护异常（已记录）」，不立刻断开；计数清零条件：连续 60 s 无失败。
6. `vpnConnection === null` 时收到 protect 视为异常（说明 TUN 未建立但内核已 dial），必须计数并拒绝；不允许「无保护放行」。

**压测验收**：≥50 并发建连、连续 10 分钟产生流量，`failures=0`、`timeouts=0`、`dropped=0`、无 `reject loopback` 类错误。

### 6.5 异步化与避免阻塞

| 调用 | 问题 | 设计 |
| --- | --- | --- |
| `quickStartSync` | 在 JS 线程同步执行 init+setState+setupConfig；大配置数百 ms 到数秒，期间 protect 无法 ack | 改用 C ABI 的回调式 `quickStart`，在 `napi_async_work` 线程执行，完成后 TSFN 回投；RPC `core.quickStart` 返回 Promise |
| `initClashSync` | 初始化含 GC/内存限制设置，短但可能触发 Go runtime 启动 | 提供 `initCoreAsync`；RPC `core.init` 使用异步版本 |
| 大 JSON 解析 | 1 MiB 帧在 JS 线程解析 | 帧上限 1 MiB；超限断开；解析只做一次，不复制多份 |
| 同步文件拷贝（geo 42.8 MB） | 首启会卡 UI | 只在扩展进程、`napi_async_work` 或分块异步执行；有进度与超时；UI 显示「正在准备代理数据」 |
| 日志/诊断写盘 | 可能阻塞 | 只写白名单字段、异步队列、单文件 ≤5 MB、保留 ≤2 份 |

### 6.6 `getConfig` 路径白名单

**事实**：core 的 `getConfig` 只 `os.Stat/ReadFile`，没有 `Path.IsSafePath` 校验；上游 `getConfig` 接受任意路径。**风险**：本机同 sandbox 的攻击者/错误调用可读任意可读文本并得到解析后的 `RawConfig`。

**设计**：

1. UI **不向扩展传路径**；RPC `core.action` 对 `getConfig` 只接受 `data = "<profileId>"`，由扩展拼成 `<home>/profiles/<profileId>.yaml`。
2. `profileId` 只允许 `[A-Za-z0-9_-]{1,64}`；拒绝 `.`/`..`/`/`/`\`/NUL/绝对路径。
3. 扩展拼路径后规范化：必须满足 `canonicalPath.startsWith(home + '/profiles/')` 且不含符号链接逃逸（`fs.realpath` 后再次校验前缀）；不满足 → `path_rejected`，不调用内核。
4. provider 文件同理限定在 `<home>/profiles/providers/<profileId>/`。
5. 内核 home 与 ArkTS 配置根必须同为 `.../el2/base/files`；否则 core 的 `SAFE_PATHS` 会拒绝并弹阻塞式对话框（上游已踩坑）。

### 6.7 `external-controller` 与本地监听面

| 项 | 设计 | 理由 |
| --- | --- | --- |
| `external-controller` | 强制 `""`（关闭） | 上游默认 `127.0.0.1:9090` 且 secret 常为空，同机可访问 REST API |
| `external-ui` | 强制 `""` | 不使用 zashboard；避免额外 Web 资源与路径 |
| `secret` | 强制 `""` | 关闭时无意义；不写入日志 |
| `mixed-port`/`port`/`socks-port`/`redir-port`/`tproxy-port` | 全部 `0` | TUN 模式不需要本地代理端口；减少监听面 |
| `allow-lan` | `false` | 不暴露局域网 |
| `bind-address` | `127.0.0.1`（若 profile 设置） | 即使误开端口也仅回环 |
| 开发者临时开启 | 仅开发者入口、随机端口 + 随机 secret、退出即关闭 | 【待确认】是否需要；MVP 不做 |

**验收**：代理运行时 `netstat`/`ss` 不出现 9090；只有扩展会话的随机端口在监听，停止后消失。

### 6.8 原生侧错误与日志

- `initCore` 失败：`dlopen` 失败、符号缺失、`initClashSync` 返回 false → 分别记录 `core_load_failed`/`core_symbol_missing`/`core_init_failed`，由 NAPI 返回结构化结果，不打印路径。
- stdio 重定向：`<files>/logs/core.log`；默认只保留 warning/error；单文件 ≤5 MB、保留 ≤2 份；发布构建不开启 debug。
- 日志字段白名单：时间、模块、级别、错误码、状态名、计数；禁止完整 Action JSON、完整 `SetupParams`、订阅正文、节点地址、域名。
- 崩溃：Go panic 不得导致 UI 进程退出（独立进程）；`crash` Action 仅用于测试。

---

## 7. VPN 扩展设计

### 7.1 生命周期

| 回调 | 行为 |
| --- | --- |
| `onCreate(want)` | 计算 `homeDir`；创建 `ClashRpcServer`；注册 handler；读取会话 req；`bind(0)`；写 ack；发布基础通知（可选）；**不加载内核** |
| `onConnect(want)` | 读取新 nonce；轮换会话（关闭旧监听/旧连接、重新 bind、写 ack）；不重复加载内核 |
| `onDisconnect(want)` | 记录；不停止代理（由 RPC `tun.stop` 控制） |
| `onDestroy()` | 推送 `fault{extension_destroyed}`；`stopTun()`；`conn.destroy()`；关闭 RPC；删除会话文件；取消通知 |

**homeDir 计算【事实】**：

```text
extFilesDir = this.context.filesDir            // .../el2/base/haps/entry/files
idx = extFilesDir.indexOf('/haps/')
homeDir = idx > 0 ? extFilesDir.substring(0, idx) + '/files' : extFilesDir   // .../el2/base/files
```

`homeDir` 同时是内核 `home-dir`、profile 根、geo 根、日志根；UI 侧使用同一路径（通过 `UIAbilityContext.filesDir` 得到 `.../el2/base/files`）。若两者不一致，内核 `SAFE_PATHS` 会拒绝 UI 传入的路径并弹阻塞对话框。

### 7.2 扩展进程代码隔离

**禁止 import**：`@ohos.contact`、`@ohos.geolocation`/`geoLocationManager`、`@ohos.multimedia.audio`、`@ohos.multimedia.camera`、`@ohos.telephony.call`、`@ohos.telephony.sim`、`@ohos.telephony.sms`、`@kit.TelephonyKit`（含 `radio`）。

**禁止依赖 UI 模块**：`services/TelegramService.ets`、`services/MediaNetworkMonitor.ets`、`telegram/**`、`data/**`、`components/**`、`pages/**`。

**网络类型**：若扩展需要（MVP 不需要），通过 RPC `network.info` 向 UI 请求；UI 返回 `{mediaNetwork, isRoaming}` 的**分类结果**，不返回 SSID/运营商/IP。

**静态复核**：编译前用检索验证扩展目录的 import 集合；SDK 26 真实编译 + 静态检索双重复核。

### 7.3 VpnConfig 构造

**输入**：`vpn.options`（Action `getAndroidVpnOptions` 返回）+ `scope` + 自身 bundleName。

| `VpnConfig` 字段 | 值 | 说明 |
| --- | --- | --- |
| `addresses` | `[{address:'172.19.0.1', prefixLength:30}]`，IPv6 开启时追加 `fdfe:dcba:9876::1/126` | 与上游 `state` 默认一致 |
| `routes` | `routeAddress`（来自 options）；为空时 `0.0.0.0/0`；IPv6 开启时追加 `::/0` | 空 = 全局路由 |
| `mtu` | `1420` | 与内核 `core/tun` 夹紧值一致（SDK 允许 576–1500） |
| `dnsAddresses` | `['172.19.0.2']` | 与内核 `dns-hijack 172.19.0.2:53` 一致 |
| `isIPv4Accepted` | `true` | — |
| `isIPv6Accepted` | `ipv6Address !== ''` | 仅由地址决定 |
| `isInternal` | `false` | — |
| `isBlocking` | `false` | — |
| `trustedApplications` | `scope==='harlgramOnly'` → `[<自身 bundleName>]`（默认 `xyz.3333189.harlgram`，运行时从 `bundleManager` 读取）；`global` → `[]` | 白名单只含自身 bundle |
| `blockedApplications` | 始终 `[]` | 与 trusted 互斥；上游测试机上 blocked 表现为「黑洞」断网 |

**校验规则**：

- `options` 缺字段/空串/非法地址 → 使用设计默认值并记录 `options_fallback`；不得把 `undefined` 传给 `VpnConfig`。
- `trustedApplications` 与 `blockedApplications` 不能同时非空；构造后断言。
- `port`/`bypassDomain` 在 OHOS 扩展中无用途，**直接忽略**（`port` 来自 `mixed-port`；`bypassDomain` 上游 OHOS 未实现）。
- `options.accessControl` 不使用（MVP 不做分应用名单）。
- 地址/路由/IPv6 任一不合法 → `failed(tun_config_invalid)`，不调用 `create`。

**fd 所有权**：`conn.create(config)` 返回 fd；`startTun(fd)` 后所有权转移给内核。`startTun` 失败时调用 `conn.destroy()`，**不重复 `close(fd)`**（内核可能已关闭）。

### 7.4 授权与首次开启

- 系统授权弹窗在 `conn.create()` 时出现，不是 manifest 权限；`MANAGE_VPN` 不声明。
- 首次开启前 UI 先说明「系统将请求允许 HmChat 建立 VPN 连接」，再触发 `tun.start`。
- 用户拒绝：`create` 抛出/返回失败 → `failed(auth_denied)`；开关回弹；不建立 TUN、不写凭据、不启用保活；再次开启允许重新触发。
- 授权成功：不重复弹窗；配置/节点切换不需要重新授权（仅 TUN 重建时可能触发【待确认】）。

### 7.5 三重证据的扩展侧实现

`tun.start` 返回：

```text
{
  fd: <number>,                  // >0
  startedAt: <epochms>,
  evidence: {
    coreReady: true,             // core.init + quickStart 成功
    tunReady: true,              // fd>0 且 startTun=true 且 getRunTime()>0
    routeReady: true             // conn.create 成功（地址/路由/DNS 被系统接受）
  },
  options: { ipv4Address, ipv6Address, dnsServerAddress, mtu, scope, trustedOnly }
}
```

任一 `false` → RPC 返回结构化失败，UI 不进入 `connected`。`routeReady` 目前只能以 `conn.create` 成功为依据；更细的路由生效检查需系统 API【待确认】。

### 7.6 protect（扩展侧）

见 §6.4。扩展侧额外约束：

- `onCoreEvent` 中 protect 分支必须**先**处理、**不 await** 其他慢操作；`conn.protect(fd)` 的 Promise 链只做 `notifyProtected`。
- 失败/超时均调用 `notifyProtected`，但必须计数并上报；不得「失败仍当作成功」。
- 停止 TUN 前先等待所有 pending protect 结算或 3 s 超时，避免 fd 复用错配。

### 7.7 通知

| 项 | 设计 |
| --- | --- |
| 通知 ID | `1001`（固定） |
| 类型 | `NOTIFICATION_CONTENT_BASIC_TEXT` |
| 标题 | 「HmChat 网络代理」 |
| 正文 | 「已连接」/「正在启动」/「已停止」；可附当前节点名（用户可见名称），**不含**订阅 URL、域名、服务器地址、密码 |
| 停止动作 | 可选：`WantAgent` 指向 UI 的停止入口；【待确认】API 26 通知动作能力 |
| 失败 | 发布失败只告警并计入诊断；不影响代理 |
| 停止后 | 立即取消通知，不残留「VPN 运行中」 |

### 7.8 KeepAlive（UI 进程）

**事实**：`startBackgroundRunning` 只能从 UIAbility 上下文调用，扩展调用返回 401；`DATA_TRANSFER` 约 10 分钟无「进度 + 真实流量」会被回收。

**设计**（`ClashKeepAlive.ets`）：

1. 仅在进入 `connected` 后 `enable(UIAbilityContext)`；`stop`/`failed`/`unauthorized` 立即 `disable()`。
2. `wantAgent` 使用 `actionType: START_ABILITY`、`actionFlags: [UPDATE_PRESENT_FLAG]`；目标为 `EntryAbility`。
3. `startBackgroundRunning(context, ['dataTransfer'], agent)` 返回 `notificationId`；每 60 s 发布 `NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW`、`SlotType.LIVE_VIEW`、`downloadTemplate` 进度（沿用已验证的上游方案）。
4. 监听 `continuousTaskStateChange`（若 API 26 提供【待确认】）：任务被系统取消时，UI 立即探测 `hello`/`getRunTime`，状态不保留 `connected`。
5. 不把 KeepAlive 放扩展；不修改 `extensionAbilities.backgroundModes` 作为主方案（若后续验证 API 26 支持，可作为补充，不改主路径）。
6. 应用退到后台/锁屏时，UI 线程可能被冻结；RPC 推送由扩展继续，UI 恢复后通过 `hello` + `diagnostics.snapshot` 重建状态。

### 7.9 错误码（扩展与 UI 共用）

| 错误码 | 用户文案 | 建议 | 触发 |
| --- | --- | --- | --- |
| `core_missing` | 此安装包不包含代理内核 | 更换完整安装包 | `dlopen` 失败/符号缺失 |
| `core_load_failed` | 代理内核加载失败 | 重启应用；仍失败则更换安装包 | 加载异常 |
| `core_init_failed` | 代理服务初始化失败 | 重试；检查存储空间 | `initClashSync` false |
| `config_missing` | 尚未导入配置 | 导入订阅或本地配置 | 无有效 profile |
| `config_invalid` | 配置无法使用 | 重新导入或更新订阅 | `validateConfig`/`quickStart` 返回非空错误 |
| `tun_config_invalid` | 网络参数无效 | 重试；反馈诊断 | VpnConfig 校验失败 |
| `tun_create_denied` | 未获得 VPN 授权 | 重新开启并允许系统授权 | 用户拒绝 |
| `tun_create_failed` | 无法建立 VPN 连接 | 重试；检查是否被其他 VPN 占用 | `create` 异常 |
| `tun_start_failed` | 代理启动失败 | 重试或重启应用 | `startTun` false |
| `tun_route_failed` | 网络路由配置失败 | 重试；切换网络 | 路由/DNS 下发失败 |
| `rpc_unavailable` | 内部服务连接失败 | 重试或重启应用 | 端口/连接/ack 超时 |
| `rpc_auth_failed` | 内部服务校验失败 | 重启应用 | 首帧 token 错误 |
| `path_rejected` | 配置路径无效 | 重新导入配置 | 路径越界/非法 profileId |
| `protect_degraded` | 网络保护异常，已停止代理 | 重试；仍失败请反馈 | protect 连续/高频失败 |
| `extension_crashed` | 代理服务异常退出 | 手动重试 | 崩溃预算耗尽 |
| `timeout` | 启动超时 | 重试 | 60 s 启动预算 |
| `unsupported` | 当前系统不支持该功能 | 升级系统或使用其他设备 | API/能力缺失 |
| `internal` | 操作失败 | 重试；反馈诊断 | 未分类 |

**UI 分类原则**：配置问题不显示「未授权」；授权问题不显示「配置无效」；内核缺失不请求授权。

---

## 8. 数据模型与存储

### 8.1 模型清单

| 模型 | 用途 | 持久化 | 敏感 |
| --- | --- | --- | --- |
| `ProxyProfile` | 配置/订阅元数据 | Preferences + Asset 引用 | 部分（`sourceRef`） |
| `ProxySettings` | 范围、意图、上次选择 | Preferences | 否 |
| `ProxyNode` | 节点展示 | 不持久化（由内核派生） | 否 |
| `ProxyGroup` | 组展示 | 不持久化 | 否 |
| `DelayMap` | 测速结果 | 仅内存 | 否 |
| `ProxyRuntimeSnapshot` | 运行事实 | 仅内存（可重建） | 否 |
| `ProxyError` | 分类错误 | 随快照/迁移记录 | 否 |
| `CoreAction`/`ActionResult` | RPC/Action 信封 | 不持久化 | 可能含配置（仅内存） |
| `SetupParams` | 应用配置载荷 | 不持久化（可回滚快照在内存） | 是（含节点凭据） |
| `VpnOptions` | TUN 参数 | 不持久化 | 否 |
| `SessionDescriptor` | 端口/token 交接 | 临时文件（0600） | 是（token） |

### 8.2 字段定义与 Dart 对应

**ProxyProfile**

| 字段 | 类型 | 语义 | Dart 对应 |
| --- | --- | --- | --- |
| `id` | string | `[A-Za-z0-9_-]{1,64}`，本地生成 | `Profile.id` |
| `displayName` | string | 用户可见名，≤64 字符 | `label` |
| `sourceKind` | `'subscription'|'localYaml'` | 来源 | `url.isEmpty` 推断 |
| `sourceRef` | string? | Asset 中的键（不是 URL） | `url`（但不明文存 Preferences） |
| `configFileName` | string | `<id>.yaml` | `getProfilePath(id)` |
| `nodeCount` | number | 最近成功解析节点数 | 派生 |
| `groupCount` | number | 最近成功解析组数 | 派生 |
| `contentHash` | string | SHA-256（hex） | 无（新增） |
| `updatedAt` | number? | 最近成功时间（epoch ms） | `lastUpdateDate` |
| `lastAttemptAt` | number? | 最近尝试时间 | 无（新增） |
| `lastErrorCode` | string? | 最近失败分类 | 无（新增） |
| `isActive` | boolean | 唯一生效 | `currentProfileId` 对应 |

**ProxySettings**

| 字段 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `schemaVersion` | number | 1 | 迁移用 |
| `scope` | `'global'|'harlgramOnly'` | `global` | 与开关分离存储 |
| `enabledIntent` | boolean | false | 仅意图，不推导状态 |
| `lastActiveProfileId` | string? | null | 重建用 |
| `lastSelectedNodeName` | string? | null | 重建用 |
| `testUrl` | string | `https://www.gstatic.com/generate_204` | 非敏感；可配置 |
| `batchConcurrency` | number | 4 | 4–8 |
| `autoUpdate` | boolean | false | 本 MVP 不实现，固定 false |
| `experimentalScopeAck` | boolean | false | 「仅 HmChat」提示已确认 |

**ProxyNode / ProxyGroup / DelayMap**

| 字段 | 类型 | 来源 |
| --- | --- | --- |
| `ProxyGroup.name` | string | `getProxies` 键 |
| `ProxyGroup.type` | `Selector|URLTest|Fallback|LoadBalance|Relay` | `getProxies[name].type` |
| `ProxyGroup.isAuto` | boolean | URLTest/Fallback/LoadBalance/Relay |
| `ProxyGroup.now` | string? | 组当前出口（解析到叶子） |
| `ProxyGroup.nodeNames` | string[] | `all` |
| `ProxyGroup.hidden` | boolean? | `hidden` |
| `ProxyNode.id` | string | `groupName + '/' + name`（不哈希，仅内存键） |
| `ProxyNode.displayName` | string | `name` |
| `ProxyNode.groupName` | string | 所属组 |
| `ProxyNode.protocolLabel` | string | `type`（大写展示，如 `SS`/`VMESS`） |
| `ProxyNode.availability` | `available|unavailable` | 类型/字段/`alive` |
| `ProxyNode.unavailableReason` | string? | 用户可读、脱敏 |
| `DelayMap[url][proxyName]` | `{value:number, at:number, state:'ok'|'timeout'|'error'}` | `asyncTestDelay`/`delay` 事件 |

**ProxyRuntimeSnapshot**

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `state` | 六态枚举 | 唯一真值 |
| `epoch` | number | 本次会话 |
| `coreVersion` | string? | 不可得显示「未知」 |
| `activeProfileId` | string? | 内核实际加载 |
| `activeNodeName` | string? | 内核实际出口 |
| `scope` | `global|harlgramOnly` | 实际生效 |
| `startedAt` | number? | 连接建立时间 |
| `errorCode`/`userMessage`/`nextAction` | string? | 结构化错误 |
| `protectFailureCount` | number | 诊断 |
| `rpcPort` | number? | 仅诊断，不展示 |
| `sessionId` | string? | 不持久化、不含 token |

**与 Dart 模型的总对应**：`ProxyProfile` ↔ `lib/models/profile.dart` 的 `Profile`（`url` 改为 Asset 引用，新增 `contentHash`/`lastAttemptAt`/`lastErrorCode`）；`ProxySettings` ↔ `Config` 中的 `VpnProps`/`NetworkProps`/`AppSettingProps` 子集（`scope` 为新增，替代分应用 `accessControl`）；`ProxyNode` ↔ `Proxy`（`name`/`type`/`now`/`serverDescription`）；`ProxyGroup` ↔ `Group`（`type`/`all`/`now`/`hidden`/`testUrl`/`icon`）；`DelayMap` ↔ `providers/app.dart` 的 `Map<url, Map<proxy, int?>>`（`-1` 失败、`0` 加载中）；`ProxyRuntimeSnapshot` ↔ `getCoreState`/`ClashManager` 的运行时状态（新增六态与错误枚举）。HmChat 不使用 Dart 的 `overrideData`/`scriptProps`/DAV/主题/窗口字段。

**错误枚举**：`core_missing`、`core_load_failed`、`core_init_failed`、`config_missing`、`config_invalid`、`tun_config_invalid`、`tun_create_denied`、`tun_create_failed`、`tun_start_failed`、`tun_route_failed`、`rpc_unavailable`、`rpc_auth_failed`、`path_rejected`、`protect_degraded`、`extension_crashed`、`timeout`、`unsupported`、`internal`。

### 8.3 存储归属

| 数据 | 介质 | 位置/键 | 理由 |
| --- | --- | --- | --- |
| 订阅 URL（含 token） | Asset | alias `harlgram.proxy.v1`，secret JSON `{version:1,entries:{<profileId>:{url,headers?}}}` | 等同 Telegram 凭据级敏感 |
| 完整 YAML（节点密码/UUID） | 沙箱文件 | `<files>/profiles/<id>.yaml`，权限 0600 | 内核可直接读；不进 Preferences |
| 上一版 YAML（回滚） | 沙箱文件 | `<files>/profiles/<id>.prev.yaml` | 更新失败回滚 |
| provider 文件 | 沙箱文件 | `<files>/profiles/providers/<id>/{proxies,rules}/<md5>` | 与内核路径一致 |
| geo 四件套 | 包内 rawfile + 首次复制到 `<files>/` 根 | `GeoIP.dat`、`GeoSite.dat`、`geoip.metadb`、`ASN.mmdb` | core `constant/path.go` 固定文件名 |
| profile 元数据 | Preferences | `harlgram_proxy_v1` → `profiles` JSON | 非敏感（label/count/hash/时间） |
| 设置 | Preferences | `harlgram_proxy_v1` → `settings` JSON | 非敏感 |
| 延迟结果 | 内存 | `DelayMap` | 非持久真值 |
| 日志 | 沙箱文件 | `<files>/logs/*.log` | 轮转、脱敏、不进备份 |
| 会话交接 | 沙箱文件 | `<files>/proxy/session/*.json` | 0600、用后删除 |
| 诊断导出 | `artifacts/`（忽略）或用户选择 | 去敏 JSON | 不自动上传 |

**明确禁止**：写入 `LocalStore` 的 `snapshot`（演示数据）、`harlgram_local_v1`、`harlgram_appearance_v1`；写入任何 Assets 之外的明文凭据。

### 8.4 Asset 细节

- 别名固定 `harlgram.proxy.v1`，与 `harlgram.telegram.v1`、`harlgram.accounts.v1` 分开。
- 单条 secret 保存的是**所有 profile 的 URL 索引** JSON；若超过 Asset 单条容量【待确认】，退化为「每条 profile 一个 alias `harlgram.proxy.v1.<profileId>`」；仍不足则只存 URL，正文永远在文件。
- 写操作串行化（单写队列，参考 `CredentialVault` 的 Promise 链）。
- 读取只在导入/更新/删除时发生；UI 不缓存完整 URL 到全局单例。
- 删除 profile 时删除对应 Asset 条目；失败则 UI 明确提示，不静默。

### 8.5 Preferences 细节

```text
key: "harlgram_proxy_v1"
value: {
  schemaVersion: 1,
  settings: { scope, enabledIntent, lastActiveProfileId, lastSelectedNodeName,
              testUrl, batchConcurrency, autoUpdate:false, experimentalScopeAck },
  profiles: [ { id, displayName, sourceKind, sourceRefKey?, configFileName,
                nodeCount, groupCount, contentHash, updatedAt, lastAttemptAt,
                lastErrorCode, isActive, selectedMap } ]
}
```

- `selectedMap` 属于 profile（组名→节点名），切换 profile 不串用。
- `isActive` 全局最多一个 true；写入时先清除其他。
- 不存 URL、密码、UUID、token、端口。
- 读取失败/损坏：回退到空设置并保留损坏副本 `harlgram_proxy_v1.corrupt`（不含敏感数据）。

### 8.6 凭据最小化

- 订阅正文只在 `ClashSubscriptionFetcher` 的局部变量中存在；写盘后立即丢弃引用；不放进 `@State`/`AppStorage`。
- 错误对象只保存错误码与脱敏摘要，不保存原始响应体。
- 日志调用只接受白名单字段；禁止直接打印 `SetupParams`/`RawConfig`。
- 截图/公开素材使用虚构配置；节点名、服务器地址脱敏；更新 `config/public-assets.json`。

### 8.7 备份排除

`entry/src/main/resources/base/profile/backup_config` 增加排除：

```text
profiles/           # 含节点凭据
proxy/              # 会话/诊断
logs/               # 代理日志
GeoIP.dat, GeoSite.dat, geoip.metadb, ASN.mmdb
```

TDLib 的 `telegram/` 仍按现有策略处理，不因本特性改变。代理目录不得包含可用于恢复用户消息的 Telegram 数据。

### 8.8 删除与清理

`removeProfile(id)` 的顺序：

1. 若该 profile 为 active 且代理在运行 → 先停止（或用户确认「将断开代理」）。
2. 删除 `profiles/<id>.yaml`、`<id>.prev.yaml`、`profiles/providers/<id>/`。
3. 删除 Asset 条目。
4. 删除 Preferences 中的 profile 与 `selectedMap`。
5. 清除 `DelayMap` 中该 profile 节点的全部结果。
6. 若删除后无 profile → 状态 `unconfigured`，节点区清空，开关禁用。
7. 任一步失败 → 可见提示 + 残留清单（不含路径），允许重试清理。

---

## 9. Action 映射（真实协议）

### 9.1 协议信封

```text
Action       { "id": string, "method": string, "data": any }
ActionResult { "id": string, "method": string, "data": any, "code": int }
```

- `code = 0` 成功，`code = -1` 错误。**必须检查 `code`**（上游 Dart 的 interface 忽略 code，不能照搬）。
- `id` 由客户端生成：`<method>#<epoch>-<seq>`；ActionResult 按 `id` 关联；超时后丢弃迟到响应。
- 事件把 `Message{type,data}` 包进 `ActionResult{method:"message"}` 推送：`{id:"",method:"message",data:{type,data},code:0}`。
- `setupConfig`/`updateConfig`/`validateConfig` 的「成功」是**空字符串**；失败是非空字符串（即使 `code` 可能为 0），两者都要检查。

### 9.2 初始化与运行时

| 场景 | method | `data` | 结果 | 失败语义 |
| --- | --- | --- | --- | --- |
| 内核初始化 | `initClash` | JSON 字符串 `{"home-dir":"<el2/base/files>","version":29}` | bool | false → `core_init_failed`；通常由 NAPI `initClashSync(29, homeDir)` 在异步线程执行 |
| 是否已初始化 | `getIsInit` | 无 | bool | false → 继续初始化或失败 |
| 设置状态 | `setState` | JSON 字符串 `CoreState`：`{"vpn-props":{...},"current-profile-name":"...","bypass-domain":[...]}`；`only-statistics-proxy` 为 Dart 额外字段，Go 忽略 | true | 非 true → `internal` |
| 版本 | `getCoreVersion` | 无 | `constant.Version` 字符串 | 空/异常 → 显示「未知」，不编造 |
| 运行时长 | `getRunTime` | 无 | epoch ms 字符串（NAPI 转 number） | `0` = 未启动；启动失败后可能短暂非零，**以 `startTun` 返回为准** |
| 当前配置名 | `getCurrentProfileName` | 无 | 字符串 | 空 → 空展示 |
| 内核状态 | `setUiActive` / `setScreenActive` | bool | true | 可选；锁屏时降低健康检查频率 |
| 关闭内核 | `shutdown` | 无 | bool | 失败也要继续释放 TUN/端口 |
| 内存/GC | `getMemory` / `forceGc` | 无 | 字节数字符串 / true | 仅诊断 |

### 9.3 配置应用

| 场景 | method | `data` | 结果 | 失败语义 |
| --- | --- | --- | --- | --- |
| 校验 YAML | `validateConfig` | **YAML 文本字符串** | 错误字符串（`''`=合法） | 非空 → `config_invalid`；不写文件 |
| 读取配置 | `getConfig` | **文件路径字符串**（扩展内由 profileId 拼接） | `RawConfig` JSON 对象；错误时 `code=-1` | 路径越界→`path_rejected`；解析失败→`config_invalid` |
| 应用配置 | `setupConfig` | **`SetupParams` JSON 字符串**：`{"config":<RawConfig>,"selected-map":{"组名":"节点名"},"test-url":"https://..."}` | 错误字符串（`''`=成功） | 非空 → `config_invalid`；解析失败时 core 会先 fallback `defaultSetupParams` 再返回错误，**必须按失败处理** |
| 热更新网络/模式 | `updateConfig` | JSON 字符串：`{"tun":{...},"allow-lan":false,"mixed-port":0,"find-process-mode":"off","mode":"rule|global|direct","log-level":"...","ipv6":true,"sniffing":true,"tcp-concurrent":true,"external-controller":"","unified-delay":true}` | 错误字符串（`''`=成功） | 仅用于 mode/网络字段；切换 profile 用 `setupConfig` |
| 快速启动 | `quickStart`（NAPI 回调式） | 三个 JSON 字符串：`InitParams`、`SetupParams`、`CoreState` | 错误字符串（`''`=成功） | 依次执行 `initClash → setState → setupConfig`；`init` 失败返回 `"init error"` |

**`RawConfig` 的规则键是 `"rule"`，不是 `"rules"`**。Dart 曾把 `rule` 改名 `rules` 做 UI 处理，再写回 `rule`；HmChat 不做改名，patch 后必须保证顶层键为 `rule`。

### 9.4 节点与组

| 场景 | method | `data` | 结果 | 失败语义 |
| --- | --- | --- | --- | --- |
| 读取全部代理 | `getProxies` | 无 | `map[string]proxyObject`（含 `name`、`type`、`now`、`all`、`history`、`alive`、`udp`、`hidden`、`testUrl`、`icon`、`serverDescription` 等） | 空/异常 → `internal`；UI 显示空态，不伪造节点 |
| 选择节点 | `changeProxy` | JSON 字符串 `{"group-name":"GROUP","proxy-name":"PROXY"}` | 错误字符串（`''`=成功） | 非空 → 回滚选中标记 + 用户可见原因；空 `proxy-name` 会 `ForceSet("")`，禁止发送 |
| 健康检查 | `healthCheck` | 组名字符串；空=全部组 | `''`（结果走 `delay` 事件） | 事件驱动；超时 30 s |
| 单节点测速 | `asyncTestDelay` | JSON 字符串 `{"proxy-name":"PROXY","test-url":"https://...","timeout":5000}` | `Delay` JSON 字符串 `{"name","url","value"}` | `value=-1` 失败；`0` 加载中；超时/拒绝/协议错误分类展示 |
| 外部提供者（可选） | `getExternalProviders` / `getExternalProvider` | 无 / provider 名 | JSON 数组/对象字符串 | MVP 不展示 provider 管理 |
| 关闭连接 | `closeConnections` / `closeConnection` | 无 / connection id | bool | 默认可选；节点切换不默认调用 |

**组派生算法（ArkTS，`ClashProxyCatalog.ts`）**：

```text
proxies = JSON.parse(getProxies.data)
isGroup(name) = proxies[name].type in {Selector, URLTest, Fallback, LoadBalance, Relay}
groupNames = ['GLOBAL'] + (proxies['GLOBAL']?.all ?? []).filter(isGroup)
for name of groupNames:
  g = proxies[name]
  nodes = g.all.map(n => proxies[n]).filter(exists)
  if g.hidden === true: skip unless 开发者显示隐藏组
  now = resolveToLeaf(g.now, depth<=16)
  isAuto = g.type != 'Selector'
```

- 嵌套组按 `all` 里的名字递归解析到叶子；深度上限 16，超过显示组名而非叶子。
- `Selector` 允许 `changeProxy`；自动组（URLTest/Fallback/LoadBalance/Relay）只读，不提供手动选择（REQ-049）。
- 同名节点通过 `groupName` 区分；列表键用 `group/name`。

### 9.5 流量、连接与日志

| 场景 | method | `data` | 结果 | 说明 |
| --- | --- | --- | --- | --- |
| 实时流量 | `getTraffic` | 无 | JSON 字符串 `{"up","down"}` | 或由 event 聚合；UI 1 Hz |
| 累计流量 | `getTotalTraffic` | 无 | 同上 | 诊断 |
| 重置流量 | `resetTraffic` | 无 | true | 诊断 |
| 连接列表 | `getConnections` | 无 | JSON 快照字符串 | MVP 不展示连接明细（隐私） |
| 日志开关 | `startLog` / `stopLog` | 无 | true | 默认只 warning/error；发布构建不自动开 |
| 内存 | `getMemory` | 无 | 十进制字节字符串 | 诊断 |

### 9.6 失败语义统一

| 层 | 成功 | 失败 | UI 处理 |
| --- | --- | --- | --- |
| NAPI 同步 | true / 非空字符串 | false / 空字符串（`initCore`） | 转 `core_load_failed`/`core_init_failed` |
| Action | `code=0` 且（字符串类）`data==''` | `code=-1` 或错误字符串非空 | 按 method 映射错误码 |
| RPC | `result` 存在 | `error{code,message}` | 按错误码显示；不显示原始 message |
| 事件 | `type` 白名单 | 未知 type 丢弃并计数 | 不展示原始 JSON |

**禁止**：把 `''`、`true`、`0`、`"ok"` 单独当作「已连接」；它们最多是某个环节的成功信号。

---

## 10. 订阅与配置流程

### 10.1 全流程

```text
导入订阅
  用户输入 URL → 本地校验（scheme/长度/字符）→ 生成 profileId
  → 启动扩展会话（不建 TUN、不请求 VPN 授权）→ core.init（如未初始化）
  → HTTP 拉取（限时/限体积）→ UTF-8 校验 → validateConfig(YAML)
  → 通过：写 <profiles>/<id>.yaml（原子替换）+ Asset 存 URL + Preferences 存元数据
  → 解析 getProxies 统计节点/组 → 更新 nodeCount/groupCount/contentHash
  → 状态 unconfigured → stopped（不自动启动）

导入本地 YAML
  系统文件选择器（DocumentViewPicker）→ 读取（≤8 MB）→ UTF-8/YAML 校验
  → validateConfig → 原子写文件 → Preferences 元数据（sourceKind=localYaml，无 Asset 条目）
  → 命名冲突：追加序号或用户确认替换

更新订阅
  读 Asset URL → HTTP 拉取 → validateConfig → 写临时文件 → 原子替换
  → 保留 <id>.prev.yaml（上一成功版本）→ 清空延迟结果 → 重新统计节点/组
  → 若为生效配置且代理运行：不自动重载（提示「更新后需应用」），或用户确认后 applyProfile

删除
  见 §8.8

应用配置（启动/切换 profile/范围变化）
  getConfig(<profileId>) → patch（§10.4）→ setupConfig(SetupParams)
  → 失败回滚旧 SetupParams；成功刷新 getProxies/组/选中项
```

**依赖顺序**：`core.init` 必须先于 `validateConfig`/`getConfig`/`setupConfig`。导入订阅会启动扩展进程与内核，但**不建立 TUN、不弹 VPN 授权**；UI 文案只显示「正在校验配置」，不显示「正在连接」。

**内核缺失**：`hello.coreLoaded=false` → 拒绝导入并提示「此安装包不包含代理内核，无法校验配置」；不写入半成品文件。

### 10.2 HTTP 拉取

| 项 | 设计 | 依据/说明 |
| --- | --- | --- |
| 客户端 | `@kit.NetworkKit` 的 `http` | 现有工程无 HTTP 客户端，需新增受控入口 |
| URL | 仅 `https://`/`http://`；`http` 给出明文传输提示 | 需求 027 |
| UA | `HmChat/<versionName> (HarmonyOS; ClashProxy)` | 不冒充 Clash Verge；若面板拒绝，开发者可配置 UA 覆盖【待确认】 |
| 设备头 | 默认**不发送** `x-hwid`/`x-device-os`/`x-ver-os`/`x-device-model` | 隐私；上游 OHOS 分支实际也基本为空 |
| 重定向 | 自动跟随 ≤5；仅允许 http/https；跨域重定向不携带任何认证头 | 上游先手动看 3xx 再跟随；设计简化为自动跟随并限制次数 |
| 连接超时 | 15 s | 与上游一致 |
| 读取超时 | 60 s | 与上游一致 |
| 体积上限 | 8 MB（8,388,608 字节）；超限中止并提示「订阅内容过大」 | 需求 037；上限可标定 |
| 响应码 | 仅 2xx 视为成功；3xx 未跟随/4xx/5xx → 失败 | 不把 HTML 登录页当配置 |
| 内容类型 | 不强制 `content-type`；以 `validateConfig` 为准 | 部分面板返回 `text/plain` |
| 编码 | UTF-8；允许 BOM（去除）；含 NUL/明显二进制 → 拒绝 | 需求 040 |
| 正文格式 | 仅 Clash YAML；**不支持 base64 订阅**，遇到时提示「暂不支持该订阅格式」 | 需求 029【待确认】 |
| 并发 | 同一 profile 同时最多一个拉取；全局最多 2 | 需求 027 防重复 |
| 缓存 | 不使用 HTTP 缓存；不持久化响应正文 | 隐私 |

**响应头白名单**（只读，不用于自动改 URL）：

| 头 | 用途 | 处理 |
| --- | --- | --- |
| `content-disposition` | 建议名称 | 提取 filename，清洗后作为 `displayName` |
| `subscription-userinfo` | 流量/到期展示 | 解析 `upload/download/total/expire`（expire 秒）→ 仅展示，不参与调度 |
| `profile-update-interval` | 建议更新周期 | 仅记录展示；本 MVP **不自动更新** |
| `flclashx-*` | 上游私有头 | 忽略（不改变 URL、不改变行为） |

**隐私**：错误提示只显示域名级摘要（如「订阅服务器返回 403」），不显示完整 URL、token、查询参数；日志不记录请求头与响应正文。

### 10.3 校验、原子写入与回滚

1. 大小/编码/结构初检（ArkTS，纯逻辑可测）。
2. `validateConfig(YAML 文本)` → 空错误串才继续；非空 → 映射 `config_invalid`，不写文件。
3. 写入 `<files>/profiles/.tmp-<id>.yaml`（0600）→ `fsync`（若可用）→ `rename` 为 `<id>.yaml`。
4. 若已有旧文件：先把旧文件 `rename` 为 `<id>.prev.yaml`，再 `rename` 新文件；失败则恢复旧文件。
5. `getConfig(<id>)` 读取新文件并统计 `getProxies` 的节点/组数；为 0 或解析失败 → 回滚到 `.prev` 并报错。
6. 成功后更新 Preferences：`contentHash`（SHA-256）、`nodeCount`、`groupCount`、`updatedAt`；清空该 profile 的延迟结果。
7. `contentHash` 与上次相同 → 标记「无变化」，仍可更新时间但不重载内核。

**名称与冲突**：优先 `content-disposition` 文件名 → `proxy-groups`/`GLOBAL` 名称 → 域名摘要；清洗控制字符、截断 64 字符；同名追加 ` (2)` 或要求确认替换；不静默覆盖。

### 10.4 `getConfig` → patch → `setupConfig`

**必须保留**：`getConfig` 返回的 `RawConfig` 是完整配置；patch 只改白名单字段，**不得删除** `proxies`、`proxy-groups`、`rule`（规则）、`proxy-providers`、`rule-providers`、`hosts`、`dns`、`sniffer` 等未知字段。实现上用「解析为开放对象 → 改白名单键 → 原样序列化」，而不是重新构造配置。

| 顶层键 | 设计值 | 理由 |
| --- | --- | --- |
| `mode` | `rule`（默认；可设置 `global`/`direct` 但不提供 UI） | 产品默认规则模式；MVP 不暴露模式切换 |
| `log-level` | 发布 `warning`；调试 `info` | 不默认输出详细请求 |
| `allow-lan` | `false` | 不暴露局域网 |
| `bind-address` | `127.0.0.1`（若存在） | 即使误开端口也仅回环 |
| `mixed-port` / `port` / `socks-port` / `redir-port` / `tproxy-port` | `0` | TUN 模式无需本地端口 |
| `external-controller` | `""` | 默认关闭 REST 控制面 |
| `external-ui` | `""` | 不使用 zashboard |
| `secret` | `""` | 关闭时无意义 |
| `ipv6` | 设置值（默认 `true`） | 与 VpnConfig IPv6 一致 |
| `find-process-mode` | `off` | `initClash` 的 version=29 已关闭 per-app UID 解析，保留 `always` 无收益 |
| `geodata-loader` | `memconservative` | 移动端内存 |
| `unified-delay` | `true` | 与上游默认一致 |
| `tcp-concurrent` | `true` | 与上游默认一致 |
| `keep-alive-interval` | `30` | 与上游默认一致 |
| `profile.store-selected` | `false` | 选择由 HmChat 的 `selectedMap` 管理，避免双写 |
| `tun.enable` | `true` | 与上游移动端一致；由扩展 fd 驱动，真机需确认未创建第二个 tun 设备【待确认】 |
| `tun.stack` | `gvisor` | core 会无条件覆盖为 gVisor；显式写避免误解 |
| `tun.mtu` | `1420` | 与 `core/tun` 夹紧值一致 |
| `tun.dns-hijack` | `["any:53"]`（若 profile 为空则 `172.19.0.2:53`） | 与 VpnConfig DNS 一致 |
| `tun.auto-route` | `false` | 路由由 VpnConfig 控制，避免双写系统路由【待确认】 |
| `tun.auto-detect-interface` | `false` | 同上 |
| `dns` | 保留 profile；缺失时注入最小配置 | 见下 |
| `rule` | 保留；若存在遗留 `rules` 键则移动到 `rule` | mihomo `RawConfig` 的规则键是 `rule` |

**最小 DNS 注入**（仅当 profile 没有 `dns` 或 `dns.enable !== true`）：

```text
enable: true
enhanced-mode: fake-ip
fake-ip-range: 198.18.0.1/16
nameserver: ["system"]        // 不内置第三方 DoH；真机确认无环路
fallback: []
```

【待确认】`system` 解析器在 TUN 下是否可用；若不可用，改为「保留系统 DNS 但经 TUN 劫持」的官方推荐配置，不引入第三方 DNS 提供商。

**`SetupParams`**：

```json
{
  "config": { /* patch 后的完整 RawConfig，规则键为 "rule" */ },
  "selected-map": { "GLOBAL": "节点名", "某组": "节点名" },
  "test-url": "https://www.gstatic.com/generate_204"
}
```

- `selected-map` 来自当前 profile 的 `selectedMap`；节点不存在时由 core 忽略（不报错），UI 需在应用后校验实际 `now`。
- `test-url` 默认 `https://www.gstatic.com/generate_204`；用户可改（非敏感），非法 URL 回退默认。

### 10.5 应用、切换与回滚

| 场景 | 行为 |
| --- | --- |
| 首次启动 | 先 `initClash`，再 `quickStart`；`quickStart` 内已含 `setState → setupConfig` |
| 已初始化后切换 profile | 直接 `setupConfig`；TUN 不重建；状态 `preparing(apply)` → `connected` |
| 应用失败 | 重放内存中的旧 `SetupParams`；成功 → `connected` + 提示「已恢复到原配置」；失败 → `failed(config_invalid)` |
| 范围变化（global ↔ harlgramOnly） | 必须重建 VpnConnection：`tun.stop` → `tun.start`（新 trustedApplications）；失败回滚旧 scope；期间状态 `preparing(scope)` |
| 节点切换 | `changeProxy`；成功写 `selectedMap`；失败回滚标记 |
| 配置更新（订阅） | 写文件后不自动 apply；UI 显示「有新版本，点击应用」；用户确认后走切换流程 |
| 启动中取消 | 发送 `tun.stop` + 取消 pending；资源释放完成后 `stopped` |

**回滚快照**：内存保存 `{rawConfigJson, selectedMap, testUrl, scope, profileId}`，只保留最近一次成功；不写盘（含凭据）。

### 10.6 geo 首次部署

**事实**：core 在 home 根查找固定文件名：`GeoIP.dat`、`GeoSite.dat`、`geoip.metadb`、`ASN.mmdb`；上游 `assets/data` 四件套约 42.8 MB（ASN 12.29 MB、GeoIP 19.13 MB、metadb 9.23 MB、GeoSite 4.20 MB）。缺失且 `geo-auto-update=false` 时，mihomo 可能尝试下载，失败则规则不可用。

**设计**：

1. 四件套放 `entry/src/main/resources/rawfile/clash/geo/`，随 HAP 分发（MVP 保证离线可用）。
2. 首次 `core.init` 前由扩展检查 `<files>/{GeoIP.dat,GeoSite.dat,geoip.metadb,ASN.mmdb}`；缺失则从 rawfile 分块复制，写 `<files>/proxy/geo.json` 记录版本/SHA-256/大小。
3. 复制在扩展进程异步执行，带进度事件「正在准备代理数据」；失败 → `failed(geo_missing)`，不得在无 geo 的情况下假装规则可用。
4. `geo-auto-update=false`；MVP 不提供 geo 更新 UI（非目标）；后续可由 `updateGeoData` 实现。
5. 发布前核对四件套来源、版本与许可；`GeoData.txt` 进入 `rawfile/clash/licenses/`。

### 10.7 无配置、空配置与损坏

| 情形 | 状态 | 行为 |
| --- | --- | --- |
| 无任何 profile | `unconfigured` | 开关禁用；导入入口；不启动内核/TUN |
| profile 存在但文件缺失/损坏 | `failed(config_invalid)` | 提示重新导入；不自动删除元数据，保留供用户导出诊断（脱敏） |
| 节点数为 0 | `failed(config_invalid)` 或 `unconfigured`（依配置存在性） | 开关禁用；说明「当前配置没有可用节点」 |
| 所有节点不可用 | `stopped` + 节点区置灰 | 允许查看原因；不允许启动 |
| 订阅更新失败 | 保持旧配置与状态 | 显示失败原因与最后成功时间；不无限重试 |
| 生效配置被外部删除 | 先停止 → 依存在性 `stopped`/`unconfigured` | 清理运行时引用 |

### 10.8 自动更新

**本 MVP 不做**：无定时任务、无后台网络请求。`autoUpdate` 字段固定 false；文档与 UI 不得宣称支持。订阅到期信息只做展示。

---

## 11. UI 设计

### 11.1 入口与导航

- 设置页「数据与存储」分组新增 `HdsSettingsRow`：标题「网络代理」，右侧摘要 `proxySummary()`，图标复用 `hg_globe_blue`（不新增位图则无需登记 `public-assets.json`）。
- 点击 `openProxy()`：`persistDraft()`；若在聊天则 `telegramService.leaveChat()`；`page = 'proxy'`。
- 代理页使用 `HdsPage`（`HdsNavigation` + `MINI` 标题 + 返回），不新增底部 Tab。
- 返回：页面返回与系统返回都走 `closeProxy()` → `page='home'; currentTab=2`；不落到会话列表，不重置导航栈/草稿/滚动锚点。
- 根背景：`windowBackground()` 增加 `page === 'proxy'` → `pageBackground()`；`HdsPage` 背景同色，底部安全区无色差。

### 11.2 页面信息架构

```text
HdsPage(title="网络代理", onBack=closeProxy, firstLabel="测速", firstAction=testAll)
└─ Scroll（BarState.Off，padding 16，bottom 24）
   └─ Column（maxWidth 720，居中；space 16）
      ├─ 状态卡（surface，圆角 16）
      │   状态点 + 主文案 + 副文案
      │   生效节点（connected 时） | 内核版本（不可得显示「未知」）
      │   错误摘要 + 「查看详情」 | 「重试」主按钮
      │
      ├─ 主开关行（HdsListItemCard + SuffixSwitch）
      │   标题「网络代理」；值：开/关；preparing/stopping 时禁用并显示进度
      │
      ├─ 分组「代理范围」
      │   └─ HdsListItemCard + SuffixSwitch：「仅 HmChat 走代理」
      │        副文案：关闭=「所有应用」；开启=「仅 HmChat（实验性）」+ 说明入口
      │
      ├─ 分组「配置与订阅」
      │   ├─ ProfileRow × N（HdsListItemCard）
      │   │   名称 | 来源（订阅/本地）| 节点数 | 更新时间 | 生效徽标 | 失败标记
      │   │   右侧菜单：应用 / 更新 / 删除
      │   ├─ 行「导入订阅」
      │   └─ 行「导入本地配置」
      │
      ├─ 分组「节点与测速」
      │   ├─ GroupHeader（组名 | 自动/手动 | 当前出口）
      │   ├─ NodeRow × N（虚拟列表）
      │   │   名称 | 协议 | 延迟徽标 | 选中标记 | 单点测速按钮
      │   │   自动组行只读，显示「自动」与当前叶子节点
      │   └─ 空态：「当前配置没有可用节点」
      │
      └─ 开发者入口（默认隐藏；仅「关于」页连点或调试构建可见）
          内核版本、状态迁移、错误码、protect 计数；导出脱敏诊断
```

### 11.3 HDS 组件映射

| 区域 | 组件 | 说明 |
| --- | --- | --- |
| 页面容器/标题/返回 | `HdsPage`（`HdsNavigation`，`MINI`） | 复用现有组件，不新建导航壳 |
| 设置值/跳转行 | `HdsListItemCard` + `SuffixTextAndArrow` | 与 `HdsSettingsRow` 一致 |
| 开关 | `HdsListItemCard` + `SuffixSwitch` | 新增 `ProxySwitchRow` 组件；不使用自绘胶囊 |
| 主操作 | `ButtonStyleMode.EMPHASIZED` | 「重试」「导入」 |
| 次操作 | `ButtonStyleMode.NORMAL` | 「取消」「应用配置」 |
| 文本操作 | `ButtonStyleMode.TEXTUAL` | 「查看详情」「删除」 |
| 菜单 | `Menu`/`promptAction.showActionMenu` | profile 行操作、删除确认 |
| 输入 | 官方 `TextInput` + `bindSheet`/对话框 | 订阅 URL 输入；不自定义文件浏览器 |
| 文件选择 | `DocumentViewPicker` | 系统文件选择器；不接受任意路径 |
| 进度 | `LoadingProgress` + 文案 | `preparing`/测速中 |
| 空态 | 简短文案 + 主操作 | 不写宣传语 |

### 11.4 交互规则

| 交互 | 规则 |
| --- | --- |
| 主开关 | 点击开启：先校验配置与内核；`preparing`/`stopping` 期间禁用；快速连点合并为最后一次意图；开关不先乐观置为「开」 |
| 开启前说明 | 首次全局模式：一次性说明「会影响设备上其他应用的网络」；切换为「仅 HmChat」时说明随之变化；`experimentalScopeAck` 记录 |
| 授权 | 先说明再由系统弹窗；拒绝后开关回弹，状态 `unauthorized`，可重试 |
| 配置行 | 点击=应用（如有需要）；右侧菜单=更新/删除；生效项有明确徽标；非生效项节点不参与当前列表 |
| 订阅输入 | 就地校验 URL；重复提交不产生并行请求；输入框不回显完整已保存 URL（只显示域名摘要） |
| 更新 | 显示更新中；成功后刷新节点与时间；失败保留旧配置并显示最后成功时间 |
| 删除 | 确认弹层说明作用范围；生效配置先停止或提示「将断开代理」 |
| 节点选择 | 点击后行内显示「正在切换」；成功才移动选中标记；失败回滚 + 原因 |
| 自动组 | 只读；显示当前实际出口；不提供组内手动选择 |
| 单点测速 | 行尾按钮；测速中显示 spinner；成功显示 `N ms`；超时显示「超时」；失败显示「失败」 |
| 批量测速 | 页面菜单「全部测速」；并发 4；可取消；已得结果保留，未完成回到未测 |
| 滚动/返回 | 返回立即响应，不等后台请求；不重置滚动位置 |
| 大列表 | `LazyForEach`/虚拟列表；≥500 节点首屏 ≤1 s；不在 `build()` 内做排序/派生 |

### 11.5 状态与错误文案

| 状态/错误 | 主文案 | 副文案/下一步 |
| --- | --- | --- |
| `unconfigured` | 尚未导入配置 | 导入订阅或本地配置后即可开启 |
| `unauthorized` | 未获得 VPN 授权 | 重新开启并允许系统授权 |
| `preparing` | 正在启动代理… | 首次开启可能需要几秒 |
| `preparing(apply)` | 正在应用配置 | 完成前不会显示已连接 |
| `preparing(scope)` | 正在应用网络范围 | 完成前不会显示已连接 |
| `connected` | 已连接 | 当前节点：`<名称>`（来自内核事实） |
| `stopped` | 已停止 | 开启后可继续使用 |
| `failed(config_invalid)` | 配置无法使用 | 重新导入或更新订阅 |
| `failed(core_missing)` | 此安装包不包含代理内核 | 更换完整安装包 |
| `failed(auth_denied)` | 未获得 VPN 授权 | 重试并允许系统授权 |
| `failed(protect_degraded)` | 网络保护异常，已停止代理 | 重试；仍失败请反馈诊断 |
| `failed(extension_crashed)` | 代理服务异常退出 | 手动重试 |
| `failed(timeout)` | 启动超时 | 重试或检查网络 |
| `stopped_with_warning` | 已停止，但存在未释放资源 | 重试清理或重启应用 |

**禁止**：文案出现 `preparing`、Action 名、SDK/ABI、二进制名、绝对路径、订阅 URL、节点密码、完整服务器地址。

### 11.6 响应式与外观

| 条件 | 布局 |
| --- | --- |
| `< 600 vp` | 单栏；行高 ≥48 vp；末项可滚动到浮动底栏之上；开关/测速按钮 ≥44 vp 命中区 |
| `600–839 vp` | 单栏，内容最大宽度 720 vp 居中；不拉满整屏 |
| `≥ 840 vp` | 同样单栏 + 最大宽度；本轮不做主从双栏（代理页无第二栏需求） |
| 跨断点 | 只改变布局；状态、配置、选中节点、滚动位置、测速结果不变 |
| 字体放大 | 行高自适应；长名称两行截断；开关与箭头不重叠 |
| 浅色/深色/跟随系统 | 复用 `surface/pageBackground/ink/mutedInk/line`；状态色对比度满足既有设置页标准 |
| 底部手势区 | 根背景与页面一致，无渐变遮罩 |

### 11.7 无障碍与文案

- 开关：`accessibilityText`「开启/关闭网络代理，当前 `<状态>`」。
- 测速：`accessibilityText`「测试 `<节点名>` 的延迟」。
- 删除：`accessibilityText`「删除 `<配置名>` 及其节点」。
- 错误详情：可聚焦、可朗读；不堆叠技术术语。
- 空态与加载态都有可朗读描述，不依赖颜色单独表达状态。

### 11.8 开发者入口

- 默认隐藏；仅在设置→关于的版本行连点 7 次或 debug 构建显示。
- 展示：内核版本、状态迁移（时间/状态/错误码）、protect 计数、RPC 会话时长。
- 导出：JSON 到用户选择位置；节点名哈希化、域名/IP/URL 移除、路径移除；不自动上传。
- 不展示原始 Action JSON、`RawConfig`、`SetupParams`。

---

## 12. TDLib 与媒体兼容

### 12.1 状态隔离

| 状态 | 归属 | 说明 |
| --- | --- | --- |
| `telegram.phase`/`telegram.ready` | TDLib | 不因代理启停改变 |
| 代理六态 | 代理 | 不复用 `phase` 枚举、不复用错误字段 |
| VPN 授权 | 系统 | `unauthorized` 只属于代理状态 |
| 媒体网络类型 | `MediaNetworkMonitor` | 只反映底层物理网络，不受代理开关影响 |

**规则**：代理 `failed` 时 TDLib 仍可直连；代理 `connected` 时 TDLib 仍可显示自身认证失败；两者互不代偿。

### 12.2 `MediaNetworkMonitor` 修正

**现状【事实】**：`getDefaultNet()` 得到默认网络；`BEARER_WIFI` 或 `NOT_METERED` → `wifi`；`BEARER_CELLULAR` **或 `BEARER_VPN`** → 读 `radio.getNetworkState().isRoaming`，未知按 `roaming`（保守关闭自动下载）。

**问题**：自有 VPN 生效后，默认网络可能是 `BEARER_VPN`，从而被判为蜂窝/漫游，触发 `configureMediaPolicy` 关闭自动下载，并向 TDLib 发送 `networkTypeMobile/MobileRoaming`。

**设计**：

1. `MediaNetworkMonitor` 增加「物理网络探测」：
   - 优先使用 `connection.getAllNets()`（若 API 26 提供【待确认】）过滤掉 `BEARER_VPN`，在剩余网络中按「WIFI 优先 → 非计量优先 → 蜂窝」选择。
   - 若只能拿到默认网络且为 `BEARER_VPN`：保留上一次非 VPN 判定（缓存 `lastPhysicalNetwork`，仅内存），并标记 `viaVpn=true`；**不得**因 `BEARER_VPN` 直接判 `roaming`。
   - `BEARER_VPN` 不参与 `isRoaming` 判定；漫游只由物理蜂窝网络决定。
2. 新增内部类型 `MediaNetwork = 'wifi'|'mobile'|'roaming'|'none'|'unknown'` 保持不变；不新增用户可见「代理网络」类型（避免 UI 语义混乱）。
3. 代理开关本身不触发 `refresh()`；只有系统网络变化触发。若底层 Wi-Fi 不变，代理开启前后判定必须一致。
4. 代理激活期间 `isRoaming` 读取失败 → 沿用 `lastPhysicalNetwork`；无历史值时保守用 `mobile`（不是 `roaming`），并记录 `networkUnknown`。

**验收**：底层 Wi-Fi + 代理开启，`MediaNetwork` 仍为 `wifi`；自动下载行为与关闭代理一致；底层蜂窝 + 代理开启，仍为 `mobile`/`roaming`（按真实蜂窝），不额外叠加漫游惩罚。

### 12.3 告知 TDLib 网络类型

- `TelegramClient.setMediaNetwork()` 继续使用 `MediaNetworkMonitor` 的结果；代理启停不得导致 `setNetworkType` 抖动。
- 若物理网络变化（Wi-Fi ↔ 蜂窝），按现有逻辑发送对应 `networkType*`；不发送「VPN」类型。
- 不在代理开启时主动调用 `setNetworkType(networkTypeOther)`。

### 12.4 VPN 生效时机与重连

**待确认**：VPN 建立后，已存在的 TDLib socket 是否立即走 TUN（Linux 路由按包生效，通常会；但 TDLib 可能因接口变化报错）。

**设计（保守）**：

1. 代理开启/关闭不主动重启 TDLib、不重新登录、不清空草稿。
2. 进入 `connected` 后若 30 s 内 TDLib 出现连续连接错误，UI 显示一次性提示「网络已切换，若消息收发异常可重试连接」；不自动 `close()` 客户端。
3. 若真机验证确认必须重连，S5 再实现「安全重连」：只重建 TDLib 连接，不清账号/草稿/会话；并在文档标注为已验证行为。
4. 账户切换不重启 VPN（`switchAccount` 只影响 TDLib）。

### 12.5 回环视频

**事实**：`VideoHttpStream.ets` 在 `127.0.0.1:0` 启动临时 HTTP 服务，路径为随机 UUID，供本机 AVPlayer 取流。

**设计**：

1. 回环流量原则上不经 TUN：系统本地路由优先于 TUN 默认路由；但必须在代理开启状态下实测播放与拖动。
2. 额外防护：在 patch 的规则前插入 `IP-CIDR,127.0.0.0/8,DIRECT,no-resolve`（若 profile 有规则），确保即使被 TUN 捕获也直连，不进入代理。
3. 代理自身出站由 protect 排除；回环服务不对外监听。
4. 验收：代理开启时播放已下载/本地流式视频，播放、暂停、拖动、倍速均正常；不要求关闭代理才能播放。
5. 若真机仍失败：改为 `::1` 绑定或改用应用内解码器【待确认】，不得把「关闭代理才能播放」当通过。

### 12.6 媒体自动下载策略

- 代理启停不修改存储/下载设置中的任何开关值。
- 底层 Wi-Fi 且代理开启 → 自动下载仍生效（依赖 §12.2 修正）。
- 「代理开启后图片不再自动下载」视为回归缺陷，阻断 MVP。

### 12.7 回归矩阵

| 场景 | 代理关闭 | 代理开启 | 切换节点 |
| --- | --- | --- | --- |
| 文本收发 | 必测 | 必测 | 必测 |
| 图片/视频加载 | 必测 | 必测 | 必测 |
| 附件上传/下载 | 必测 | 必测 | 必测 |
| 草稿保存/恢复 | 必测 | 必测 | 必测 |
| 会话搜索 | 必测 | 必测 | 必测 |
| 账户切换 | 必测 | 必测（VPN 不重启） | 必测 |
| 回环视频 | 基线 | 必测 | — |
| 自动下载策略 | 基线 | 必测（Wi-Fi 不变） | — |

---

## 13. 构建、许可证与发布

### 13.1 内核构建（`scripts/build-clash-core.sh`）

| 项 | 设计 |
| --- | --- |
| 输入 | `CLASH_CORE_SRC`（固定提交的源码工作树，含 `core/`、`third_party/sing-tun`、`go.mod/go.sum`） |
| 工具链 | 固定 Go 版本（基线二进制为 1.24.5，实施时固定到具体补丁版本）；`GOTOOLCHAIN=local`；`OHOS_GO`、`OHOS_NDK` 显式传入并校验 |
| 环境 | `GOOS=openharmony`、`GOARCH=arm64`、`CGO_ENABLED=1`、`CC=<clang --target=aarch64-linux-ohos --sysroot=... -D__MUSL__>`、`GOPROXY` 固定 |
| 标签 | `-tags with_gvisor`（必须；否则无 gVisor） |
| 构建模式 | `-buildmode=c-shared` |
| 路径 | `-trimpath` |
| VCS | `-buildvcs=false`（避免 `vcs.modified=true` 污染指纹） |
| 版本 | `-X github.com/metacubex/mihomo/constant.Version=<固定版本>`（如 `v1.19.28`）；修正上游未注入导致 `getCoreVersion` 返回默认 `1.10.0` 的问题 |
| 链接 | `-ldflags="-s -w -extldflags=-Wl,-soname,libclash_core.so"` |
| 输出 | `entry/libs/arm64-v8a/libclash_core.so` |
| 校验 | 构建后 `llvm-readelf` 检查 SONAME/`DT_NEEDED`；`sha256sum`；`go version -m` 保存到 `artifacts/clash-core/` |
| 记录 | `artifacts/clash-core/manifest.json`：版本、提交、Go 版本、SDK/NDK 版本、构建参数、大小、SHA-256；**不含本机绝对路径** |
| 失败 | 任一步失败即退出非零，不覆盖已有产物；不生成「半成品」HAP |

**必须保留的本地补丁**：`third_party/sing-tun` 的 5 个文件（`debug_hilog.go`、`debug_hilog_ohos.go`、`debug_hilog_stub.go`、`tun_linux.go` 的 `pumpStop`、`tun_linux_gvisor.go` 的 channel endpoint/`rawRead`/`rawWrite`/`Poll`）以及 `go.mod` 的 `replace`。移除补丁会导致 TUN fd `fstat` EACCES 下无法建端点。

### 13.2 桥构建与打包

- `entry/src/main/cpp/CMakeLists.txt` 双 target（§6.1）。
- `entry/oh-package.json5` 增加 `libclash_bridge.so` 本地包。
- `entry/build-profile.json5` 的 `abiFilters` 保持 `["arm64-v8a"]`。
- 打包后必须存在：`libs/arm64-v8a/libentry.so`、`libtdjson.so`、`libc++_shared.so`、`libclash_bridge.so`、`libclash_core.so`。
- `libclash_bridge.so` 的 `DT_NEEDED` 必须包含 `libclash_core.so`；两个库 SONAME 可解析；无 RUNPATH 指向构建机。

### 13.3 `verify-hap.py` 同步

**现状【事实】**：

```text
LIBRARIES = ('libentry.so', 'libtdjson.so', 'libc++_shared.so')
LICENSES  = ('TDLib.txt','OpenSSL.txt','SQLCipher.txt','LLVM.txt','Libphonenumber.txt','Unicode-CLDR.txt','Harlgram-GPL-3.0.txt','Harlgram-Notices.txt')
```

**设计**：

```text
LIBRARIES = ('libentry.so','libtdjson.so','libc++_shared.so','libclash_bridge.so','libclash_core.so')
LICENSES  = 现有 8 项 + ('mihomo.txt','Go.txt','sing-tun.txt','FlClashX.txt','GeoData.txt')
```

新增检查：

1. `libclash_bridge.so` SONAME 恰为 `libclash_bridge.so`。
2. `libclash_core.so` SONAME 恰为 `libclash_core.so`。
3. `libclash_bridge.so` 的动态段 `NEEDED` 包含 `libclash_core.so`。
4. 任一库出现 `RUNPATH`/`RPATH` 且含绝对路径 → 失败。
5. 内核库大小 ≤512 MB（现有限制）；记录 SHA-256 到输出（不改变现有只读行为）。
6. 许可文件缺失/空 → 失败。

### 13.4 `tests/ci-package.test.mjs` 同步

- `libraries` 追加两个库；`licenses` 追加五项。
- 新增负例：缺少 `libclash_core.so` 必须失败；`libclash_bridge.so` 缺少 `NEEDED libclash_core.so` 必须失败；带 RUNPATH 必须失败。
- 所有夹具使用**合成 ELF 头与虚构许可文本**，不放入任何真实二进制或凭据。

### 13.5 strip 策略

**现状【事实】**：`entry/build-profile.json5` 的 release `nativeLib.debugSymbol.strip: true` 会作用于所有 `.so`；Go c-shared 已用 `-s -w` 构建。

**设计**：

1. 首选：release 保持 `strip: true`，S1 在真机验证内核仍可加载、`getCoreVersion` 可读、无崩溃；若 `llvm-strip` 破坏 Go 的 pclntab/异常信息导致启动失败，则改为按库排除或 release `strip: false`。
2. 桥库可安全 strip；内核库若排除 strip，体积增加有限（已 `-s -w`）。
3. 任何 strip 策略变更必须记录到 `docs/LICENSING.md` 与构建指纹；不得以「体积更小」为由牺牲可启动性。

### 13.6 GPL、SBOM 与通知

| 交付物 | 内容 |
| --- | --- |
| `THIRD_PARTY_NOTICES.md` | 新增 FlClashX（固定提交/来源/修改说明）、mihomo（固定版本/提交）、sing-tun（v0.4.21 + 5 文件 diff）、Go runtime（BSD-3-Clause）、125 个 Go 依赖、geo 数据 |
| `docs/LICENSING.md` | 「实际构建的来源记录」新增固定提交、Go/SDK/NDK 版本、构建参数、产物 SHA-256、对应源码包位置 |
| `entry/src/main/resources/rawfile/clash/licenses/` | `mihomo.txt`、`Go.txt`、`sing-tun.txt`、`FlClashX.txt`、`GeoData.txt`，以及逐依赖许可（可按 SBOM 索引） |
| `scripts/package-clash-source.sh` | 生成源码包：`core/`（含 untracked 文件）、`third_party/sing-tun`、`go.mod/go.sum`、`build_ohos.sh`、`build-clash-core.sh`、mihomo 对应版本源码、125 依赖源码/许可、SBOM、diff 说明、工具链版本 |
| SBOM | `go version -m` 输出 + 依赖清单（名称/版本/许可/来源）；存 `artifacts/`，发布时附在源码包 |
| 发布阻断 | 源码包无法重建同 ABI 产物 → 禁止分发含内核 HAP；仅本机调试需明确标注「不可分发」 |

**明确**：GPL-3.0 与 HmChat 的 GPL-3.0-or-later 兼容，但「兼容」不等于「合规」；必须提供完整对应源码、修改说明、安装/重建信息，不得只给上游链接。

### 13.7 签名、bundleName 与商店

- 不修改 `signingConfigs`，不复制上游证书/签名材料，不输出任何签名内容。
- `bundleName` 保持 `xyz.3333189.harlgram`；如用户后续调整，`trustedApplications` 必须同步改为实际 bundleName（代码中从 `bundleManager` 读取，不硬编码）。
- 【待确认】AppGallery 对第三方 VPN 的资质、隐私与审核要求；未确认前不宣称可上架。
- 隐私说明需覆盖：代理配置本地处理、是否上传、日志保留、订阅 URL 存储方式、诊断导出内容。

### 13.8 体积与 ABI

- 预估：内核 51.2 MB + geo 42.8 MB + 桥 ~0.2 MB + TDLib/OpenSSL 等现有库 → HAP 显著增大（≥100 MB 量级）。
- 记录 HAP 大小、安装耗时、首启耗时，与基线对比；不得宣称「体积无影响」。
- 仅 `arm64-v8a`；x86_64 模拟器明确「不支持」，不提供 fallback；后续扩 ABI 必须重建内核与桥。
- `MAX_LIBRARY_BYTES` 512 MB 仍满足；但需评估商店/用户下载体验。

### 13.9 可复现与指纹

- 固定：Go 补丁版本、SDK/NDK 版本、`GOPROXY`、构建脚本、`go.sum`、`third_party` 哈希。
- 记录：`libclash_core.so` 与 `libclash_bridge.so` 的 SHA-256、大小、`go version -m`、`llvm-readelf -d` 输出。
- 重建比对：同输入应得到同 SONAME/NEEDED 与可启动产物；字节一致性不作强制承诺，但必须记录差异原因。

---

## 14. 分阶段实施（S1–S5）

### S1 内核加载与 RPC（不接 UI）

| 项 | 内容 |
| --- | --- |
| 目标 | 能从固定源码重建内核；桥 target 编译通过；扩展能被拉起；RPC 鉴权与 `hello`/`core.init`/`getCoreVersion` 可用 |
| 改动 | `scripts/build-clash-core.sh`、`cpp/clash/*`、CMake 双 target、`vpn/ClashVpnExtensionAbility.ets` 骨架、`ClashRpcServer/Client`、`ClashSessionFiles`、`ClashCoreBridge`、`module.json5` 扩展声明 |
| 验收 | SDK 26 `assembleHap` 退出码 0；HAP 含双库且 SONAME/NEEDED 正确；真机安装后 `startVpnExtensionAbility` 成功；错误 token 连接被拒；`hello.coreLoaded=true`；`getCoreVersion` 等于固定版本；**不建 TUN、不弹授权** |
| 风险 | GPL 源码不齐（不得分发）；hvigor 是否打包未被 NAPI 引用的 DT_NEEDED 库；`OHOS_ARCH` 变量名 |
| 回滚 | 移除扩展声明与桥 target、恢复 `oh-package.json5`、门禁白名单回退；不影响 TDLib |

### S2 VPN、TUN 与 protect

| 项 | 内容 |
| --- | --- |
| 目标 | 授权、TUN 建立、protect 可靠、通知、KeepAlive、停止收敛、错误码 |
| 改动 | `ClashVpnSession`、`getAndroidVpnOptions` 调用、VpnConfig 构造、protect 分支、`ClashKeepAlive`、通知、`backup_config` |
| 验收 | 首次开启弹系统授权；拒绝 → `unauthorized`；允许 → `ifconfig vpn-tun` UP、`getRunTime>0`；protect 压测 10 分钟失败 0；停止后端口关闭/通知消失；后台/锁屏 ≥10 分钟可用或如实记录被回收；扩展崩溃不影响 UI |
| 风险 | `trustedApplications`/`blockedApplications` 互斥与黑洞语义；`tun.enable` 双 TUN；`terminateSelf` 不存在；KeepAlive 策略变化 |
| 回滚 | 关闭扩展声明与代理入口，保留内核构建脚本；VPN 不启用时行为与基线一致 |

### S3 数据、订阅与 Action 闭环

| 项 | 内容 |
| --- | --- |
| 目标 | Asset/Preferences/沙箱存储、订阅拉取/校验/原子写、`getConfig→patch→setupConfig`、组派生、选节点、测速、回滚 |
| 改动 | `ClashProfileStore`、`ClashSubscriptionFetcher`、`ClashConfigBuilder`、`ClashProxyCatalog`、`ClashEventDecoder`、`ClashDiagnostics`、纯 `.ts` 模型与测试 |
| 验收 | 用户授权的真实订阅导入成功且节点/组数与实际一致；`validateConfig` 拒绝错误内容且不写文件；切换 profile 后内核实际出口与 UI 标记一致（连续 3 次）；单点/批量测速有结果，超时显示「超时」；更新失败旧配置仍可启动；`scripts/test-domain.sh` 全绿 |
| 风险 | `rule` 键写错；`setupConfig` fallback 伪成功；大配置超时；Asset 容量；base64 订阅不支持 |
| 回滚 | 保留内核与 VPN，隐藏导入/应用入口；已导入文件可手动清理（不触碰 TDLib 数据） |

### S4 UI 与交互

| 项 | 内容 |
| --- | --- |
| 目标 | 设置入口、代理页三段、状态机 UI、范围切换、响应式、返回语义、无障碍 |
| 改动 | `ProxyPage.ets`、`ProxyRows.ets`、`Index.ets`（入口/返回/根背景/分支）、`ClashService` 门面 |
| 验收 | 设置→代理→返回设置页路径 100%；六态文案与视觉一致；`preparing` 不显示成功色；599/600、839/840 vp 边界不重置状态；浅/深色无裁切；长名称/大字号不重叠；空态可操作；删除/更新确认 |
| 风险 | `goBack()` 硬编码回 `home`；根背景色差；底栏遮挡；页面重建导致会话重建 |
| 回滚 | 移除入口行与分支，页面文件保留但不挂载 |

### S5 兼容、验收与发布

| 项 | 内容 |
| --- | --- |
| 目标 | TDLib/媒体兼容、回环视频、回归、门禁、GPL、体积、商店材料 |
| 改动 | `MediaNetworkMonitor` 物理网络探测、配置规则插入回环直连、`verify-hap.py`/`ci-package`/`transpile`、`THIRD_PARTY_NOTICES`/`LICENSING`/README |
| 验收 | 三态（关/开/切节点）下文本/图片/附件/草稿/搜索全通过；Wi-Fi 下自动下载不变；代理开启时回环视频可播放拖动；`verify-hap.py` 与 `test-domain.sh` 通过；源码包可重建同 ABI；无凭据进入公开树 |
| 风险 | 媒体策略回归；回环被 TUN 捕获；GPL/商店；HAP 体积 |
| 回滚 | 关闭入口与扩展声明；保留文档与脚本；不得发布含内核 HAP 直至合规通过 |

**阶段纪律**：每个阶段分别记录源码/编译/设备/服务端证据；S1–S4 产物默认「本机调试，不可分发」；S5 通过门槛 3 后才可宣称可分发。

---

## 15. 风险登记

| 等级 | 风险 | 触发条件 | 缓解 | 验证方法 |
| --- | --- | --- | --- | --- |
| 高 | RPC 端口被抢占/冒充 | 固定端口或先连后启 | `bind(0)`、会话文件交接、首帧鉴权、ack 校验 `pid/bootId` | 外部进程连接随机端口无法鉴权；连续两次端口不同；47471 无监听 |
| 高 | protect 失败导致流量环路 | TSFN 满、JS 线程阻塞、`conn` 为空 | 独立 TSFN/容量 64/3 s 重试/计数/降级停 TUN | 50 并发压测 10 分钟；`reject loopback` 计数 0 |
| 高 | 凭据泄漏（URL/密码/UUID） | 写入 Preferences、日志、截图、诊断 | Asset + 沙箱 0600 + 白名单日志 + 统一脱敏 | 全沙箱与 artifacts 检索命中 0 |
| 高 | 伪造 Ready | `init` 返回 `"ok"`、只看到程/端口 | 三重证据 + 结构化 `hello` + 状态机 | 临时移走内核库，UI 必须 `failed(core_missing)` |
| 阻断 | GPL 源码不齐 | 直接分发预编译 `.so` | 自建 + 源码包/SBOM + 发布阻断 | 按脚本重建同 ABI；清单逐项核对 |
| 中 | 内核未加载/符号缺失 | `.so` 缺失、ABI 不符、strip 破坏 | 构建指纹、SONAME/NEEDED 门禁、启动自检 | HAP 内容检查 + 真机启动 |
| 中 | MediaNetwork 误判漫游 | 默认网络为 `BEARER_VPN` | 物理网络过滤 + 缓存 + 不把 VPN 当漫游 | Wi-Fi 下代理前后自动下载一致 |
| 中 | 「仅 HmChat」黑洞 | `blockedApplications` 语义或系统限制 | 只用 `trustedApplications` 白名单；实验性标注；失败回滚 global | 真机对照：本应用可用、其他应用不被断网 |
| 中 | 回环视频被 TUN 捕获 | 默认路由覆盖 127/8 | 规则前置 `127.0.0.0/8,DIRECT`；真机验证 | 代理开启时播放/拖动正常 |
| 中 | `rule` 键错误导致规则丢失 | patch 写成 `rules` | patch 后断言 `rule` 存在；单元测试 | 应用后 `getConfig` 复核规则数 |
| 中 | 大配置/大订阅超时 | >8 MB、节点 >500 | 体积上限、超时、`LazyForEach`、并发限制 | 500 节点滚动 ≤1 s；导入 8 MB 不卡死 |
| 中 | 保活被系统回收 | DATA_TRANSFER 无进度/流量 | 60 s 实况窗 + 真实流量；状态如实更新 | 锁屏 ≥10 分钟记录 |
| 中 | HAP 体积过大 | 内核 + geo + TDLib | 记录体积、评估分发策略、不宣称无影响 | 安装/首启耗时对比基线 |
| 中 | 扩展进程被回收后状态错乱 | 无 terminateSelf、系统回收 | 会话可重建；重启只到 `stopped`/`unconfigured` | 杀进程后重进页面状态正确 |
| 低 | fd 复用导致 protect ack 错配 | 高频建连/关闭 | fd + epoch + 代次键；未知 fd 计数 | 压测 + 计数 |
| 低 | 通知发布失败 | 用户关闭通知权限 | 只告警、不影响代理；诊断可见 | 关闭通知权限后代理仍可用 |
| 低 | 订阅面板要求 HWID | 服务端校验 | 默认不发；文档说明；必要时用户显式开启 | 真实订阅（用户授权）验证 |

---

## 16. 开放问题（仅保留仍需外部确认的项）

| # | 问题 | 影响 | 关闭方式 | 当前设计兜底 |
| --- | --- | --- | --- | --- |
| Q1 | 固定 TDLib 1.8.69 schema 是否提供代理相关请求（`addProxy`/`editProxy`/`getProxies` 等）及字段 | 「仅 Telegram」退路、REQ-082/112 | 读取固定 schema | 不实现「仅 Telegram」；只做 VPN |
| Q2 | VPN 建立后对已存在 TDLib socket 的生效时机；是否需主动重连 | REQ-112 | 真机抓包 + 收发测试 | 不主动重连；仅提示 |
| Q3 | `trustedApplications`/`blockedApplications` 在目标设备的真实语义（blocked 是否黑洞） | REQ-078/082 | 真机对照测试 | 只用 trusted 白名单；实验性标注 |
| Q4 | Asset 单条 secret 容量上限 | REQ-083 | 官方文档 + 实机写读 | 只存 URL 索引；必要时按 profile 分 alias |
| Q5 | API 26 是否提供 `VpnExtensionContext.terminateSelf()` | REQ-108 | 查 SDK d.ts + 真机 | 空闲 60 s 后 shutdown，等系统回收 |
| Q6 | API 26 是否允许 `extensionAbilities.backgroundModes` | REQ-020 | 查 modulecheck schema | 保活固定放 UIAbility |
| Q7 | CMake 向工程暴露的 ABI 变量名与 `libs` 相对层级 | 构建 | 读构建日志 | 先用 `${OHOS_ARCH}`，失败则用绝对相对路径兜底 |
| Q8 | hvigor 是否打包未被 NAPI 直接引用的 DT_NEEDED 库 | REQ-118 | 实际构建后查 HAP | 若不打，改为 `entry/libs` + 显式 copy 步骤/构建后校验 |
| Q9 | `llvm-strip` 对 Go c-shared 的影响 | REQ-118/124 | 构建 + 启动验证 | 失败则 release 关闭 strip 或按库排除 |
| Q10 | `tun.enable=true` 是否创建第二个 tun 设备 | REQ-017 | 真机 `ifconfig`/日志 | 若冲突改 `tun.enable=false`，仅用 `startTun` |
| Q11 | `system` DNS 在 TUN 下是否可用 | REQ-017/110 | 真机解析测试 | 失败则使用 profile DNS 或系统推荐配置，不内置第三方 DoH |
| Q12 | 订阅 base64 格式与 HWID 面板要求 | REQ-029/036 | 用户授权真实订阅测试 | 明确提示「暂不支持」；默认不发 HWID |
| Q13 | `runtime.GOOS` 在 OHOS Go 工具链的实际值 | `common.go` 的 Android 分支 | 构建/设备日志 | 已强制 gVisor；`mixed-port=0` 降低影响 |
| Q14 | protect 队列/超时的最优值（64/3 s） | REQ-105/106 | 压测标定 | 采用保守默认；超限可调常量 |
| Q15 | 回环 `127.0.0.0/8` 与 AVPlayer 在代理下的真实行为 | REQ-107/115 | 真机播放测试 | 规则前置直连 + 关闭代理对照 |
| Q16 | AppGallery 对第三方 VPN 的资质/隐私要求 | REQ-126 | 官方政策 + 发布流程 | 未确认前不宣称可上架 |
| Q17 | geo 四件套来源/版本/许可 | REQ-119 | 上游 meta-rules-dat 核对 | 随包分发 + `GeoData.txt` + SHA-256 记录 |
| Q18 | 停止后重新开启是否需要再次授权 | REQ-014/018 | 真机 3 次启停 | 允许重新弹窗；不假设免授权 |

---

## 17. 需求追溯矩阵

| 需求组 | 设计落点 | 主要组件 |
| --- | --- | --- |
| REQ-001–005 入口/页面/空态 | §4.3、§11.1–11.2、§11.4 | `Index.ets`、`ProxyPage.ets`、`ProxyRows.ets` |
| REQ-006–012 状态卡/防抖/响应式/重建 | §3.3、§11.2、§11.5–11.7、§5.5 | `ClashStateMachine.ts`、`ClashService.ts`、`ClashKeepAlive.ets` |
| REQ-013–026 启停/授权/停止/后台/崩溃 | §3.2、§5.5–5.6、§7.1–7.9 | `ClashVpnSession.ets`、`ClashRpcServer/Client`、`ClashKeepAlive.ets` |
| REQ-027–038 订阅导入/更新/删除 | §10.1–10.3、§8.3–8.5 | `ClashSubscriptionFetcher.ets`、`ClashProfileStore.ets` |
| REQ-039–045 本地 YAML | §10.1、§10.3、§6.6 | `ClashProfileStore.ets`、`ClashConfigBuilder.ets` |
| REQ-046–056 节点/组/选择/刷新 | §9.4、§11.2、§11.4 | `ClashProxyCatalog.ts`、`ProxyPage.ets` |
| REQ-057–064 测速 | §3.2、§9.4、§11.4 | `ClashService.ets`、`ClashEventDecoder.ets` |
| REQ-065–076 状态机/错误/重试/诊断 | §3.3、§7.9、§8.2、§11.5、§11.8 | `ClashStateMachine.ts`、`ClashDiagnostics.ets` |
| REQ-077–082 代理范围 | §7.3、§10.5、§11.4 | `ClashVpnSession.ets`、`ProxyPage.ets` |
| REQ-083–093 持久化/安全/界面不回显 | §8.3–8.6、§11.4、§11.8 | `ClashProfileStore.ets`、`ClashRedaction.ts` |
| REQ-094–099 日志/隐私/事件最小化 | §5.7、§6.8、§8.6 | `ClashEventDecoder.ets`、`ClashDiagnostics.ets` |
| REQ-100–109 进程隔离/RPC/protect/崩溃 | §3.1、§5、§6、§7 | `clash_bridge.cpp`、`ClashRpcServer/Client`、`ClashCoreBridge.ets` |
| REQ-110–116 TDLib/媒体/回环视频 | §12.1–12.7 | `MediaNetworkMonitor.ets`、`TelegramClient.ts`、`ClashConfigPatch.ts` |
| REQ-117–126 构建/许可/发布 | §13.1–13.9 | `build-clash-core.sh`、`verify-hap.py`、`THIRD_PARTY_NOTICES.md` |
| REQ-127–132 回归/纪律 | §13、§14、§17 | `tests/clash/*.test.mjs`、`transpile.mjs`、`docs/STATUS.md` |

**设计覆盖声明**：132 条需求均可落到上述章节与组件；其中标注【待确认】的条目只能标记为「设计完成、未验证」，不得计入通过。

---

## 18. 变更记录

| 版本 | 日期 | 变更 |
| --- | --- | --- |
| v1 | 2026-11-05 | 初版：基于 132 条 EARS 规格、三份基线与 OHOS 交付记录，给出双进程架构、RPC 鉴权/端口轮换、protect 可靠性、VPN 扩展、数据模型、Action 映射、订阅流程、HDS 页面、TDLib 兼容、构建/许可与 S1–S5 分期 |

---

## 附录 A：设计决策速查

| 决策 | 结论 | 依据 |
| --- | --- | --- |
| 单模块还是新模块 | 单 `entry` 内新增目录 | 根 `build-profile.json5` 不在仓库，新增模块摩擦大 |
| 内核放哪 | 只在 VPN 扩展进程 | 崩溃/TLS/内存隔离；主进程不加载 |
| RPC 端口 | `bind(0)` 随机 | 固定 47471 可被抢占/冒充 |
| token 交接 | 沙箱一次性文件（0600） | 不进 Want 参数/日志；可用后删除 |
| 配置解析 | 保留 `getConfig` 往返 | 不在 ArkTS 重写完整 mihomo YAML |
| 配置写入 | 原子替换 + `.prev` | 失败可回滚 |
| 订阅 URL | Asset | 等同凭据 |
| YAML/节点凭据 | 沙箱文件 | 内核需要；不进 Preferences |
| 延迟结果 | 仅内存 | 非持久真值 |
| 代理范围 | 默认全局；仅 HmChat 实验性 | `trustedApplications` 白名单；blocked 语义风险 |
| 保活 | UI 进程 `dataTransfer` | 扩展调用 401 |
| 控制面 | 关闭 `external-controller` | 上游默认无鉴权回环端口 |
| strip | 先验证，失败则排除内核 | `llvm-strip` 对 Go 产物影响未知 |
| ABI | 仅 `arm64-v8a` | 本轮产物与 SDK 基线一致 |

## 附录 B：禁止事项清单（实施时逐项检查）

1. 不把订阅 URL、节点密码、UUID、私钥写入 Preferences、日志、通知、截图、公开 artifacts。
2. 不在 UI 进程 `import libclash_bridge.so` 或链接 `libclash_core.so`。
3. 不使用固定端口 47471、无鉴权连接、明文公共文件交接 token。
4. 不使用 `init` 的 `"ok"`、`setupConfig` 的空串以外的单点信号判定「已连接」。
5. 不在扩展进程 import `contacts`/`geo`/`audio`/`camera`/`call`/`sim`/`sms`/`TelephonyKit`。
6. 不使用 `blockedApplications` 实现「仅 HmChat」；不与 `trustedApplications` 同时下发。
7. 不在 `RawConfig` 中使用 `rules` 作为规则键；不删除 profile 未知字段。
8. 不在 release 构建开启 debug 日志；不输出完整 Action JSON/SetupParams。
9. 不修改 `signingConfigs`/`bundleName`；不复制上游签名材料。
10. 不在 GPL 对应源码未补齐时分发含内核 HAP。
11. 不在持有真实会话的设备上做同 bundle 的 ohosTest 安装/卸载循环。
12. 不在代理开启时修改媒体自动下载设置或把自有 VPN 判为漫游。
13. 不把「模拟器通过」写成「真机通过」；不把「编译通过」写成「服务端验证通过」。

