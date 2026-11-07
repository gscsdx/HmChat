# FlClashX core/ 与 lib/ 勘察基线（关闭上一份文档的关键待确认项）

- 勘察对象：`source-refs/FlClashX/`（完整仓库，含 `core/`、`lib/`、`pubspec.yaml`、`LICENSE`、`OHOS-DELIVERY.md`）
- 对照对象：`source-refs/FlClashX-ohos/`（上一轮的 `ohos/` 子工程快照）
- 勘察日期：2026-11-05
- 方式：只读源码、配置、许可证与二进制元数据；未构建、未安装、未运行设备命令、未修改签名
- 范围：关闭上一份 `docs/integration/flclash-baseline.md` 的 §8.4、§8.5、§10.2、§11.4；重点回答 Action 词表/参数、`quickStart`/`setupConfig` schema、`AndroidVpnOptions`、订阅/节点/测速、存储、geo、许可证/构建、与 `ohos/` 快照差异
- 分级：全文继续使用【事实】【推断】【待确认】

> 本仓库 HEAD 为 `85b903ad13ea3fcb67142dae521e2479ff8cdbe0`（2026-11-01），但工作树有 167 个改动文件，且 `core/build_ohos.sh`、`core/dns_*.go`、`core/third_party/` 为 **untracked**。因此「源码存在」不等于「HEAD 可重建」；下文会分别标注。

---

## 0. 结论先行

1. 【事实】`core/` 不是 `lib_android.go` + `android_bride.go` 的旧结构，而是 **`lib_mobile.go`（由 `lib_android.go` 重命名）+ `android_bride.go` + `action.go` + `hub.go` + `common.go` + `lib.go` + `lib_other.go` + `state/` + `platform/` + `tun/` + `third_party/sing-tun`**。`dns_android.go` 与 `dns_openharmony.go` 是新增的按平台 DNS 适配。
2. 【事实】Action 协议的真实形态是 `{id, method, data}`；`ActionResult` 是 `{id, method, data, code}`（`code=0` 成功、`-1` 错误）。Action 的 `data` **不是统一对象**：多数方法要求 JSON 字符串，少数要求 bool/字符串/路径。Dart 侧用 `id = "<method>#<utils.id>"` 关联响应（`interface.dart` L143）。
3. 【事实】上一份文档猜测的 `getGroups`、`setProxyGroup`、`testDelay`、`getRules`、`getProviders`、`setProfile/updateProfile/deleteProfile`、`changeMode/getMode`、`getHomeDir` **都不是 core Action**：
   - `getGroups` 由 Dart 从 `getProxies` 结果派生；
   - 选节点是 `changeProxy`，没有 `setProxyGroup`；
   - 测速是 `asyncTestDelay`，没有 `testDelay`；
   - 规则来自 `getConfig` 返回的 `RawConfig`；
   - 提供者是 `getExternalProviders` / `getExternalProvider`；
   - profile 的增删改完全在 Dart 侧（文件 + Preferences）；
   - 模式通过 `updateConfig` 的 `mode` 字段修改，通过 `getConfig` 读取；
   - homeDir 只在 `initClash` 的 `{home-dir}` 中设置，没有 getter；版本是 `getCoreVersion`，不是 `getVersion`。
4. 【事实】`setupConfig` 接收的是 **JSON（`SetupParams`）**，不是 YAML 文本，也不是路径。`SetupParams = {config: RawConfig 对象, selected-map: {组名: 节点名}, test-url: string}`。`getConfig` 才接收 **文件路径**，由 Go 读取 YAML 并返回 `RawConfig` JSON；`validateConfig` 接收 **YAML 文本**。
5. 【事实】`quickStart(init, params, state)` 的三个 JSON 分别是 `InitParams`、`SetupParams`、`CoreState`；`quickStartSync` 在 Go 内同步执行 `initClash → setState → setupConfig`。`initClashSync(29, homeDir)` 的 `version=29` **只在 `handleResolveProcess` 中用作阈值**：`version < 29` 才通过 `/proc/net/*` 查 UID；`>=29` 时 uid 固定 `-1`，即关闭 per-app UID 解析。
6. 【事实】`AndroidVpnOptions` 的精确 JSON 字段是 `enable, port, accessControl, allowBypass, systemProxy, bypassDomain, routeAddress, ipv4Address, ipv6Address, dnsServerAddress, includePackage, excludePackage`；默认地址 `172.19.0.1/30`、DNS `172.19.0.2`、IPv6 `fdfe:dcba:9876::1/126`。`port` 来自 `mixed-port`，在 Android 上用于 HTTP 代理提示；**OHOS 的 `ClashVpnExtensionAbility` 完全忽略 `port` 与 `bypassDomain`**。上一份文档的 ArkTS `VpnOptions` 接口还漏了 `allowBypass`/`systemProxy`。
7. 【事实】TUN 的真实适配在 `core/tun/tun.go`：OHOS 下 **无条件强制 gVisor**、MTU 夹紧到 1420、GSO/RecvMsgX/SendMsgX 关闭，并在 `handleStartTun` 内自动 `handleStartLog()`。Dart 在 OHOS 下把 `tun.stack` 写成 `mixed`，但 core 会覆盖为 gVisor。
8. 【事实】订阅/节点/测速的算法完整存在 `lib/`：订阅 URL 以明文 `url` 存在 `Profile`，随整个 `Config` JSON 写入 `shared_preferences` 的 `config` 键；profile YAML 在 `files/profiles/<id>.yaml`；节点选择持久化在 `Profile.selectedMap`；测速结果按 `url -> proxy -> delay` 存在内存 `DelayMap`，并由 `asyncTestDelay` / `healthCheck` 的 `delay` 事件更新。
9. 【事实】`Profile.update` 会发送 `x-hwid/x-device-os/x-ver-os/x-device-model`（`sendDeviceHeaders` 默认 true），采集 `subscription-userinfo`、`content-disposition`、`profile-update-interval`、`flclashx-*` 等响应头；先 `validateConfig` 再写文件。OHOS 分支没有实现 HWID/OS/model 获取，实际只会带 UA 与可能为空的头。
10. 【事实】geo 部署是 `initGeo()` 把 `assets/data/{geoip.metadb, GeoIP.dat, GeoSite.dat, ASN.mmdb}` 复制到 `getApplicationSupportDirectory()` 根；core 的 `constant/path.go` 从 home 根读取这些固定文件名。没有 profile 时不会内置 YAML；`profiles` 默认空，首页显示「Add Profile」。
11. 【事实】许可证：根 `LICENSE` 是 GPL v3 全文（674 行，无项目版权行）；`core/third_party/sing-tun/LICENSE` 是 GPL-3.0-or-later（Copyright 2022 nekohasekai）；mihomo v1.19.28 也是 GPL v3。HmChat 的 GPL-3.0-or-later 与之兼容，但 `.so` 分发必须补齐对应源码；当前 HEAD 不含 OHOS 支持文件。
12. 【事实】构建脚本 `core/build_ohos.sh` 使用 `GOOS=openharmony GOARCH=arm64 CGO_ENABLED=1`、`-tags with_gvisor`、`-buildmode=c-shared`、`-trimpath`、`-ldflags="-s -w -extldflags=-Wl,-soname,libclash_core.so"`。它 **没有** `-X github.com/metacubex/mihomo/constant.Version=...`，因此 OHOS 产物很可能把 `getCoreVersion` 报成 mihomo 源码默认的 `1.10.0`，而 Dart 生成的 `core_version.dart` 是 `v1.19.28`。
13. 【事实】`core/third_party/sing-tun` 是 v0.4.21 的本地 fork，实际差异只有 5 个文件：3 个新增 `debug_hilog*.go`、`tun_linux.go` 增加 `pumpStop`、`tun_linux_gvisor.go` 用 `channel.Endpoint + rawRead/rawWrite/Poll` 替换 gVisor `fdbased` 端点。
14. 【事实】`source-refs/FlClashX/ohos/` 与 `source-refs/FlClashX-ohos/` 的 16 个关键 ArkTS/CMake/配置/README 文件 SHA-256 完全一致；两份 `libclash_core.so` 也完全一致（51,155,984 字节，SHA-256 `246e77...`）。完整仓库是权威源；旧快照只适合作为已构建产物参考。
15. 【推断】HmChat 的最短可行路径是：保留 Go core 与 Action 协议，改用 ArkTS 重写 `lib/` 的订阅/配置/节点/存储/UI；优先复用 core 的 `getConfig`（YAML→JSON）与 `setupConfig`（JSON 应用），不要把 YAML 解析器搬进 ArkTS。阻断项仍是 GPL 对应源码与 OHOS 构建可复现性。

---

## 1. core/ 结构与职责

### 1.1 文件清单（本工作树实际存在）

【事实】`core/` 根文件（排除 `third_party/`）：

| 文件 | 职责 | 关键行 |
| --- | --- | --- |
| `core/main.go` | `!cgo` 桌面可执行入口：`startServer(args[1])` | L10-L17 |
| `core/main_cgo.go` | `cgo` 构建的空 `main()` | L7-L9 |
| `core/server.go` | `!cgo` 桌面 TCP/Unix socket 服务端；逐行读 Action | L42-L94 |
| `core/lib.go` | cgo C ABI：`getTraffic/getTotalTraffic/freeCString/invokeAction/getConfig/startListener/stopListener`、`sendMessage` | L14-L91 |
| `core/lib_mobile.go` | Android/OHOS 共享 mobile 桥：TUN fd、protect/resolveProcess、`quickStart`、`quickStartSync`、`initClashSync`、`startTUN` 等 | L129-L413 |
| `core/lib_other.go` | 非 Android/OHOS 的 stub；排除 openharmony 后避免重复定义 | L1-L18 |
| `core/android_bride.go` | Android/OHOS 共享 C 回调注册：`registerCallbacks/setEventListener/Protect/ResolveProcess/emitEvent` | L62-L194 |
| `core/action.go` | `Action`/`ActionResult` 与主 dispatch `handleAction` | L10-L278 |
| `core/constant.go` | `InitParams`/`SetupParams`/`UpdateParams`/`ChangeProxyParams`/`TestDelayParams` 与方法常量 | L15-L140 |
| `core/common.go` | 配置应用 `setupConfig`、`updateConfig`、`DefaultRawConfig`、proxy 合并/描述、listener 生命周期 | L32-L445 |
| `core/hub.go` | 状态、listener 启停、流量/连接、provider、日志、健康检查、`getConfig`、`setupConfig` | L35-L1044 |
| `core/state/state.go` | `AndroidVpnOptions`、`AndroidVpnRawOptions`、`State`、默认地址 | L5-L59 |
| `core/dns_android.go` | Android 系统 DNS 更新（`cmfa` tag） | L9-L15 |
| `core/dns_openharmony.go` | OHOS 只清 resolver cache + reset connection | L9-L16 |
| `core/platform/limit.go` | `ShouldBlockConnection` 等平台限制（Android/OHOS） | 全文 |
| `core/platform/procfs.go` | `/proc/net/*` 查 UID；build tag `linux || openharmony` | L23-L65 |
| `core/tun/tun.go` | OHOS/Android TUN 包装：强制 gVisor、MTU 1420、GSO 关闭 | L28-L103 |
| `core/build_ohos.sh` | OHOS 交叉编译脚本（untracked） | L1-L102 |
| `core/go.mod` / `go.sum` | Go module 与依赖锁定 | `go.mod` L1-L152 |
| `core/third_party/sing-tun/` | vendored sing-tun v0.4.21 + OHOS 补丁（untracked） | 见 §6 |

【事实】`lib_android.go` 已不存在；工作树将其重命名为 `core/lib_mobile.go`（`git status` 显示 `RM core/lib_android.go -> core/lib_mobile.go`）。两者是同一文件的新版本，build tag 扩为 `(android || openharmony) && cgo`（L1）。

### 1.2 平台构建标签与分支

【事实】

| 文件 | build tag | 作用 |
| --- | --- | --- |
| `lib_mobile.go` | `(android || openharmony) && cgo` | mobile TUN / callback / OHOS 同步入口 |
| `android_bride.go` | `(android || openharmony) && cgo` | 共享 C 回调分发 |
| `dns_android.go` | `android && cgo` | `dns.UpdateSystemDNS` + flush |
| `dns_openharmony.go` | `openharmony && cgo` | `resolver.ClearCache` + `ResetConnection` |
| `platform/limit.go` | `(android || openharmony) && cgo` | 平台限制 |
| `platform/procfs.go` | `linux || openharmony` | procfs UID 查询 |
| `tun/tun.go` | `(android || openharmony) && cgo` | TUN fd → sing-tun |
| `lib_other.go` | `!android && !openharmony && cgo` | stub，避免与 mobile 重复定义 |
| `main.go/server.go` | `!cgo` | 桌面可执行路径 |

【推断】`runtime.GOOS` 在 OHOS Go 工具链上的实际值需要真机/构建日志确认：`core/tun/tun.go` L58-L64 明确说「runtime.GOOS does NOT report openharmony」，并观察到设备日志 `effective=Mixed`；这会影响 `common.go` 中 `runtime.GOOS == "android"` 的分支（L121-L125、L247-L249、L262-L264、L404-L406）。【待确认】实际是 `android` 还是 `linux`/其他值，决定 OHOS 是否误走 mihomo 内置 TUN listener 分支。

### 1.3 运行数据流（事实）

```text
Dart/ArkTS Action JSON
  → core/lib.go invokeAction (cgo)
  → go handleAction(action, result)
    ├─ 同步方法直接 result.success(...)
    ├─ 异步方法起 goroutine，完成后 result.success/error
    └─ default → nextHandle (lib_mobile.go) 处理 Android/OHOS 专属方法
  → ActionResult.Json()
  → callback(callback, json) / emitEvent(json)
  → NAPI trampoline → ArkTS dispatcher
```

【事实】`invokeAction` 每次调用都 `go handleAction(...)`（`lib.go` L37-L52），所以同一进程内多个 Action 并发；`quickStartSync` 不走 Action，直接同步调用（`lib_mobile.go` L358-L365）。

【事实】`handleStartTun` 把 fd 交给 `core/tun.Start`；`handleStartTun` 先 `handleStopTun`，再 `t.Start(fd, tunCfg)`；失败时返回 false，但 `runTime` 已在 `t.Start` 前设置（L150-L151），失败路径没有清空 `runTime`（L163-L190）。【推断】这会让 `getRunTime` 在启动失败后短暂返回非零；UI 需以 `start` 返回 0 为准，不能只看 `getRunTime`。

---

## 2. Action 协议（完整词表、参数与结果）

### 2.1 结构与线格式

【事实】`core/action.go` L10-L27：

```text
Action       { id: string, method: Method, data: any }
ActionResult { id: string, method: Method, data: any, code: int, callback: pointer(json:"-") }
```

【事实】`ActionResult.success(data)` 设 `code=0`；`ActionResult.error(data)` 设 `code=-1`（L29-L39）。`ActionResult.Json()` marshal 后由 `send()` 交给 `invokeCallback`（`lib.go` L29-L35）。

【事实】`Method` 是字符串枚举（`constant.go` L115）。有效 Action 方法如下表；`data` 类型、Go handler 与结果类型均从 `action.go` / `hub.go` / `lib_mobile.go` 确认。

### 2.2 完整 Action 方法表

| 方法 | Method 常量行 | dispatch 行 | `data` 类型 | 结果 `data` |
| --- | --- | --- | --- | --- |
| `initClash` | L73 | L43-L50 | JSON 字符串（`InitParams`） | bool |
| `getIsInit` | L74 | L51-L53 | 无 | bool |
| `forceGc` | L75 | L54-L57 | 无 | `true` |
| `shutdown` | L76 | L58-L60 | 无 | bool |
| `validateConfig` | L77 | L61-L69 | YAML 文本字符串 | 错误字符串（`''`=合法） |
| `updateConfig` | L78 | L70-L78 | JSON 字符串（`UpdateParams`） | 错误字符串（`''`=成功） |
| `setupConfig` | L106 | L79-L87 | JSON 字符串（`SetupParams`） | 错误字符串（`''`=成功） |
| `getProxies` | L79 | L88-L90 | 无 | `map[string]proxyObject` |
| `changeProxy` | L80 | L91-L100 | JSON 字符串（`ChangeProxyParams`） | 错误字符串（`''`=成功） |
| `getTraffic` | L81 | L101-L103 | 无 | JSON 字符串 `{"up","down"}` |
| `getTotalTraffic` | L82 | L104-L106 | 无 | JSON 字符串 `{"up","down"}` |
| `resetTraffic` | L83 | L107-L110 | 无 | `true` |
| `asyncTestDelay` | L84 | L111-L120 | JSON 字符串（`TestDelayParams`） | `Delay` JSON 字符串 |
| `getConnections` | L85 | L121-L123 | 无 | JSON 字符串（snapshot） |
| `closeConnections` | L86 | L124-L126 | 无 | bool |
| `resetConnections` | L87 | L127-L129 | 无 | bool |
| `getConfig` | L107 | L130-L142 | 文件路径字符串 | `RawConfig` JSON；错误时 `error` |
| `getCoreVersion` | L108 | L143-L145 | 无 | `constant.Version` 字符串 |
| `closeConnection` | L88 | L146-L153 | connection id 字符串 | bool |
| `getExternalProviders` | L89 | L154-L156 | 无 | JSON 数组字符串 |
| `getExternalProvider` | L90 | L157-L164 | provider 名字符串 | JSON 对象字符串 |
| `updateGeoData` | L93 | L165-L182 | JSON 字符串 `{geo-type,geo-name}` | 错误字符串 |
| `updateExternalProvider` | L94 | L183-L192 | provider 名字符串 | 错误字符串 |
| `sideLoadExternalProvider` | L95 | L193-L210 | JSON 字符串 `{providerName,data}` | 错误字符串 |
| `startLog` | L96 | L211-L214 | 无 | `true` |
| `stopLog` | L97 | L215-L218 | 无 | `true` |
| `startListener` | L98 | L219-L221 | 无 | bool |
| `stopListener` | L99 | L222-L224 | 无 | bool |
| `getCountryCode` | L91 | L225-L234 | IP 字符串 | 国家代码字符串 |
| `getMemory` | L92 | L235-L239 | 无 | 字节数（十进制字符串） |
| `setState` | L101 | L240-L248 | JSON 字符串（`CoreState`） | `true` |
| `healthCheck` | L109 | L249-L254 | 组名字符串（空=全部） | `''`（结果走 `delay` 事件） |
| `healthProbe` | L110 | L255-L259 | 无 | `"ok"` / `""` |
| `setUiActive` | L111 | L260-L264 | bool | `true` |
| `setScreenActive` | L112 | L265-L269 | bool | `true` |
| `crash` | L105 | L270-L272 | 无 | `true` 后 panic（测试用） |
| `getAndroidVpnOptions` | L102 | `lib_mobile.go` L296-L298 | 无 | JSON 字符串 |
| `updateDns` | L100 | `lib_mobile.go` L299-L307 | JSON 数组或逗号分隔字符串 | `true` |
| `getRunTime` | L103 | `lib_mobile.go` L308-L310 | 无 | epoch ms 字符串 |
| `getCurrentProfileName` | L104 | `lib_mobile.go` L311-L313 | 无 | 字符串 |
| `startTun` / `stopTun` | Dart enum 有，core 无常量 | 无 Action；仅 NAPI | — | — |
| `message` | L72 | `sendMessage` 内部事件，不是可调用 Action | — | — |

【事实】事件推送不是独立线格式，而是把 `Message{type,data}` 包进 `ActionResult`：`sendMessage` 构造 `ActionResult{Method:"message", Data: Message{...}}` 后 `emitEvent`（`lib.go` L54-L67；`constant.go` L117-L135）。因此 UI 收到的 `event` 内容形如：

```json
{ "id": "", "method": "message", "data": { "type": "delay|log|request|loaded", "data": ... }, "code": 0 }
```

【事实】`handleAction` 的 `default` 调 `nextHandle(action,result)`（`action.go` L273-L277）；`nextHandle` 只处理上表最后 4 个 Android/OHOS 方法，其余返回 false 并得到 `unknown method: ...` 错误（`lib_mobile.go` L294-L316）。

【事实】`startTun`/`stopTun` 在 Dart `ActionMethod` 枚举中存在（`lib/enum/enum.dart` L291-L292），但 core `constant.go` 没有对应 Method 常量，`handleAction` 也没有 case；实际启动/停止 TUN 走 NAPI `startTun`/`stopTun`（`lib_mobile.go` L367-L380），不通过 Action。

### 2.3 关键方法的参数 schema

【事实】`InitParams`（`constant.go` L15-L18）：

```json
{ "home-dir": "/abs/path", "version": 29 }
```

【事实】`SetupParams`（L20-L24）：

```json
{
  "config": { /* mihomo RawConfig JSON，规则键是 "rule" 不是 "rules" */ },
  "selected-map": { "GROUP": "PROXY" },
  "test-url": "https://www.gstatic.com/generate_204"
}
```

【事实】`UpdateParams`（L26-L39）：

```json
{
  "tun": {
    "enable": true,
    "device": "...",
    "stack": "gvisor|system|mixed",
    "dns-hijack": ["any:53"],
    "auto-route": true,
    "route-address": ["..."]
  },
  "allow-lan": false,
  "mixed-port": 7890,
  "find-process-mode": "always|strict|off",
  "mode": "rule|global|direct",
  "log-level": "silent|error|warning|info|debug",
  "ipv6": true,
  "sniffing": true,
  "tcp-concurrent": true,
  "external-controller": "127.0.0.1:9090",
  "interface-name": "",
  "unified-delay": true
}
```

【事实】`ChangeProxyParams`（L50-L53）：

```json
{ "group-name": "GROUP", "proxy-name": "PROXY" }
```

空 `proxy-name` 会走 `selector.ForceSet("")`（`hub.go` L589-L591）。

【事实】`TestDelayParams`（L55-L59）：

```json
{ "proxy-name": "PROXY", "test-url": "https://...", "timeout": 5000 }
```

`timeout` 单位 ms；`test-url` 为空时 core 用 `https://www.gstatic.com/generate_204`（`hub.go` L675-L680）。

【事实】`updateGeoData`（L165-L182）参数 JSON：

```json
{ "geo-type": "MMDB|ASN|GeoIp|GeoSite", "geo-name": "..." }
```

【事实】`sideLoadExternalProvider`（L193-L210）参数 JSON：

```json
{ "providerName": "...", "data": "<provider 文件内容字符串>" }
```

【事实】`setupConfig`/`updateConfig`/`validateConfig` 的错误语义是「返回非空字符串 = 失败」，不是靠 `ActionResult.error`；`handleSetupConfig` 解析失败会先 fallback 到 `defaultSetupParams()` 再返回错误（`hub.go` L1031-L1044），`handleUpdateConfig` 解析失败直接返回错误（L1021-L1029）。

### 2.4 `quickStart(init, params, state)` 的精确 schema

【事实】Dart `ClashLib.quickStart` 把三个对象分别 `json.encode`（`lib/clash/lib.dart` L315-L329）；`ClashServiceChannel` 把 `{init,params,state}` 转发给 RPC（`ClashServiceChannel.ets` L175-L185）；RPC handler 调用 `CoreBridge.quickStart(args.init,args.params,args.state)`（`ClashVpnExtensionAbility.ets` L139-L142）。

【事实】`core` 的 `quickStart`/`quickStartSync`（`lib_mobile.go` L318-L365）：

1. `handleInitClash(initParams)`；失败返回 `"init error"`。
2. `handleSetState(stateParams)`。
3. `handleSetupConfig([]byte(params))`；返回错误字符串（`''`=成功）。

因此：

- `init` = `InitParams`：`{"home-dir": string, "version": int}`（`constant.go` L15-L18）。
- `params` = `SetupParams`：`{"config": RawConfig, "selected-map": map[string]string, "test-url": string}`（L20-L24）。
- `state` = `CoreState`：Dart 模型字段为 `vpn-props`、`only-statistics-proxy`、`current-profile-name`、`bypass-domain`（`lib/models/core.dart` L68-L79）。
- 【事实】Go `state.State` 只有 `vpn-props`、`current-profile-name`、`bypass-domain`（`core/state/state.go` L39-L43）；`only-statistics-proxy` 是 Dart 额外字段，Go 的 `json.Unmarshal` 会忽略未知字段。

【推断】HmChat 若直接发 `only-statistics-proxy` 不影响 core；但若要严格对齐，可去掉或保留为前端统计开关。

### 2.5 `initClashSync(version=29)` 的含义

【事实】`handleInitClash`（`hub.go` L77-L108）：

- 反序列化 `InitParams`；
- `debug.SetGCPercent(-1)`、`debug.SetMemoryLimit(70MB)`；
- `version.Store(int32(params.Version))`；
- `constant.SetHomeDir(params.HomeDir)`；
- `uiActive=true`、`screenActive=true`、`isInit=true`。

【事实】全仓库对 `version.Load()` 的唯一使用在 `lib_mobile.go` L106-L108：

```go
if version.Load() < 29 {
    uid = platform.QuerySocketUidFromProcFs(source, target)
}
return ResolveProcess(t.callback, protocol, source.String(), target.String(), uid)
```

因此 `version=29` 的实际含义是「**跳过 per-app UID 的 /proc 查询，uid=-1**」；不是协议版本、不是配置版本、不是 mihomo 版本。`ResolveProcess` 回调再由 NAPI `TrampResolveProcess` 返回 `nullptr`（`clash_bridge.cpp` L173-L179），所以 OHOS 分应用归属为空。

【推断】如果以后要恢复 OHOS 分应用归属，需要把 version 降到 28 并实现 `platform.QuerySocketUidFromProcFs` 在 OHOS 的可用性；但这会增加权限/隐私与性能风险。

### 2.6 `getConfig` 与 `setupConfig` 的 JSON 细节

【事实】`getConfig`（`hub.go` L917-L927）读取路径文件，`config.UnmarshalRawConfig(bytes)` 返回 `*RawConfig`，`ActionResult.success(config)` 序列化。`lib.go` 的 C 导出版 `getConfig` 失败时返回空字符串（L69-L81），丢失错误；Action 版通过 `result.error(err)` 保留错误（L130-L142）。

【事实】mihomo `RawConfig` 的 JSON tag 中，规则字段是 `json:"rule"`（`config/config.go` L399-L470，尤其 L452），不是 `rules`。Dart 在 `state.dart` L767-L776 把 `getConfig` 返回的 `rule` 改名为 `rules` 做 UI 处理，最后在 L749-L763 再写回 `rawConfig["rule"] = rules`。HmChat 直接构造 `SetupParams.config` 时必须使用 `rule`，否则 `UnmarshalRawConfig` 的规则为空。

【事实】`setupConfig` 流程（`common.go` L384-L438）：

1. `extractProxyDescriptionsFromRaw`；
2. `computeMinHealthCheckInterval`；
3. `resetHealthCheckForwarderState`；
4. 设置 `currentTestURL`；
5. `config.ParseRawConfig(params.Config)`；失败则 fallback `config.DefaultRawConfig()` 并记录错误；
6. `pendingTunEnable`、移动端 TUN 禁用逻辑；
7. `executor.ApplyConfig(currentConfig, true)`；
8. 恢复 `currentConfig.General.Tun.Enable`；
9. 重建 external-controller、`patchSelectGroup(params.SelectedMap)`；
10. `updateListeners()`；
11. `runInitialProviderHealthChecks()`、`startHealthCheckForwarder()`；
12. 发 `Message{Type:"loaded", Data:"all"}`。

【事实】`setupConfig` 不接收 YAML 文本；它接收已经解析/修补过的 `RawConfig` JSON。`validateConfig` 才是 YAML 文本 → 错误字符串。`updateConfig` 只热更新网络/模式等字段，不重载完整配置（`common.go` L309-L382）。

### 2.7 `AndroidVpnOptions` 精确字段、默认值与用途

【事实】`core/state/state.go`：

| JSON 字段 | Go 类型 | 来源/默认 | 用途 |
| --- | --- | --- | --- |
| `enable` | bool | `state.CurrentState.VpnProps.Enable`；Dart 默认 true | Android/OHOS 是否启用 VPN |
| `port` | int | `currentConfig.General.MixedPort`（默认 7890；可被 header 强制 0） | Android `setHttpProxy` 的端口；OHOS 扩展未使用 |
| `accessControl` | object | `VpnProps.AccessControl`；Dart 默认 `{enable:false, mode:rejectSelected, acceptList:[], rejectList:[]}` | 分应用白/黑名单 |
| `allowBypass` | bool | `VpnProps.AllowBypass`；默认 false | Android 允许绕过 VPN 的应用列表策略 |
| `systemProxy` | bool | `VpnProps.SystemProxy && mixedPort != 0` | Android 系统代理提示；OHOS 未使用 |
| `bypassDomain` | string[] | `state.CurrentState.BypassDomain`；Dart 默认 `defaultBypassDomain`（`models/config.dart` L13-L31） | Android 直连域名；**OHOS 扩展未使用** |
| `routeAddress` | string[] | `currentConfig.General.Tun.RouteAddress` | TUN 路由前缀；为空则默认全局 |
| `ipv4Address` | string | `state.DefaultIpv4Address = "172.19.0.1/30"` | VpnConfig 地址 |
| `ipv6Address` | string | `state.GetIpv6Address()`：`VpnProps.Ipv6` 为 true 时 `"fdfe:dcba:9876::1/126"`，否则 `""` | VpnConfig IPv6 |
| `dnsServerAddress` | string | `state.GetDnsServerAddress() = "172.19.0.2"` | VpnConfig DNS |
| `includePackage` | string[] | `currentConfig.General.Tun.IncludePackage` | 映射 `trustedApplications` |
| `excludePackage` | string[] | `currentConfig.General.Tun.ExcludePackage` | 映射 `blockedApplications` |

【事实】`handleGetAndroidVpnOptions`（`lib_mobile.go` L240-L271）还做了一件关键事：`systemProxy = VpnProps.SystemProxy && mixedPort != 0`；当 `mixed-port=0` 时强制关闭系统代理提示，避免 `127.0.0.1:0`。

【事实】OHOS `ClashVpnExtensionAbility` 的 `VpnOptions` 接口只声明 `ipv4Address/ipv6Address/accessControl/routeAddress/bypassDomain/dnsServerAddress/includePackage/excludePackage/enable/port`（L23-L34），**没有 `allowBypass`/`systemProxy`**，且 `buildVpnConfig` 只使用地址/路由/DNS/应用列表（L245-L333）。因此 core 返回的 `allowBypass`/`systemProxy` 在 OHOS 被丢弃。

【事实】`port` 与 `bypassDomain` 在 OHOS 扩展中只出现在接口声明（L25、L30），没有任何使用点；这是上一份文档已指出的事实，本轮由 core 源码确认其来源。

### 2.8 对上一份文档的关键修正

| 上一份猜测 | 实际实现 | 证据 |
| --- | --- | --- |
| `getGroups` Action | 不存在；Dart 从 `getProxies` 派生 | `lib/clash/core.dart` L100-L147；`hub.go` L543-L547 |
| `setProxyGroup` | 不存在；用 `changeProxy({group-name,proxy-name})` | `constant.go` L80、L50-L53；`hub.go` L549-L602 |
| `testDelay` | 不存在；用 `asyncTestDelay` | `constant.go` L84；`hub.go` L636-L700 |
| `getRules` | 不存在；规则在 `getConfig` 返回的 `RawConfig.rule` | `config/config.go` L452；`hub.go` L917-L927 |
| `getProviders` | 用 `getExternalProviders` / `getExternalProvider` | `constant.go` L89-L90；`hub.go` L746-L782 |
| `setProfile`/`updateProfile`/`deleteProfile` | 无 core Action；profile 由 Dart 文件/Preferences 管理 | `models/profile.dart` L50-L80、L136-L245；`controller.dart` L246-L269 |
| `changeMode`/`getMode` | 无专用 Action；`updateConfig.mode` / `getConfig.mode` | `common.go` L339-L342；`constant.go` L78 |
| `getVersion` | 用 `getCoreVersion`，返回 `constant.Version` | `constant.go` L108；`action.go` L143-L145 |
| `getHomeDir` | 无 getter；只在 `initClash` 的 `home-dir` 设置 | `constant.go` L15-L18；`hub.go` L99 |
| `healthProbe` 是公开 Action | Go 有，但 Dart `ActionMethod` 未暴露；后台 watchdog 用 | `constant.go` L110；`action.go` L255-L259；`enum.dart` L253-L297 |
| `setScreenActive` 是公开 Action | Go 有，Dart 未暴露；Android SuspendModule 用 | `constant.go` L112；`action.go` L265-L269 |

### 2.9 不是 core Action、必须由 HmChat 自己实现的能力

| 能力 | FlClashX 的实现路径 | HmChat 需要做什么 |
| --- | --- | --- |
| `setProfile`（设为当前） | `addProfile` 写 profiles、首个自动设 `currentProfileId`；`profilesProvider`/`needSetup` 触发 `applyProfile`（`controller.dart` L246-L253） | ArkTS `ProfileStore.setCurrent` + `applyProfile`；没有 core 调用 |
| `updateProfile`（刷新订阅/元数据） | `Profile.update` HTTP→validate→写 YAML；`updateProfile` 合并 headers、更新当前 profile 后 debounce apply（`profile.dart` L171-L245；`controller.dart` L433-L496） | ArkTS `SubscriptionUpdater`；HTTPS、重定向、头采集、validate、写文件 |
| `deleteProfile`（删除） | `profilesProvider.deleteProfileById` + `clearEffect` 删除 YAML/provider 目录；若删当前则选第一个或 null/stop（`controller.dart` L255-L269、L1602-L1616） | ArkTS `ProfileStore.delete` + 文件清理 + 状态收敛 |
| `changeMode` / `getMode` | 无 Action；改 `patchClashConfig.mode` 后 `updateConfig`；读 `getConfig`/本地 Config（`controller.dart` L1791-L1799；`common.go` L339-L342） | ArkTS 设置 `mode` 并调用 `updateConfig`；从 `getConfig`/`SetupParams.config.mode` 读回 |
| `getVersion` | `getCoreVersion` 返回 `constant.Version`（`action.go` L143-L145） | 调 `getCoreVersion`；同时显示 Dart/ArkTS app 版本与 mihomo 版本 |
| `getHomeDir` | 无 getter；`initClash` 写入 `home-dir`；Dart `appPath.homeDirPath` 本地已知（`constant.go` L15-L18；`hub.go` L99） | ArkTS 自己持有 `filesDir` 根；不向 core 查询 |
| `setProxyGroup` | 无；`changeProxy` 的 `{group-name,proxy-name}`（`hub.go` L549-L602） | ArkTS 用 `changeProxy`，并写 `Profile.selectedMap` |
| `getGroups` | 无；`getProxies` + Dart 派生（`core.dart` L100-L147） | ArkTS 复用 §3.5 的组派生算法 |
| `getRules` | 无；`getConfig` 的 `RawConfig.rule`（`config/config.go` L452） | ArkTS 从 `getConfig` 取规则；修改后写回 `rule` |
| `getProviders` | `getExternalProviders` / `getExternalProvider`（`hub.go` L746-L782） | ArkTS 用这两个 Action；不要找 `getProviders` |
| `testDelay` | `asyncTestDelay`（`hub.go` L636-L700） | ArkTS 用 `asyncTestDelay`；处理 `Delay` 事件 |

---

## 3. 订阅、节点、测速的可移植逻辑

### 3.1 `lib/` 侧关键文件

| 文件 | 职责 | 关键行 |
| --- | --- | --- |
| `lib/clash/interface.dart` | `ClashInterface` + `ClashHandlerInterface.invoke`，Action id、Completer、typed default、超时 | L95-L179、L181-L416 |
| `lib/clash/lib.dart` | MethodChannel `com.wormhole.app/service`；OHOS/Android 共用 | L15-L381 |
| `lib/clash/core.dart` | 高层 API：init/setup/getProxiesGroups/changeProxy/getConnections/getConfig/... | L16-L316 |
| `lib/clash/message.dart` | `event` → `AppMessage` → log/delay/request/loaded 分发 | L8-L70 |
| `lib/state.dart` | `Config` 生成、`getCoreState`、`getSetupParams`、`patchRawConfig`、geo | L394-L810 |
| `lib/controller.dart` | 编排：init/applyProfile/订阅更新/删除/选节点/测速/崩溃恢复 | L246-L269、L433-L496、L630-L800、L830-L999、L1244-L1370、L1452-L1541、L1764-L1799 |
| `lib/models/profile.dart` | Profile/SubscriptionInfo/OverrideData；订阅下载与写文件 | L20-L265 |
| `lib/models/config.dart` | Config/VpnProps/NetworkProps/AppSettingProps 默认值 | L13-L160、L245-L263 |
| `lib/models/clash_config.dart` | ClashConfig/Tun/Dns/GeoXUrl/ProxyGroup/Rule | L106-L506 |
| `lib/models/common.dart` | Proxy/Group/Connection/Log/Traffic/Delay 等 | L41-L319 |
| `lib/common/path.dart` | 应用目录、profile 文件、provider 文件 | L70-L117 |
| `lib/common/preferences.dart` | `config`/`clash_config` 读写 | L27-L70 |
| `lib/common/request.dart` | dio 订阅下载、UA、redirect、超时 | L12-L99 |
| `lib/utils/device_info_service.dart` | HWID/OS/型号，Android/桌面分支 | L26-L174 |
| `lib/common/ua.dart` | UA 预设与默认 `clash-verge/v2.4.5` | L46-L120 |
| `lib/services/subscription_notification_service.dart` | 订阅到期通知（仅 Android） | L13-L28 |

### 3.2 订阅 URL 的保存、拉取、解析、更新

【事实】Profile 模型 `lib/models/profile.dart` L50-L67：

```text
id, label?, currentGroupName?, url (default ""),
lastUpdateDate?, autoUpdateDuration, subscriptionInfo?,
autoUpdate (default true), selectedMap (default {}), unfoldSet (default {}),
overrideData (default OverrideData()), isUpdating (transient), providerHeaders (default {})
```

【事实】`url.isEmpty == true` 表示本地文件 profile，否则是 URL profile（`ProfileExtension.type`，L136-L140）。`Profile.normal({label,url})` 用当前毫秒时间戳作为 id，默认更新间隔 `defaultUpdateDuration`（`lib/common/constant.dart` L33：1 天）（L72-L80）。

【事实】订阅 URL 的保存位置：

- `Profile.url` 字段（L55）随整个 `Config` JSON 写入 `shared_preferences` 的 `config` 键（`preferences.saveConfig` L53-L59；`configKey` = `"config"`，`constant.dart` L46）。
- `Profile` 没有单独的加密字段；`saveConfig` 直接 `json.encode(config)`，所以 **订阅 URL 明文**（包括 URL 内 `user:pass@host` 的 userinfo；`normalizeUrlCredentials` 只把 `@` 编码为 `%40`，不隐藏凭据，`lib/common/string.dart` L11-L19）。
- 旧版本还有 `clash_config` 键（`constant.dart` L45；`preferences.getClashConfig` L27-L38），用于迁移。

【事实】`Profile.update`（`profile.dart` L171-L245）的步骤：

1. `shouldSendHeaders` 为 true 时，构造 `x-hwid`、`x-device-os`、`x-ver-os`、`x-device-model`（L174-L182）。
2. `request.getFileResponseForUrl(url, headers)`（L184-L187）。
3. 读取 `content-disposition`、`subscription-userinfo`（L189-L190）。
4. 收集 `announce`、`support-url`、`profile-update-interval`、`x-hwid-max-devices-reached`、`x-hwid-not-supported`，以及所有 `flclashx-*` 响应头（L199-L218）。
5. `profile-update-interval` 按**小时**解析为 `Duration(hours: h)`（L220-L227）。
6. `flclashx-newdomain` 存在时替换 URL host（L229-L236）。
7. `copyWith(url,label,subscriptionInfo,autoUpdateDuration,providerHeaders).saveFile(responseData)`（L238-L244）。

【事实】`saveFile`（L247-L255）：

1. `clashCore.validateConfig(utf8.decode(bytes))`；非空错误字符串则 `throw`；
2. 写 `files/profiles/<id>.yaml`；
3. `lastUpdateDate = now`。

【事实】`Request.getFileResponseForUrl`（`request.dart` L49-L89）：

- 使用 dio，默认 `User-Agent: browserUa`（L15-L19），随后被 `globalState.ua` 覆盖（L55）；
- `connectTimeout=15s`、`receiveTimeout=60s`（L23-L24）；
- 第一次 `followRedirects:false`，若 3xx 读 `location`，再 `followRedirects:true,maxRedirects:5`（L59-L86）；
- 状态码：第一次 `<400`，第二次 `<500`；
- 不解析 base64/非 YAML；非 YAML 会在 `validateConfig` 失败。

【事实】OHOS 设备头缺口：`DeviceInfoService.getDeviceDetails` 只处理 Windows/Android/Linux/macOS（`device_info_service.dart` L142-L162），没有 `isOhos` 分支；`_getPlatformDeviceId` 也没有 OHOS 分支（L71-L109）。因此在 Flutter-OHOS 上 `hwid/os/osVersion/model` 基本为 null，只有 `appVersion` 能得到；`x-hwid` 等不会发送。部分订阅面板要求 HWID，可能拒绝或返回不同配置。【待确认】目标订阅是否强制 HWID。

【事实】更新调度：

- `Application._autoUpdateProfilesTask` 每 20 分钟调用 `autoUpdateProfiles`（`application.dart` L78-L86）。
- `autoUpdateProfiles` 遍历 profiles，跳过 `!autoUpdate`、未到期、`ProfileType.file`，逐个 `updateProfile`；异常只 log（`controller.dart` L830-L847）。
- 到期条件：`lastUpdateDate + autoUpdateDuration` 早于 now（L833-L837）。
- 启动后 1 秒 `_updateCurrentProfileSubscription`（`controller.dart` L1305-L1307），但会跳过已被 `autoUpdateProfiles` 覆盖的当前 profile（L882-L897）。
- `updateProfile` 更新当前 profile 后才 `applyProfileDebounce(silence:true)`；非当前 profile 不应用（L481-L483）。
- 订阅到期通知 `SubscriptionNotificationService` 仅 `Platform.isAndroid`（L25-L28），OHOS 不触发。

【事实】错误处理：

- `updateProfile` 失败时把 `isUpdating=false` 后 `rethrow`（L490-L495）；`addProfileFormURL` 捕获并 `showMessage`（L1484-L1488）；`autoUpdateProfiles` 捕获只 log（L841-L845）。
- `Profile.update` 没有重试/退避；失败靠下一轮 20 分钟调度。
- `saveFile` 验证失败不会写文件，也不会更新 `lastUpdateDate`。

### 3.3 配置生成算法（`patchRawConfig`）

【事实】`getSetupParams`（`state.dart` L404-L417）调用 `patchRawConfig(patchConfig: current patch config)`，把结果作为 `SetupParams.config`，`selectedMap` 取当前 profile 的 `selectedMap`，`testUrl` 取 `appSetting.testUrl`。

【事实】`patchRawConfig`（L465-L765）的完整步骤：

1. 无当前 profile → 返回 `{}`（L468-L471）。
2. `getProfileConfig(profileId)` → `clashCore.getConfig(profilePath)`（core 读 YAML 并返回 `RawConfig` JSON）；把 `configMap["rules"] = configMap["rule"]`，删除 `rule`（L767-L776）。
3. 若配置了 `scriptProps.currentScript`，用 `handleEvaluate` 在 QuickJS（`flutter_js`）中执行 `main(config)`，返回新 config（L779-L810）。
4. 从 `proxy-groups` 提取：组描述 `description`、GLOBAL 的 `flclashx-override` 与顺序、所有组声明顺序 `proxyGroupOrder`（L481-L520）。
5. `external-controller`：profile 值优先；否则用 UI 默认 `127.0.0.1:9090`；`external-ui`：profile 值优先，否则 `home/zashboard`；`interface-name=""`；`secret` 来自 profile（L521-L547）。
6. 网络字段：`tcp-concurrent`、`unified-delay`、`log-level`、`keep-alive-interval`；`overrideNetworkSettings` 决定 UI 值优先还是 profile 值优先（L548-L607）。
7. 端口：`port/socks-port/redir-port/tproxy-port/mixed-port`；`mode`；若 `isOhosOrAndroid` 且 profile 头 `flclashx-androidsecure=true`，强制 `mixed-port=0`（L578-L622）。
8. TUN：移动端 `enable=true`；`device`、`dns-hijack`、`stack`（OHOS 强制 `"mixed"`）、`route-address`、`auto-route`（L624-L654）。
9. `geodata-loader`；sniffer 端口字符串化；`profile.store-selected=false`（L655-L701）。
10. 把 `proxy-providers`/`rule-providers` 中 `type=http` 的 `url` 改成本地 `profiles/providers/<id>/proxies|rules/<md5(url)>` 路径（L667-L699）。
11. `geox-url`：默认 `GeoXUrl` 与 profile 值逐项合并，profile 优先（L703-L719）。
12. `global-ua` = 用户选择或 `clash-verge/v2.4.5`；`hosts` 合并（L720-L730）。
13. DNS：如果 `overrideDns` 或 profile `dns.enable != true`，用 patch DNS；若原 DNS 未启用则追加 `system://`；`nameserver-policy` 的值按多分隔符拆分（L731-L748）。
14. 规则：取 `rules`，删除原键；若 `overrideData.enable` 且没有脚本，按 override/added 替换/前置；最后写回 `rawConfig["rule"]`（L749-L764）。
15. 返回 JSON 对象；`SetupParams` 再包 `selected-map`、`test-url`。

【关键事实】Dart 从不自己解析 YAML：它通过 core 的 `getConfig(path)` 得到 `RawConfig` JSON，编辑 JSON，再 `setupConfig` 回 core。HmChat 若不想在 ArkTS 写 YAML 解析器，应保留同样的 `getConfig` 往返；否则需要实现 YAML→`RawConfig` 的完整解析（不推荐）。

【事实】OHOS 的 `tun.stack` 在 Dart 被强制 `"mixed"`（L643-L651），但 core `core/tun/tun.go` 又无条件覆盖为 gVisor（L58-L65）。因此最终是 gVisor；Dart 的 `mixed` 只是历史兼容。

### 3.4 Profile 模型

【事实】`Profile` 字段（`profile.dart` L50-L67）：

| 字段 | 类型 | 用途 |
| --- | --- | --- |
| `id` | string | 文件名 `profiles/<id>.yaml`；必须唯一 |
| `label` | string? | 展示名；缺省回退 id |
| `currentGroupName` | string? | 当前选中的代理组 |
| `url` | string | 订阅 URL（明文；空=本地文件） |
| `lastUpdateDate` | DateTime? | 上次成功更新时间 |
| `autoUpdateDuration` | Duration | 默认 1 天；可被响应头 `profile-update-interval` 覆盖 |
| `subscriptionInfo` | SubscriptionInfo? | `upload/download/total/expire` |
| `autoUpdate` | bool | 默认 true；file 类型实际不更新 |
| `selectedMap` | Map<String,String> | 组名→节点名；应用时 `patchSelectGroup` |
| `unfoldSet` | Set<String> | UI 展开状态 |
| `overrideData` | OverrideData | 规则覆盖/追加 |
| `isUpdating` | bool（不序列化） | 下载中状态 |
| `providerHeaders` | Map<String,String> | 订阅响应头缓存 |

【事实】`SubscriptionInfo.formHString`（L31-L46）解析 `subscription-userinfo` 的 `upload=...;download=...;total=...;expire=...`；`expire` 单位秒（`SubscriptionNotificationService` L44 用 `expire * 1000`）。

【事实】`OverrideData`/`OverrideRule`（L84-L127）：`enable`、`type`（added/override）、`overrideRules`、`addedRules`；`runningRule` 返回当前类型列表。

【事实】`ProfileExtension`：`type`、`realAutoUpdate`、`checkAndUpdate`、`check`、`getFile`、`profileLastModified`、`update`、`saveFile`、`saveFileWithString`（L136-L265）。

### 3.5 节点/代理组模型与选择

【事实】`Proxy`（`models/common.dart` L250-L258）：`{name, type, now?, serverDescription?}`。

【事实】`Group`（L260-L273）：`{type: GroupType, all: Proxy[], now?, hidden?, testUrl?, icon, name}`。

【事实】`GroupType`（`enum.dart` L45-L61）：`Selector`、`URLTest`、`Fallback`、`LoadBalance`、`Relay`；`isComputedSelected` 为 URLTest/Fallback。

【事实】`ClashCore.getProxiesGroups`（`core.dart` L100-L147）：

1. `getProxies()` 返回 `Map<String, dynamic>`；
2. `isGroup(name)`：`GroupTypeExtension.valueList.contains(proxies[name]["type"])`；
3. 从 `proxies["GLOBAL"]["all"]` 过滤出组名，保持 GLOBAL 顺序；
4. `groupNames = ["GLOBAL", ...fromGlobal]`；
5. 若 `globalState.globalOverrideEnabled`，再按 `profile` 中 `proxy-groups` 的声明顺序补入 `proxies.keys` 中未出现的组；
6. 对每个组，把 `all` 中的名字替换为 `proxies[name]` 的完整对象（缺失则丢）；
7. `Group.fromJson`。

【事实】core `handleGetProxies` 返回 `proxiesWithDescriptions()`（`hub.go` L543-L547、`common.go` L129-L150）：每个 proxy 先 `json.Marshal`，再解成 map，注入从 RawConfig 的 `serverDescription`/`server-description` 提取的描述。mihomo 的 `Proxy.MarshalJSON` 会附加 `history`、`extra`、`alive`、`name`、`udp`、`uot`、`xudp`、`tfo`、`mptcp`、`smux`、`interface`、`routing-mark`、`provider-name`、`dialer-proxy`（模块 `adapter/adapter.go` L136-L158）；组还会带 `now/all/testUrl/hidden/icon/emptyFallback`（`adapter/outboundgroup/selector.go` L55-L77）。

【事实】`changeProxy` 应用流程（`controller.dart` L977-L999）：

1. `clashCore.changeProxy(ChangeProxyParams(groupName,proxyName))`；
2. 若 `appSetting.closeConnections`，`closeConnections()`；
3. `updateCurrentSelectedMap` 把选择写入 `Profile.selectedMap`（L1764-L1776）；
4. 移动端若正在运行，`_persistColdStartParams()`（OHOS 的 `saveParams` 目前是 no-op）。

【事实】`setupConfig` 的 `selected-map` 通过 `patchSelectGroup` 重新 `ForceSet`（`common.go` L268-L287），所以选择在 profile 重载/重启后保持。

【事实】`getProxies` 没有 `getGroups` Action；HmChat 必须自己实现上述组派生算法，或直接复用 core 返回的 `GLOBAL.all` 与 `type`。

【推断】`Group.all` 里的嵌套组会以 `Proxy` 形式出现（type 是组类型）；Dart 用 `GroupsExt.resolveToLeafProxy` 深度 16 解析到叶子（`models/common.dart` L281-L307），HmChat 应复用这个逻辑显示真实节点。

### 3.6 测速（`asyncTestDelay`）与健康检查（`healthCheck`）

【事实】单节点测速：

- Dart `ClashCore.getDelay(url, proxyName)` → `clashInterface.asyncTestDelay(url, proxyName)`（`core.dart` L239-L242）。
- Action 参数：`{proxy-name, test-url, timeout: httpTimeoutDuration.inMilliseconds}`；`httpTimeoutDuration=5000ms`（`constant.dart` L28）；客户端超时 6000ms；失败默认返回 `Delay(name,url,-1)`（`interface.dart` L372-L392）。
- core `handleAsyncTestDelay`（`hub.go` L636-L700）：
  1. 并发信号量 `testDelaySem` 上限 50（`common.go` L37）；
  2. 解析 `TestDelayParams`；
  3. 默认 URL `https://www.gstatic.com/generate_204`；
  4. `proxy.URLTest(ctx, testUrl, expectedStatus)`；
  5. 失败或 delay=0 → `value=-1`；
  6. 成功 → `Delay{Name,Url,Value}` 返回，并 `sendMessage(DelayMessage)` 推送。
- Dart `proxyDelayTest` 先写 `value=0`（加载态），再写结果；失败写 -1（`views/proxies/common.dart` L24-L56）。
- 批量测速按 100 个一批 `Future.wait`（L58-L100）。

【事实】组健康检查：

- `ClashCore.healthCheck([groupName])` → Action `healthCheck`；UI 代理页按钮调用 `healthCheck()`（`views/proxies/proxies.dart` L36）。
- core `handleHealthCheck`（`hub.go` L929-L982）：
  - `groupName` 为空 → 所有 `tunnel.Proxies()` 中实现 `ProxyGroup` 的组；
  - 每组优先用 provider 的 `HealthCheckURL()`，否则 `currentTestURL`；
  - 先给组内每个 proxy 发 `Delay{Value:0}`；
  - `group.URLTest(ctx, testUrl, expectedStatus)`，10 秒超时；
  - 结果逐条发 `Delay` message。
- `healthProbe`（L990-L1015）是后台 watchdog 的单次 `GLOBAL` 204 探测，返回 `"ok"`/`""`，Dart 未暴露。

【事实】延迟数据在 Dart 内存中按 `DelayMap = Map<url, Map<proxy, int?>>` 保存（`providers/app.dart` L303-L325）；`ClashManager.onDelay` 更新并 debounce 5s 刷新组（`manager/clash_manager.dart` L69-L80）；`getDelay` 读取时按当前测试 URL 与组选中的 proxy 取值（`providers/state.dart` L416-L437）。重启后不持久化。

【推断】HmChat 可以用 `Map<string, Map<string, number>>` 复刻；测速并发建议低于 50（移动端 8-16），并在后台/锁屏时暂停批量测速以省电（原 Dart 在后台也会暂停 request/日志，但 healthCheck forwarder 仍有节流）。

### 3.7 错误处理与崩溃重启（可直接移植的策略）

【事实】`ClashLib`（Mobile MethodChannel 路径，`lib.dart`）：

- `_init()` 15 s 超时（L34-L47）；`_maxCrashRetries=5`（L30）；
- `_handleCrashRestart`：60 s 稳定窗口重置计数；超过 5 次放弃并 complete(false)；延迟 `1000 * (1 << (n-1)).clamp(1,16)` ms（L49-L81）；
- `_initInFlight` 防止并发 init（L26-L28、L75-L78）；
- `destroy()` 调 `shutdown`，重置 completer 与 crash 计数（L108-L119）；
- `reconnectIfNeeded()` 每次 resume 重新 init，但受 crash 预算限制（L128-L148）；
- `sendMessage` 对 `invokeAction` 空响应/异常调用 `_failPendingCompleter`，用 typed default 完成，避免 30 s 挂起（L156-L195）；
- `_onMethodCall`：`event` 解析 ActionResult；`crash` 触发重启；`onStarted` 忽略（L83-L103）。

【事实】`ClashHandlerInterface.invoke`（`interface.dart` L136-L179）：

- `id = "<method.name>#<utils.id>"`；
- `callbackCompleterMap[id]` + `callbackDefaultMap[id]`；
- `safeFuture(timeout: ..., onTimeout: ...)`；默认 String→`""`、bool→`false`、Map→`{}`；
- `handleResult`：`message` 完成 true；`getConfig` 完成 `Result`；其他直接完成 `result.data`，**忽略 `code`**（L103-L127）。

【事实】`_setupClashConfig` 失败时抛错，不推进 `lastProfileModified`（`controller.dart` L744-L756）；`handleStart` 若 `startVpn` 返回 0/false 会回滚 startTime 并 stopListener（`state.dart` L236-L254）。

【事实】桌面 `ClashService`（`service.dart`）另有进程重启逻辑：socket EOF / 进程退出 → `_onCoreLost` → 5 次退避；`_stopping` 防止主动 stop 被误判为 crash（L216-L260、L314-L335）。

【推断】HmChat 的 ArkTS 门面应把「RPC 可达」「core 初始化成功」「VPN 已建立」「protect 正常」拆成四个状态；沿用 5 次/60 s/1-16 s 的重启预算，但不要把 `''`/`true`/`0` 直接当作成功。

### 3.8 可直接移植到 ArkTS 的数据结构

```ts
// 仅列字段，不含实现
interface Profile {
  id: string; label?: string; currentGroupName?: string;
  url: string; lastUpdateDate?: number;      // epoch ms
  autoUpdateDurationMs: number; autoUpdate: boolean;
  subscriptionInfo?: { upload: number; download: number; total: number; expire: number };
  selectedMap: Record<string, string>;
  unfoldSet: string[];
  overrideData: { enable: boolean; type: 'added' | 'override'; rules: string[] };
  providerHeaders: Record<string, string>;
}
interface ProxyInfo { name: string; type: string; now?: string; serverDescription?: string; }
interface GroupInfo {
  name: string; type: 'Selector'|'URLTest'|'Fallback'|'LoadBalance'|'Relay';
  all: ProxyInfo[]; now?: string; hidden?: boolean; testUrl?: string; icon?: string;
}
interface DelayInfo { name: string; url: string; value: number; } // -1 失败，0 加载中
type DelayMap = Record<string, Record<string, number>>; // url -> proxy -> delay
```

【事实】这些字段与 `lib/models/profile.dart` L50-L67、`lib/models/common.dart` L250-L273、`lib/models/core.dart` L158-L166 一一对应。

### 3.9 Dart → ArkTS 的算法伪代码

**订阅更新**：

```text
profile = Profile.normal(url)
headers = sendDeviceHeaders ? {x-hwid,x-device-os,x-ver-os,x-device-model} : {}
resp = http.get(url, headers + UA, redirect<=5, timeout 15/60s)
base = json(profile)
base.url = header('flclashx-newdomain') ? replaceHost(url) : url
base.label = header('content-disposition') filename ?? profile.id
base.subscriptionInfo = parse('subscription-userinfo')
base.autoUpdateDuration = hours(header('profile-update-interval')) ?? 1d
base.providerHeaders = collect(announce,support-url,flclashx-*)
if core.validateConfig(bytes) != '' -> throw
write files/profiles/<id>.yaml
profile.lastUpdateDate = now
```

**组派生**：

```text
proxies = core.getProxies()
isGroup(name) = proxies[name].type in {Selector,URLTest,Fallback,LoadBalance,Relay}
groupNames = ['GLOBAL'] + proxies.GLOBAL.all.filter(isGroup)
if globalOverride: append declared proxy-groups not seen, then remaining keys
for name in groupNames:
  g = proxies[name]; g.all = g.all.map(n => proxies[n]).filter(Boolean)
```

**选节点**：

```text
core.changeProxy({group-name, proxy-name})
profile.selectedMap[group] = proxy
if closeConnections: core.closeConnections()
persist profile (debounced)
```

**测速**：

```text
setDelay(url, proxy, 0)
try delay = core.asyncTestDelay({proxy-name,test-url:url,timeout:5000})
catch delay = {value:-1}
setDelay(url, proxy, delay.value)
```

**配置应用**：

```text
raw = core.getConfig(profilePath)   // Go YAML→RawConfig JSON
raw = patch(raw, config, profile)   // 见 §3.3 的 1-14 步
core.setupConfig({config: raw, selected-map: profile.selectedMap, test-url: appSetting.testUrl})
if error != '' -> 失败，不更新 lastProfileModified
```

### 3.10 必须替换的 Flutter/插件依赖

| Flutter/插件 | 在 lib 中的用途 | ArkTS 替代 |
| --- | --- | --- |
| `path_provider` | `getApplicationSupportDirectory`、temp、downloads | `UIAbilityContext.filesDir` / `cacheDir`；VPN 扩展需使用 `base/files` 根 |
| `shared_preferences` | `config`、`clash_config`、`sendDeviceHeaders`、通知去重 | `@ohos.data.preferences`（非敏感）；订阅 URL/DAV 密码改用 Asset |
| `dio` / `http` | 订阅下载、IP 检测、GitHub 更新 | `@kit.NetworkKit` http；或让 core 的 providers 自行拉取 |
| `device_info_plus` / `package_info_plus` | HWID/OS/型号/版本 | `@kit.BasicServicesKit` deviceInfo + `bundleManager`；OHOS 需新增 HWID 策略（隐私需用户同意） |
| `flutter_js`（QuickJS） | `handleEvaluate` 执行 profile 脚本 | MVP 直接移除脚本，仅保留 overrideData；若要保留，需原生 JS 引擎/Web 组件 |
| `webview_flutter` | zashboard 内置 Web UI | ArkUI `Web` 组件（可选）；或外部浏览器 |
| `url_launcher` / `app_links` | 打开链接、深链 | `startAbility` + Want；App Linking |
| `image_picker` / `file_picker` / `mobile_scanner` / `qr_flutter` | 导入文件/扫码/二维码 | MediaLibraryKit、CoreFileKit、Scan Kit；二维码可用 ArkUI 绘制 |
| `archive` | 备份 zip | `@kit.CompressKit` / zlib |
| `crypto` | HWID 哈希、sha256 | `@kit.CryptoArchitectureKit` |
| `freezed` / `json_serializable` | 数据模型 | 显式 ArkTS class/interface（无反射） |
| `flutter_riverpod` | 全局状态 | ArkTS `@State`/`AppStorage`/自定义 store |
| `dynamic_color`、`window_manager`、`tray_manager`、`hotkey_manager`、`win32*` | 桌面/主题 | 丢弃；HmChat 使用 ArkUI 主题与 HDS |
| `intl` / `l10n` | 文案 | ArkTS 资源 `string.json`；不要搬运 85 KB 的生成文件 |
| `path` | 路径拼接 | 字符串/`@ohos.file.fs` |
| `collection` | 深比较/排序 | 普通数组/Map + 手写比较 |
| `connectivity_plus` / `network_info_plus` | 网络状态 | `@kit.NetworkKit` connection |

【推断】订阅 URL 拉取和配置文件生成都可以留在 ArkTS；core 仍负责 YAML→JSON 与配置应用，从而避免在 ArkTS 实现完整 mihomo YAML schema。

---

## 4. 配置、geo 与首启

### 4.1 首启是否内置配置

【事实】没有内置 YAML 配置：

- `assets/` 只有 `data/`、`fonts/`、`images/`，没有默认 profile（资源清单见 §4.3）。
- `Config` 的 `profiles` 默认为 `[]`，`currentProfileId` 为 null（`models/config.dart` L251-L253；`Config` L245-L263）。
- `getSetupParams` 在无当前 profile 时 `patchRawConfig` 返回 `{}`（`state.dart` L468-L471）。
- 首页 `metainfo_widget` 在 `profiles.isEmpty` 时显示「Add Profile」入口（L59-L80）。

【推断】无 profile 时 core 收到 `config:{}`：mihomo `RawConfig` 的零值 `Mode=Global`、无 proxies/rules；`ParseRawConfig` 的 `parseGeneral` 不校验 mode，`parseProxies`/`parseRules` 为空；`executor.ApplyConfig` 仍可能建立空 GLOBAL/DIRECT/REJECT。实际表现需真机确认：可能只能直连/无代理，UI 显示添加订阅。【待确认】空配置是否被 `ParseRawConfig` 接受、是否产生可用 GLOBAL。

【事实】没有订阅时的工作方式：

- 用户必须通过 URL/文件/二维码添加 profile（`add_profile.dart` L17-L56；`controller.dart` L1452-L1541）。
- 添加第一个 profile 会自动设为 `currentProfileId`（`controller.dart` L246-L253）。
- 删除最后一个 profile 时 `updateStatus(false)`（L255-L268），回到无 profile 状态。

### 4.2 homeDir 与文件布局

【事实】`AppPath`（`common/path.dart`）：

- `homeDirPath` = `getApplicationSupportDirectory().path`（L70-L73）；在 Flutter-OHOS 上对应 `.../el2/base/files`（与 `ohos` 扩展 `ClashVpnExtensionAbility.ets` L56-L66 的注释一致）。
- `profilesPath` = `<home>/profiles`（L85-L88）。
- `getProfilePath(id)` = `<home>/profiles/<id>.yaml`（L90-L93）。
- `getProvidersDirPath(id)` = `<home>/profiles/providers/<id>`（L95-L102）。
- `getProvidersFilePath(id,type,url)` = `<home>/profiles/providers/<id>/<type>/<md5(url)>`，type 为 `proxies` 或 `rules`（L104-L117）。
- `sharedPreferencesPath` = `<home>/shared_preferences.json`（L80-L83），用于备份；实际 shared_preferences 插件存储位置由插件决定。
- `lockFilePath` = `<home>/Wormhole.lock`（L75-L78）。
- temp/download 来自 `getTemporaryDirectory`/`getDownloadsDirectory`（L22-L31）。

【事实】core 侧的 home 是 `constant.SetHomeDir(params.HomeDir)`（`hub.go` L99）；`constant/path.go` 的 `Path.homeDir` 同时被加入 `SAFE_PATHS`（`Path.SafePaths()` L78-L80）。所以 ArkTS 的 `files` 根与 profile 文件必须与 core home 一致，否则 `ExternalUI`/provider 路径会被拒绝。

### 4.3 文件与 geo 名称

【事实】`core/constant/path.go` 在 home 根查找：

| 文件 | 常量/行 | 说明 |
| --- | --- | --- |
| `GeoSite.dat` | `GeositeName` L18；`GeoSite()` L222-L233 | 域名规则库 |
| `GeoIP.dat` | `GeoipName` L19；`GeoIP()` L184-L197 | IP 规则库 |
| `ASN.mmdb` | `ASNName` L20；`ASN()` L146-L160 | ASN 库 |
| `geoip.metadb` | `MMDB()` L136-L145（也接受 `Country.mmdb`/`geoip.db`） | MMDB |
| `BundleMRS.7z` | `BundleMRS()` L162-L176 | 可选 bundle |
| `cache.db` | `Cache()` L178-L180 | 内核缓存 |
| `config.yaml` | `configFile: "config.yaml"` L49 | mihomo 默认配置名（本应用通过 Action 传配置，不一定用） |

【事实】Dart 的 `initGeo`（`clash/core.dart` L37-L66）：

1. 确保 home 目录存在；
2. 四个文件名 `mmdbFileName = "geoip.metadb"`、`geoIpFileName = "GeoIP.dat"`、`geoSiteFileName = "GeoSite.dat"`、`asnFileName = "ASN.mmdb"`（`constant.dart` L34-L37）；
3. 逐个检查 `<home>/<name>` 是否存在；不存在则从 `assets/data/<name>` 读取并写入；
4. 任一异常 → `exit(0)`（直接杀应用，不是优雅错误）。

【事实】`assets/data` 文件大小与上一轮相同：`ASN.mmdb` 12,290,045；`GeoIP.dat` 19,131,704；`geoip.metadb` 9,226,542；`GeoSite.dat` 4,202,493（42.8 MB）。HmChat 应迁移到 `rawfile/clash/`，首次复制到 `files/` 根；不要复制 Flutter 资源目录其余 3.3 MB（字体/图标）。

【事实】`patchRawConfig` 会把 `geox-url` 写入配置（默认 MetaCubeX meta-rules-dat，`models/clash_config.dart` L302-L335），并设置 `geodata-loader`（默认 `memconservative`，L496-L498）。`updateGeoData` 动作支持 `MMDB/ASN/GeoIp/GeoSite`（`hub.go` L784-L803），由 `updater.Update*` 下载到 `Path` 对应文件；`geo-auto-update` 默认 false（`config/DefaultRawConfig` L486-L489）。

【推断】如果 geo 文件缺失且 `geo-auto-update=false`，mihomo 的 `component/geodata/init.go` 仍可能在首次加载时尝试下载（`init.go` L95-L109）；无网络时会失败。HmChat 必须先复制 geo 资源，避免首启依赖下载。

### 4.4 默认配置值（可移植）

【事实】`ClashConfig` 默认（`models/clash_config.dart` L468-L506）：

| 字段 | 默认 | 行 |
| --- | --- | --- |
| `mixed-port` | 7890 | L471、L18 |
| `socks-port` / `port` / `redir-port` / `tproxy-port` | 0 | L472-L475 |
| `mode` | rule | L476 |
| `allow-lan` | false | L477 |
| `log-level` | error | L478 |
| `ipv6` | true | L479 |
| `find-process-mode` | always | L480-L485 |
| `keep-alive-interval` | 30 | L486-L488 |
| `unified-delay` | true | L489 |
| `tcp-concurrent` | true | L490 |
| `tun.enable` | true | `Tun` L179 |
| `tun.stack` | mixed | L182 |
| `tun.dns-hijack` | `["any:53"]` | L183 |
| `tun.route-address` | `[]` | L184 |
| `dns.enable` | true | `Dns` L241 |
| `dns.enhanced-mode` | fake-ip | L251-L253 |
| `geodata-loader` | memconservative | L496-L498 |
| `external-controller` | close（UI 默认 127.0.0.1:9090） | L502-L504、`constant.dart` L49 |
| `global-ua` | null → `clash-verge/v2.4.5` | L501、`ua.dart` L54 |

【事实】`VpnProps` 默认（`models/config.dart` L136-L143）：`enable=true`、`systemProxy=false`、`ipv6=true`、`allowBypass=false`、`accessControl` 默认 disabled/rejectSelected/空列表。
【事实】`NetworkProps` 默认（L149-L160）：`systemProxy=false`、`bypassDomain=defaultBypassDomain`（L13-L31）、`routeMode=config`、`autoSetSystemDns=true`。
【事实】`AppSettingProps` 默认（L62-L97）：`testUrl=https://www.gstatic.com/generate_204`、`openLogs=false`、`closeConnections=true`、`crashlytics=true`、`overrideNetworkSettings=false`、`overrideProviderSettings=false` 等。

### 4.5 外部控制器与 zashboard

【事实】`patchRawConfig` 把 `external-controller` 设置为 profile 值或 UI 默认 `127.0.0.1:9090`；`external-ui` 设置为 profile 值或 `<home>/zashboard`（`state.dart` L521-L543）。core `setupConfig` 在 `external-ui` 非空时 `route.SetUIPath`，并 `route.ReCreateServer`（`common.go` L412-L420）。
【事实】`external-controller` 的默认 `127.0.0.1:9090` 是回环 REST API；`secret` 来自 profile（可能为空）。HmChat 若不使用 zashboard，应关闭 external-controller 或设置 secret，并避免无鉴权回环端口。
【事实】zashboard UI 由 Dart 下载到 `<home>/zashboard`（`state.dart` L534-L542）；Flutter 用 WebView 打开（`webview_flutter`）。ArkTS 可改用 ArkUI `Web` 或外部浏览器；这是可选功能。

### 4.6 脚本与规则覆盖

【事实】`scriptProps.currentScript` 非空时，`patchRawConfig` 调用 `handleEvaluate`，用 `flutter_js` 的 QuickJS 执行 `main(config)`（`state.dart` L779-L810）。`scriptTemplate` 在 `constant.dart` L102-L105。
【事实】没有脚本时，`OverrideData` 才会应用：`override` 替换规则，`added` 前置追加（`state.dart` L749-L763）。
【推断】HmChat MVP 可只保留 `overrideData`，移除 `flutter_js`；若用户依赖脚本，需要原生 QuickJS 或让 core 执行脚本（core 目前不执行 JS）。

---

## 5. 本地存储与安全

### 5.1 shared_preferences 键

【事实】`Config` 整体以 JSON 存在 `config` 键；`clash_config` 是旧版迁移键：

| 键 | 类型 | 写入/读取 | 内容 |
| --- | --- | --- | --- |
| `config` | String | `preferences.saveConfig`（`common/preferences.dart` L53-L59） | 整个 `Config` JSON：profiles（含 `url`）、`dav`（含密码）、主题、网络、VPN、脚本、代理样式、ClashConfig 等 |
| `clash_config` | String | `getClashConfig`/`clearClashConfig`（L27-L38、L62-L65） | 旧版独立 ClashConfig JSON；启动时 `migrateOldData` 合并进 Config 后删除（`state.dart` L383-L391） |
| `sendDeviceHeaders` | bool | `prefs.getBool(...) ?? true`（`controller.dart` L438-L439、L1462-L1463、L1496-L1497） | 订阅请求是否发送 HWID/OS 头 |
| `subscription_notified_<profileId>_<threshold>` | int | `SubscriptionNotificationService` L77-L132 | 已通知的订阅到期阈值，避免重复 |
| `macos_origin_dns` | StringList | `system.dart` L206-L227 | 仅 macOS DNS 恢复；OHOS 不使用 |

【事实】`shared_preferences` 是明文键值存储（插件实现决定文件位置；`appPath.sharedPreferencesPath` 指向 `<home>/shared_preferences.json`，`path.dart` L80-L83，用于备份/清理）。`Config` 的 `dav` 字段包含 `uri/user/password`（`models/common.dart` L169-L179；`models/config.dart` L255），会随 `config` 一起明文保存。

### 5.2 订阅 URL、凭据与 profile 文件

【事实】

- `Profile.url` 是明文订阅 URL（`profile.dart` L55）；`Config` JSON 序列化包含 `profiles` 全量（`preferences.dart` L57）。
- `normalizeUrlCredentials` 只把 userinfo 中的 `@` 编码为 `%40`，不隐藏用户名/密码（`common/string.dart` L11-L19）。
- profile YAML 明文：`<home>/profiles/<id>.yaml`（`path.dart` L90-L93）；订阅内容（节点密码、UUID、订阅服务器）都在其中。
- provider 文件：`<home>/profiles/providers/<id>/proxies|rules/<md5(url)>`（L104-L117），无扩展名；内容由 core 拉取/写入。
- `_diag_getconfig.json` 与 `_diag_setup.json`：`state.dart` L767-L773 与 `controller.dart` L759-L767 会把完整 `RawConfig`/`SetupParams` 写到 home；包含节点、规则、provider URL/路径，**不得进入公开 artifacts**。
- 日志：`FileLogger` 写到 `<home>/logs/Wormhole_YYYY-MM-DD.log`（`common/file_logger.dart` L42-L58），10 MB/7 天轮转（L18-L19）；`ClashManager.onLog` 把 core 日志写入该文件（`manager/clash_manager.dart` L82-L93）。
- 订阅 URL 也可能留在 `fileLogger`/hilog/调试输出中；原代码没有统一脱敏。

### 5.3 OHOS 设备头与 HWID

【事实】`DeviceInfoService` 没有 OHOS 分支（`device_info_service.dart` L71-L109、L134-L174）：`Platform.isAndroid` 在 Flutter-OHOS 上为 false，`isOhos` 也没有进入 `_getPlatformDeviceId`，因此 `hwid` 为 null，`os/osVersion/model` 也为 null；只有 `appVersion` 来自 `package_info_plus_ohos`。实际订阅请求只稳定携带 `User-Agent` 与 `x-hwid` 缺失。

【推断】依赖 HWID 的面板可能：
- 返回 `x-hwid-not-supported: true`，或
- 返回 `x-hwid-max-devices-reached: true`，或
- 返回不同/精简配置。
HmChat 若要支持 HWID，需明确隐私政策与用户同意，使用 OHOS 稳定设备标识（如系统提供的开发者可用标识）并做不可逆哈希；不能直接沿用 Android `ANDROID_ID` 语义。

### 5.4 HmChat 的存储改造建议

【建议】不要把 FlClashX 的 `Config` 整体照搬进 Preferences：

| 数据 | FlClashX | HmChat 建议 |
| --- | --- | --- |
| 订阅 URL（可能含 user:pass） | `Config.profiles[].url` 明文 Preferences | `@ohos.security.asset`（别名 + 密文）；Preferences 只存 `profileId`/`label`/元数据 |
| DAV 密码 | `Config.dav.password` 明文 Preferences | Asset；Preferences 只存 URI/用户名 |
| profile YAML（节点密码） | `files/profiles/<id>.yaml` 明文 | 应用沙箱文件（`filesDir/clash/profiles`），限制权限；不要放进公开备份 |
| provider 文件 | `files/profiles/providers/...` | 同上；路径与 core home 一致 |
| 非敏感偏好（主题、语言、测试 URL） | Preferences | `@ohos.data.preferences` |
| HWID/设备标识 | 内存缓存、请求头发送 | 默认关闭；用户明确开启后再计算/发送，且不持久化原始标识 |
| 调试 dump | `_diag_*.json` | 发布版禁用；开发版放 ignored 目录并脱敏 |
| 日志 | `home/logs/*.log` | 默认关闭/脱敏；限制大小；不加入公开 artifacts |

【事实】`Profile.update` 的 `shouldSendHeaders` 可由用户关闭（`sendDeviceHeaders` false），但默认 true；HmChat 应默认关闭或首次明确询问。

### 5.5 安全风险（core/lib 侧）

【事实/风险】

1. `getConfig` 接受任意路径字符串，core `handleGetConfig` 只 `os.Stat/ReadFile`，没有 `Path.IsSafePath` 校验（`hub.go` L917-L927、`common.go` L297-L307）。在无鉴权 RPC 前提下，本机同 sandbox 的攻击者可读取应用可读的任意 YAML/文本并得到解析后的 RawConfig；应只允许 `<home>/profiles/*.yaml` 的规范化路径。
2. `external-controller` 默认 `127.0.0.1:9090`，`secret` 常为空（`state.dart` L521-L547）；同一设备上的其他应用可访问 REST API（若系统允许回环）。建议关闭或用随机 secret + 仅绑定必要时机。
3. `getProxies`/`getConnections` 返回节点名、域名、连接元数据；`event` 推送同类数据；日志/dump 可能含订阅 URL。无鉴权 RPC 会把它们暴露给任何本地连接者（上一份文档 §9 已详述）。
4. `Profile.url`/`DAV.password` 明文 Preferences；`shared_preferences` 备份（`sharedPreferencesPath`）若被导出会泄露。
5. `core.log`/`Wormhole_*.log` 可能含节点/域名；原 `FileLogger` 没有脱敏。
6. `scriptProps` 执行用户/订阅提供的 JS（QuickJS），拥有配置修改能力；HmChat 若保留脚本需沙箱/超时/权限限制，MVP 建议移除。
7. `sideLoadExternalProvider` 接受任意 provider 内容；`updateExternalProvider` 可触发网络更新；无鉴权 RPC 可被滥用。

【建议】把上一份文档 §9.9 的鉴权/端口/帧上限/停止收敛措施一并应用；本文件补充：`getConfig` 路径白名单、`external-controller` 默认关闭、profile/DAV 密文存储、调试 dump 禁用、日志脱敏。

---

## 6. 许可证与可重建性

### 6.1 已确认的许可证事实

【事实】

- 根 `LICENSE`：GNU GPL v3 全文，674 行；文件内没有项目版权人/年份行，只有 FSF 的 GPL 样板。
- `README.md` 标题为 FlClashX，徽章指向 `pluralplay/FlClashX`，描述为「Форк ... FlClash на основе ClashMeta」；`pubspec.yaml` L2 描述为「FlClash fork」。
- 本工作树 git remote 为 `https://github.com/gscsdx/WFlClashX.git`；最早提交作者 `chen08209 <chen08209@gmail.com>`（2024-04-30，FlClash 初始提交）；HEAD `85b903ad13ea...` 提交说明为 Android 编译检查工作流。
- `core/third_party/sing-tun/LICENSE`：GPL-3.0-or-later，`Copyright (C) 2022 by nekohasekai <contact-sagernet@sekai.icu>`。
- 本机 Go module cache 中 `github.com/metacubex/mihomo@v1.19.28/LICENSE` 是 GPL v3 全文；`constant.Version = "1.10.0"`（`constant/version.go`）。
- `core/` 自有 `.go` 文件未发现 `Copyright`/`SPDX` 头；`third_party/sing-tun` 文件保留上游 GPL 头。
- `ohos/entry/oh-package.json5`（上一轮）声明 `"license": "GPL-3.0"`。

【结论】FlClashX / mihomo / sing-tun 均为 GPLv3 家族；HmChat 是 GPL-3.0-or-later，许可证方向兼容。**兼容不等于合规**：必须保留上游版权/许可、标注修改、提供对应源码。

### 6.2 go.mod 版本与替换

【事实】`core/go.mod`：

```text
module core
go 1.20
require github.com/metacubex/mihomo v1.19.28
require golang.org/x/sync v0.11.0
replace github.com/metacubex/utls => github.com/metacubex/utls v0.0.0-20260715025833-a77524af3a17
replace github.com/metacubex/sing-tun => ./third_party/sing-tun
```

- `sing-tun` 的 `require` 版本是 `v0.4.21`（`go.mod` L92），但被本地 `replace` 覆盖（L150-L152）。
- `utls` 被替换为较新的伪版本，以支持新的指纹（L12-L14 注释）。
- `go.sum` 31,545 bytes，锁定依赖校验；但 `third_party/sing-tun` 无 `git` 跟踪，`build_ohos.sh` 也无跟踪。
- `go 1.20` 是语言版本；实际二进制元数据是 Go 1.24.5（见 §6.6）。

### 6.3 third_party/sing-tun 的真实修改

【事实】以本机 module cache 的 `github.com/metacubex/sing-tun@v0.4.21` 为基准，`git diff --no-index --stat` 只显示 5 个文件：

| 文件 | 变更 | 作用 |
| --- | --- | --- |
| `debug_hilog.go` | 新增 13 行 | `hlog(format,...any)` 格式化后调 `hlogRaw` |
| `debug_hilog_ohos.go` | 新增 32 行 | `//go:build openharmony && cgo`；`#cgo LDFLAGS: -lhilog_ndk.z`；调用 `OH_LOG_Print` |
| `debug_hilog_stub.go` | 新增 6 行 | 非 OHOS 的 no-op |
| `tun_linux.go` | +9 行 | `NativeTun.pumpStop chan struct{}`；`New` 初始化；`Close` 关闭 |
| `tun_linux_gvisor.go` | +211/-9 | 用 `channel.New(1024, mtu, "")` + `pumpChannelEndpoint` + `rawRead/rawWrite`（`unix.Read/Write + unix.Poll`）替换 `fdbased.New`；原因：OHOS 对 VpnService fd 的 `fstat()` 返回 EACCES；`ReadContext` 区分队列空与关闭；附 `ipv4ChecksumValid` 诊断 |

【事实】修改的根因在 `tun_linux_gvisor.go` 注释：gVisor `fdbased` 初始化调用 `isSocketFD(fd)` → `unix.Fstat(fd)`，OHOS 返回 EACCES(13)；`dup()` 同样失败；因此改用纯用户态 channel endpoint + 原生读写/Poll。`tun_linux.go` 的 `pumpStop` 只用于停止 pump goroutine，避免关闭后泄漏/阻塞。

【推断】这套补丁是 OHOS 功能正确性的关键，不能只替换 `libclash_core.so` 而不带 `third_party` 源码；HmChat 重建时必须保留这 5 个文件及 `go.mod` 的 `replace`。

### 6.4 `core/tun/tun.go` 的 OHOS 强制项

【事实】

- `Start` 无条件 `stack := constant.TunGvisor`（L65），忽略 `cfg.Stack`；原因注释 L58-L64：VpnExtension fd 没有内核 TCP 拦截，`system` 会静默丢 TCP。
- `mtu := cfg.MTU`，`0` 或 `>1500` 时夹紧到 `1420`（L71-L74）。
- `LC.Tun` 设置 `GSO=false`、`RecvMsgX=false`、`SendMsgX=false`（L84-L88）。
- 日志级别为 `SILENT` 时提升到 `INFO`（L40-L42），便于排查。
- `DNSHijack` 为空时使用 `state.GetDnsServerAddress():53`（L51-L56）。

【事实】`handleStartTun`（`lib_mobile.go` L129-L199）在 `t.Start` 前设置 `runTime`；失败路径不清 `runTime`；成功设 `tunUp=true`。`handleStartTun` 还自动 `handleStartLog()`（L158-L162），因为 Dart 在 OHOS 不一定先 `startLog`。

### 6.5 `build_ohos.sh` 的命令与环境

【事实】`core/build_ohos.sh`（untracked）：

| 项 | 值/行为 | 行 |
| --- | --- | --- |
| 必需环境 | `OHOS_GO`（Go 工具链）、`OHOS_NDK`（native/ 目录） | L36-L37 |
| 输出 | `OUT=${OUT:-$HERE/../ohos/entry/libs/arm64-v8a}` | L34 |
| 工具链检查 | `go tool dist list` 必须含 `openharmony/arm64` | L66-L69 |
| Windows | 用 `cygpath -w` 转 Windows 路径；直接调 `clang.exe`；flags `-target aarch64-linux-ohos --sysroot=... -D__MUSL__` | L43-L64 |
| 构建 env | `GOROOT`、`GOTOOLCHAIN=local`、`GOOS=openharmony`、`GOARCH=arm64`、`CGO_ENABLED=1`、`CC=<clang + flags>`、`GOPROXY` 默认 `https://goproxy.cn,direct` | L78-L87 |
| 构建命令 | `go build -trimpath -tags ${TAGS:-with_gvisor} -ldflags="-s -w -extldflags=-Wl,-soname,libclash_core.so" -buildmode=c-shared -o "$OUT/libclash_core.so" .` | L88-L94 |

【事实】脚本**没有**：
- `-X github.com/metacubex/mihomo/constant.Version=...`；
- `-buildvcs=false`（因此嵌入 `vcs.modified=true`）；
- 固定 Go 工具链版本（只检查 `openharmony/arm64`）；
- 固定 `OHOS_NDK`/SDK 版本；
- 生成 SBOM 或校验 `third_party` 差异。

【事实】`setup.dart` 的正式 core 构建会加 `-ldflags=-w -s -X github.com/metacubex/mihomo/constant.Version=$coreVersion`（L296），并从 `core/go.mod` 提取 mihomo 版本（L216-L229）；`build_ohos.sh` 没有同步这一步。

### 6.6 二进制元数据与版本不一致

【事实】`libclash_core.so`（完整仓库与旧快照相同）：

| 项 | 值 |
| --- | --- |
| 大小 | 51,155,984 bytes |
| SHA-256 | `246e77dcaa26fca25b25ce4fb8386f2d5e36f921cd9f8c88009cd0dc9c4eb9f6` |
| 主模块 | `core v0.0.0-20261031191723-85b903ad13ea+dirty` |
| vcs | `85b903ad13ea3fcb67142dae521e2479ff8cdbe0`，2026-10-31T19:17:23Z，`modified=true` |
| Go | 1.24.5（二进制内字符串） |
| 目标 | `GOOS=openharmony`、`GOARCH=arm64`、`GOARM64=v8.0`、`CGO_ENABLED=1`、`-tags=with_gvisor`、`-trimpath=true` |
| 依赖 | 125 条 `dep`；mihomo v1.19.28；sing-tun v0.4.21 → 本地 `third_party/sing-tun (devel)`；utls 替换 |

【事实】二进制内出现 `1.10.0`（mihomo `constant.Version` 默认值），与 Dart `lib/core_version.dart` 的 `v1.19.28` 不一致。由于 `build_ohos.sh` 没有 `-X`，`getCoreVersion` 很可能返回 `1.10.0`；`setup.dart` 构建的 core 才会返回 `v1.19.28`。这不是功能错误，但会让 UI/UA/支持信息显示错误版本。

【事实】`OHOS-DELIVERY.md` 记录的交付版本为 0.4.2（versionCode 2026071801），而 `pubspec.yaml` 当前是 `0.4.3+2026110401`；文档与源码版本不同步。

### 6.7 OHOS-DELIVERY 的构建/验证步骤

【事实】`OHOS-DELIVERY.md`：

- 交付日期/版本：2026-11-03，0.4.2，包名 `com.wormhole.app`；品牌从 FlClashX 改为 Wormhole。
- 构建：`rebuild_hvigor.bat` 仅 hvigor 路径（复用 `flutter_assets`）；Flutter 全量链因 pub cache 跨盘问题未完全跑通（§5.3、§7.3）。
- 只改 Go core：`cd core`，`OHOS_GO=... OHOS_NDK=... bash build_ohos.sh`；然后删除 `ohos/entry/build/default/intermediates/{stripped_native_libs,libs}` 再打包（§5.1）。
- 安装/启动：`hdc install -r ...`、`aa force-stop`/`aa start`（§5.3）。
- 健康检查：`ifconfig vpn-tun`、`hilog` 关键字、`ps` 查主进程 + `:vpn` 扩展进程（§5.4）。
- 已知限制：用户关闭通知权限导致扩展普通通知失败（1600004）；保活依赖 60 s 实况窗 + 真实流量；AppGallery ACL/上架未完成；当前 debug 签名（§7）。
- 文档包含一次真实节点的名称与浏览器验证记录；本文不复制这些内容（避免泄露订阅/节点信息）。

【事实】OHOS 构建/运行还修改了 `ohos/` 下的 KeepAlive、VPN 扩展、Channel、module.json5、CMake 等（上一份文档已详述）；它们与本轮 core/lib 的 Action 协议共同构成完整链路。

### 6.8 GPL 对应源码清单

【事实/建议】若 HmChat 分发含 `libclash_core.so` 的 HAP，至少需要提供：

1. **FlClashX 完整对应源码**：`lib/`（Dart）、`core/`（Go，含未跟踪的 `build_ohos.sh`、`dns_*.go`、`third_party/sing-tun`）、`ohos/`（ArkTS/CMake）、`pubspec.yaml`/`pubspec.lock`、`setup.dart`、`go.mod`/`go.sum`、`assets/`、`LICENSE`。
2. **mihomo v1.19.28 源码**：`github.com/metacubex/mihomo` 对应模块版本/commit；以及 `go.mod` 中 125 个依赖的对应源码/许可证。
3. **sing-tun v0.4.21 + 本地 5 文件 diff**：完整 vendored 目录与修改说明。
4. **utls 替换版本**：`v0.0.0-20260715025833-a77524af3a17`。
5. **构建脚本与工具链**：`build_ohos.sh`、Go 1.24.5/OHOS Go 工具链、`OHOS_NDK` 版本、CGO flags、`GOPROXY` 设置；DevEco SDK 的 libc++ 通知（HmChat 已有 LLVM 通知）。
6. **二进制指纹**：`libclash_core.so` SHA-256、大小、`go version -m` 输出、vcs revision/modified。
7. **第三方数据/资产**：geo 四件套（MetaCubeX meta-rules-dat）、字体（JetBrains Mono/Twemoji）、图标/头像；各自许可证需单独核对。
8. **修改声明**：`core/tun/tun.go`、`third_party/sing-tun`、`core/platform`、`core/lib_mobile.go` 的 OHOS 修改；以及 FlClashX → Wormhole 品牌/包名变更。

【事实】当前工作树的问题使上述清单不能只靠 `git archive HEAD` 获得：

- HEAD 不含 `core/build_ohos.sh`、`core/dns_android.go`、`core/dns_openharmony.go`、`core/third_party/`（`git status` 显示 `??`）。
- `core/go.mod` 的 `replace sing-tun` 是未提交修改。
- `core/lib_mobile.go` 是未提交的重命名+修改；`core/tun/tun.go`、`core/platform/*`、`core/android_bride.go` 也是未提交修改。
- 二进制 `vcs.modified=true`，说明构建时工作树已脏。

【结论】`source-refs/FlClashX` 当前工作树具备重建所需源码；但 **HEAD 不可重建**，且 `build_ohos.sh` 缺少版本 `-X`。可重建性等级：【事实】工作树+正确工具链可重建同 ABI；【推断】不能保证字节一致；【待确认】Go 工具链精确补丁版本/NDK 版本未记录。

【建议 P0】

1. 把 `core/build_ohos.sh`、`dns_*.go`、`third_party/sing-tun`、`core/go.mod` 修改提交到干净 commit；或在发布源码包中附带 `git diff` 与未跟踪文件清单。
2. 在 `build_ohos.sh` 增加 `-X github.com/metacubex/mihomo/constant.Version=v1.19.28`（或从 `go.mod` 提取），使 `getCoreVersion` 与 Dart/UA 一致。
3. 固定 Go 工具链版本（二进制显示 1.24.5）与 `OHOS_NDK`/SDK 版本；记录 `go env`、`CC`、`CGO_*`。
4. 生成 `go version -m`/SBOM，并把 125 个依赖的许可证文本纳入 `rawfile/licenses/clash/`。
5. 保存 `libclash_core.so` SHA-256 与 `libclash_bridge.so` SHA-256；发布前跑 `verify-clash-licenses`。
6. 在 `THIRD_PARTY_NOTICES.md` 增加 FlClashX/mihomo/sing-tun/Go 依赖/geo 数据条目；不得只写 GPL 而不提供源码。

---

## 7. 与 `ohos/` 快照的差异

### 7.1 关键文件哈希对比

【事实】`source-refs/FlClashX/ohos/` 与 `source-refs/FlClashX-ohos/` 的以下文件 SHA-256 **完全相同**：

```text
entry/src/main/module.json5
entry/src/main/ets/services/CoreBridge.ets
entry/src/main/ets/services/ClashRpcServer.ets
entry/src/main/ets/services/ClashRpcClient.ets
entry/src/main/ets/services/RpcProtocol.ets
entry/src/main/ets/services/ClashServiceChannel.ets
entry/src/main/ets/services/KeepAliveManager.ets
entry/src/main/ets/vpn/ClashVpnExtensionAbility.ets
entry/src/main/cpp/clash_bridge.cpp
entry/src/main/cpp/CMakeLists.txt
entry/src/main/cpp/types/libclash_bridge/index.d.ts
entry/oh-package.json5
oh-package.json5
entry/build-profile.json5
build-profile.json5
README.md
```

【事实】两份 `ohos/entry/libs/arm64-v8a/libclash_core.so` 也完全相同：

```text
51,155,984 bytes
SHA-256 246e77dcaa26fca25b25ce4fb8386f2d5e36f921cd9f8c88009cd0dc9c4eb9f6
```

【事实】目录差异：

| 项 | `source-refs/FlClashX`（完整） | `source-refs/FlClashX-ohos`（旧快照） |
| --- | --- | --- |
| `lib/` | 存在（Dart UI/业务） | 不存在 |
| `core/` | 存在（Go 源码 + third_party + build 脚本） | 不存在 |
| `pubspec.yaml` / `.lock` | 存在 | 不存在 |
| `LICENSE` / `OHOS-DELIVERY.md` | 存在 | 不存在 |
| `.git` | 存在（HEAD 85b903ad） | 不存在 |
| `ohos/` | 与旧快照关键文件相同 | 同一份 `ohos/` 源码 |
| 构建产物 | `ohos/entry/build`、`.cxx` 等 | 额外带有 `.cxx`、`build`、`Crash_*.dmp` 等 |
| `ohos/har` | 存在 | 存在 |

### 7.2 以哪份为准

【事实】完整仓库是权威来源：它包含 `lib/`、`core/`、`LICENSE`、`OHOS-DELIVERY.md` 与 git 历史；旧快照只是 `ohos/` 子工程 + 构建产物，且缺少 `lib/core/pubspec`。

【事实】上一份 `docs/integration/flclash-baseline.md` 中关于 ArkTS/CMake/`ohos` 的事实仍然有效（关键文件哈希一致）；但它的 §8.4/§8.5 对 Action 词表的猜测已被本文件 §2 修正。

【建议】
- 后续源码工作以 `source-refs/FlClashX` 工作树为准；不要从旧快照复制 `.cxx`/`build`/`Crash`/`oh_modules`。
- 复现构建基线时，记录工作树未跟踪文件（`core/build_ohos.sh`、`dns_*.go`、`third_party/`）的哈希，而不是只记 HEAD。
- 若只需要预编译产物，旧快照的 `.so` 与完整仓库一致；但仍应使用完整仓库的源码做 GPL 归档。

---

## 8. 剩余待确认清单

### 8.1 本轮已关闭的上一份待确认项

| 上一份问题 | 本轮结论 | 依据 |
| --- | --- | --- |
| Action 方法完整词表 / params / data | 已给出完整表；`getGroups/getRules/setProfile/...` 不存在 | §2.2、§2.8 |
| `quickStart` 三个 JSON schema | `InitParams` / `SetupParams` / `CoreState` | §2.4 |
| `setupConfig` 路径还是 YAML | 是 `SetupParams` JSON（`config` 为 RawConfig） | §2.5、§2.6 |
| `initClashSync(29)` 含义 | `version<29` 才查 procfs UID；29 关闭 per-app UID | §2.5 |
| `AndroidVpnOptions` 字段/默认值 | 已给精确表；`port`/`bypassDomain` OHOS 未用 | §2.7 |
| 订阅/节点/测速实现 | 已给算法/数据结构/错误策略 | §3 |
| 本地存储键与明文 URL | `config` 键整包 JSON；profile URL/DAV 密码明文 | §5 |
| 首启是否内置配置 | 无内置 YAML；空 profiles；首页 Add Profile | §4.1 |
| geo 部署 | `initGeo` 复制四件套到 home 根；core 固定文件名 | §4.2-4.3 |
| 许可证/构建 | GPLv3；go.mod/third_party/build 脚本已查 | §6 |
| 两份 ohos 差异 | 关键文件与 `.so` 哈希一致；完整仓库为准 | §7 |

### 8.2 仍需真机/真实订阅/上游确认

【说明】本轮 `core/` 与 `lib/` 的结论不依赖 TDLib schema；TDLib 只需验证与 Clash 原生库/扩展进程的共存（Q16），不是本文件协议表的前置条件。

| # | 问题 | 为什么仍需确认 | 需要的证据 |
| --- | --- | --- | --- |
| Q1 | 空 profile 时 `config:{}` 是否被 `ParseRawConfig` 接受、core 是否提供可用 GLOBAL/DIRECT/REJECT | 源码显示会进入空解析，但未在设备上验证 | 真机首启、无订阅时 `getConfig`/`getProxies`/日志 |
| Q2 | `getCoreVersion` 实际返回 `1.10.0` 还是 `v1.19.28` | `build_ohos.sh` 缺 `-X`，二进制内两者都有痕迹 | 真机调用 Action 或在 `.so` 上确认；重建时加 `-X` |
| Q3 | OHOS HWID/OS/model 是否为空、订阅面板是否拒绝 | Dart 无 OHOS 分支 | 真实订阅（用户授权）响应头/错误；设备信息实现 |
| Q4 | `event` 推送在 MethodChannel 边界是 String 还是 Map | `ClashLib._onMethodCall` 按 String 解析，链路可能传 object | 真机日志/事件；必要处 `JSON.stringify` |
| Q5 | `getConfig` 任意路径读取的沙箱范围 | core 无 `IsSafePath` | 安全测试：传不同路径，确认可读边界 |
| Q6 | mihomo v1.19.28 `getProxies` 组对象的精确字段/类型名 | 依赖具体版本 JSON；Dart 按 `Selector/URLTest/...` 过滤 | 真实 core 输出（无节点名脱敏）与 `Group.fromJson` |
| Q7 | provider 文件 path/MD5 与 core 实际写入位置 | `path.dart` 规则明确，但 core 侧 `SideUpdate` 可能另存 | 真机查看 `<home>/profiles/providers` |
| Q8 | `setupConfig` 大配置/`rule` 键/`geox-url` 在 OHOS 的实际行为 | 需真实 profile | 真机 apply + 日志；`_diag_setup.json`（脱敏） |
| Q9 | `scriptProps`/`flutter_js` 在 OHOS 是否可用 | Flutter 插件风险 | 真机执行脚本；或决定移除 |
| Q10 | `healthCheck`/`asyncTestDelay` 在 OHOS 的并发/超时/延迟 | core 50 并发、Dart 100 批、6 s 超时 | 真实节点测速；后台/锁屏节流 |
| Q11 | zashboard/external-controller 在 OHOS 的 WebView/端口/secret | Flutter WebView 与回环 REST | 真机打开 zashboard；端口/鉴权测试 |
| Q12 | FlClashX 上游精确来源/版权人 | LICENSE 无项目版权行；repo 为 fork | 上游仓库/作者确认；`git log` 与发布声明 |
| Q13 | 125 Go 依赖的许可证清单 | 只确认 mihomo/sing-tun 主许可 | `go version -m` + 各模块 LICENSE |
| Q14 | geo/字体/图标资产许可证 | 未逐项核对 | 上游 meta-rules-dat、字体、图片许可 |
| Q15 | GPL 对应源码包与构建可复现 | 工作树脏、untracked、工具链未固定 | 干净 commit/源码包 + `go env` + SHA |
| Q16 | 与 TDLib 共存的真实设备行为 | 本轮只读 core/lib；未运行 | 独立 VPN 扩展进程、内存/符号/崩溃隔离真机测试 |
| Q17 | ACL/AppGallery 上架 | SDK 26 与旧文档冲突 | 用户签名 profile、华为当前 VPN 政策 |
| Q18 | `runtime.GOOS` 在 OHOS 工具链的实际值 | 影响 `common.go` 的 Android 分支与内置 TUN listener | 构建日志/设备日志；`go env GOOS` 与运行时打印 |

### 8.3 推荐下一步

1. **P0 合规/可复现**：提交 untracked core 文件，补 `-X constant.Version`，记录工具链，生成 SBOM/源码包（§6.8）。
2. **P0 协议冻结**：以本文件 §2 的 Action 表为 HmChat `ClashRpcProtocol` 的唯一规格；不要沿用上一份的猜测词表。
3. **P1 订阅/节点 MVP**：先实现 `getConfig → patch JSON → setupConfig` 往返 + `getProxies` 组派生 + `changeProxy` + `asyncTestDelay`；存储改用 Asset/沙箱。
4. **P1 安全**：RPC 鉴权/端口/帧上限（上一份 §9.9）+ `getConfig` 路径白名单 + external-controller 关闭/secret。
5. **P2 UI**：按 HmChat HDS/ArkUI 规范重做，不复用 Flutter 页面；订阅/节点/测速只移植数据与动作，不移植 Widget。
6. **验收**：先编译/真实设备，再真实订阅（用户授权），最后 GPL/隐私/上架检查；分别记录「源码/编译/设备/服务端」证据。

---

## 附录 A：证据索引

| 主题 | 文件 | 行号 |
| --- | --- | --- |
| Action/ActionResult | `core/action.go` | L10-L39 |
| dispatch 全表 | `core/action.go` | L41-L278 |
| Init/Setup/Update/ChangeProxy/TestDelay schema | `core/constant.go` | L15-L59 |
| 方法常量 | `core/constant.go` | L71-L113 |
| Message 类型 | `core/constant.go` | L117-L135 |
| `initClash`/setup/apply | `core/hub.go` | L77-L198、L1031-L1044 |
| `getProxies`/changeProxy | `core/hub.go` | L543-L602 |
| 流量/延迟/连接 | `core/hub.go` | L604-L744 |
| providers/geo/logs | `core/hub.go` | L746-L886 |
| getConfig/healthCheck/healthProbe | `core/hub.go` | L917-L1015 |
| `setupConfig` 细节 | `core/common.go` | L384-L438 |
| TUN / gVisor / MTU | `core/tun/tun.go` | L28-L103 |
| Android/OHOS mobile 桥 | `core/lib_mobile.go` | L129-L413 |
| 回调注册/事件 | `core/android_bride.go` | L62-L194 |
| AndroidVpnOptions | `core/state/state.go` | L5-L59 |
| Action 包装/Completer | `lib/clash/interface.dart` | L95-L416 |
| MethodChannel | `lib/clash/lib.dart` | L15-L381 |
| 高层 core API | `lib/clash/core.dart` | L16-L316 |
| 组派生 | `lib/clash/core.dart` | L100-L147 |
| 消息分发 | `lib/clash/message.dart` | L8-L70 |
| 配置生成 | `lib/state.dart` | L394-L810 |
| 订阅更新/删除/选节点 | `lib/controller.dart` | L246-L269、L433-L496、L830-L999、L1452-L1541、L1764-L1799 |
| init/apply/crash | `lib/controller.dart` | L1244-L1370 |
| Profile 模型/更新 | `lib/models/profile.dart` | L20-L265 |
| Config/VpnProps 默认 | `lib/models/config.dart` | L13-L160、L245-L263 |
| ClashConfig/Tun/Dns/Geo | `lib/models/clash_config.dart` | L106-L506 |
| Proxy/Group/Connection | `lib/models/common.dart` | L41-L319 |
| 路径/存储 | `lib/common/path.dart` | L70-L117 |
| Preferences | `lib/common/preferences.dart` | L27-L70 |
| 订阅 HTTP | `lib/common/request.dart` | L12-L99 |
| 设备信息 | `lib/utils/device_info_service.dart` | L71-L174 |
| UA | `lib/common/ua.dart` | L46-L120 |
| 日志 | `lib/common/file_logger.dart` | L42-L58 |
| 订阅到期通知 | `lib/services/subscription_notification_service.dart` | L13-L28 |
| go.mod | `core/go.mod` | L1-L152 |
| build_ohos | `core/build_ohos.sh` | L1-L102 |
| 交付说明 | `OHOS-DELIVERY.md` | L1-L181 |
| LICENSE | `LICENSE` | 674 行全文 |
| sing-tun 许可 | `core/third_party/sing-tun/LICENSE` | 全文 |
| sing-tun 补丁 | `core/third_party/sing-tun/tun_linux_gvisor.go`、`tun_linux.go`、`debug_hilog*.go` | 见 §6.3 |

## 附录 B：文件/指纹清单

【事实】完整仓库 `core/` 自有 Go 文件约 20 个（不含 third_party），`lib/` 约 200 个 Dart 文件（含生成文件）。关键指纹：

| 项 | 值 |
| --- | --- |
| HEAD | `85b903ad13ea3fcb67142dae521e2479ff8cdbe0`（2026-11-01） |
| 工作树 | 167 files changed，`core` 多个修改/未跟踪 |
| `libclash_core.so` | 51,155,984 bytes；SHA-256 `246e77dcaa26fca25b25ce4fb8386f2d5e36f921cd9f8c88009cd0dc9c4eb9f6` |
| 主模块 | `core v0.0.0-20261031191723-85b903ad13ea+dirty` |
| Go | 1.24.5；`GOOS=openharmony`、`GOARCH=arm64`、`GOARM64=v8.0`、`with_gvisor` |
| mihomo | `v1.19.28` |
| sing-tun | `v0.4.21` + 本地 5 文件 diff |
| utls | `v0.0.0-20260715025833-a77524af3a17` |
| geo 资产 | 42.8 MB / 4 文件（§4.3） |
| ohos 快照 | 16 个关键文件哈希与完整仓库一致 |

## 附录 C：本勘察边界

【事实】本文没有：

- 构建、安装、运行设备命令或修改签名；
- 输出证书、密码、profile、密钥、真实订阅链接、真实节点名、真实账号或消息内容；
- 修改 `source-refs/FlClashX/` 下任何文件。

【事实】本文只写入了 `docs/integration/flclash-core-lib-baseline.md`。

【待确认】所有涉及真实设备、真实订阅、HWID 面板行为、TDLib 共存、GPL 发布、AppGallery 审核的结论，仍需后续真机/发布流程验证。