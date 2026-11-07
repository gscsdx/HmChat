# HmChat 基线勘察（面向 mihomo / 代理能力融合）

> 勘察日期：2026-11-05。范围：只读工程根目录的源码与配置。
> 目的：为把 FlClashX `ohos/` 的 mihomo（Go）代理能力融合进本应用提供可执行基线。
> 本文不涉及任何签名、证书、账号、手机号、验证码、会话正文或 API 私密配置。
>
> 证据分级：
> - **【事实】** 直接读到的代码、配置或本机 SDK 声明文件，附文件与行号。
> - **【推断】** 由事实组合出的工程判断，尚未编译或设备验证。
> - **【待确认】** 需要读固定 TDLib schema、查文档、真机或编译才能定论的项目。
>
> 关联文档：`docs/integration/flclash-baseline.md`（FlClashX `ohos/` 侧勘察，由另一任务产出）、`docs/ARCHITECTURE.md`、`docs/STATUS.md`、`AGENTS.md`。

---

## 0. 结论摘要

1. 【事实】HmChat 是**单 entry 模块**的 Stage 模型应用：根 `build-profile.example.json5` 只声明 `entry` 一个模块，`entry/src/main/module.json5` 只有一个 `EntryAbility` 与一个 `backup` 扩展。
2. 【事实】所有外联流量**只有 TDLib 一条出口**。ArkTS 侧没有 `@ohos.net.http`、`fetch`、WebSocket 客户端；NetworkKit 只用于读取网络类型（`MediaNetworkMonitor.ets`）与一个绑定 `127.0.0.1` 的临时视频回环 TCP 服务器（`VideoHttpStream.ets`）。
3. 【事实】工程内**没有任何 VPN、代理、SOCKS、mihomo 代码或权限**；全文检索 `proxy|clash|vpn` 仅命中 `MediaNetworkMonitor.ets:31` 的 `BEARER_VPN` 分支。
4. 【事实】Native 侧只有 `libentry.so`（NAPI 桥）+ 运行时 `dlopen("libtdjson.so")`；`entry/libs` 目录当前**不存在**，工作副本内无任何 `.so`。
5. 【事实】新增 UI 页面的机制是 `pages/Index.ets` 内的字符串状态路由（`@State page`）+ 顶层 `build()` 分支，不是 router 路由表；设置项由 `settingsBody()` 的 `HdsSettingsRow` 打开。
6. 【推断】融合代理最短路径是：`entry` 内新增 `proxy/` 领域层 + 新增 `VpnExtensionAbility`（`type: "vpn"`）+ 新增独立 NAPI 模块 `libclash_bridge.so`（DT_NEEDED 链接 Go 的 `libclash_core.so`）。不建议把 Go 内核塞进 `libentry.so`。
7. 【推断】最大摩擦点依次为：`scripts/ci/verify-hap.py` 的原生库白名单、根 `build-profile.json5` 不在仓库内（新增模块要改用户本地文件）、VPN 扩展独立进程与 UI 进程的 RPC、Go 内核 GPL 对应源码义务。
8. 【待确认】TDLib 1.8.69 的 `addProxy`/`setProxy` 是否可用（固定 schema 不在本副本）；VPN 开启后对已建立 TDLib socket 的生效时机；`MANAGE_VPN` 的商店/ACL 准入。

---

## 1. 工程与模块结构

### 1.1 根目录与模块清单

【事实】根目录（`Get-ChildItem`，2026-11-05）：

| 路径 | 说明 |
| --- | --- |
| `AppScope/` | `app.json5`、应用级资源 |
| `entry/` | **唯一**业务模块（Stage 模型 HAP） |
| `hvigor/` | `hvigor-config.json5`（仅 modelVersion，无插件依赖） |
| `scripts/` | 构建、安装、测试、设备、官网脚本 |
| `tests/` | 宿主机 Node 测试（20 个 `*.test.mjs`） |
| `docs/` | 交接与规范；`docs/integration/` 为本次融合新增 |
| `config/` | `telegram.example.json`（模板）；`telegram.local.json` 被忽略 |
| `website/` | GitHub Pages 静态站 |
| `hvigorfile.ts` / `entry/hvigorfile.ts` | 分别 `appTasks` / `hapTasks`，**无自定义插件** |
| `oh-package.json5` | 根依赖（仅 devDependencies） |
| `THIRD_PARTY_NOTICES.md` / `LICENSE` | GPL-3.0-or-later 与第三方通知 |

`AppScope/app.json5` 定义 `bundleName`、`versionCode 1000000`、`versionName 1.0.0`、应用图标与名称标签。【事实】本次不修改。

### 1.2 hvigor 配置

- 【事实】`hvigorfile.ts:1-6` 只有 `appTasks`；`entry/hvigorfile.ts:1-6` 只有 `hapTasks`。没有插件可挂 Go 构建步骤。
- 【事实】`hvigor/hvigor-config.json5` 中 `modelVersion: "26.0.0"`，`dependencies: {}`，`execution` 全为注释默认值。
- 【推断】新增 Go 内核构建不能依赖 hvigor 插件钩子；应放在 `scripts/`（如 `build-clash-core.sh`）并由 `build.sh` 串行调用，或在 `externalNativeOptions.arguments` 里做（不推荐，会与 hvigor 并发模型冲突）。

### 1.3 oh-package 依赖

| 文件 | 【事实】内容 |
| --- | --- |
| `oh-package.json5:1-10` | `modelVersion 26.0.0`；`dependencies {}`；`devDependencies`：`@ohos/hypium 1.0.25`、`@ohos/hamock 1.0.0` |
| `entry/oh-package.json5:1-11` | 唯一依赖 `"libentry.so": "file:./src/main/cpp/types/libentry"` |
| `entry/src/main/cpp/types/libentry/oh-package.json5:1-6` | 本地包 `libentry.so`，`types: ./Index.d.ts` |
| `oh-package-lock.json5` / `entry/oh-package-lock.json5` | 锁定上述两项，无第三方 HAR |

【推断】新增第二个 NAPI 模块必须同时新增 `entry/src/main/cpp/types/<name>/oh-package.json5` 与 `Index.d.ts`，并在 `entry/oh-package.json5` 里加一条 `file:` 依赖，否则 ArkTS 侧 `import x from 'lib<name>.so'` 无法解析。

### 1.4 SDK 版本与构建选项

【事实】`build-profile.example.json5`（公开模板，`scripts/setup.sh` 会复制为根 `build-profile.json5`）：

| 字段 | 值 | 位置 |
| --- | --- | --- |
| `targetSdkVersion` | `26.0.0` | L7 |
| `compatibleSdkVersion` | `6.1.1(24)` | L8 |
| `runtimeOS` | `HarmonyOS` | L9 |
| `nativeCompiler` | `BiSheng` | L11 |
| `strictMode` | `caseSensitiveCheck: true`、`useNormalizedOHMUrl: true` | L12-15 |
| `modules` | 仅 `entry` | L28-41 |

【事实】`entry/build-profile.json5`（不含任何 `signingConfigs`，签名由用户在本机维护，本文不展开）：

| 字段 | 值 | 位置 |
| --- | --- | --- |
| `apiType` | `stageMode` | L2 |
| `externalNativeOptions.path` | `./src/main/cpp/CMakeLists.txt` | L10 |
| `abiFilters` | `["arm64-v8a"]`（仅一个 ABI） | L13-15 |
| `buildOptionSet[release].arkOptions.obfuscation` | `enable: false` | L21-30 |
| `nativeLib.debugSymbol` | `strip: true` | L31-35 |
| `targets` | `default`、`ohosTest` | L39-46 |

【事实】本工作副本**没有根 `build-profile.json5`**（被 `.gitignore` 第 15 行忽略），只有 `build-profile.example.json5`。因此直接开 DevEco 构建会缺产品/模块声明，必须先跑 `scripts/setup.sh` 或使用 `scripts/build.sh`。

### 1.5 Native：CMake、NAPI 模块、`.so` 打包与加载

【事实】`entry/src/main/cpp/CMakeLists.txt`：

- L3 `project(harlgram)`
- L14 `add_library(entry SHARED napi_init.cpp)`
- L15 C++17、禁用编译器扩展
- L17 `target_link_libraries(entry PRIVATE libace_napi.z.so dl)`（注释 L16 说明 musl 下 `-ldl` 解析 `dlopen/dlsym`）

【事实】`entry/src/main/cpp/napi_init.cpp`：

- L16-20：声明现代 TDLib JSON C ABI 四个函数指针 `td_create_client_id`、`td_send`、`td_receive`、`td_execute`
- L38-62：`LoadTdlib()` 用 `std::call_once` + `dlopen("libtdjson.so", RTLD_NOW | RTLD_LOCAL)`，任一符号缺失则 `dlclose` 并保持 `available=false`
- L59-60：注释明确「库保持进程生命周期加载，不卸载」，且不打印任何请求/消息
- L109-138：`createClient()` 前后各执行一次 `setLogVerbosityLevel=0`，校验 `clientId > 0`，登记到 `createdClients`
- L140-195：`send()` 校验 clientId 为正 32 位整数且必须由本桥创建、请求为 UTF-8 1–1048576 字节、禁止内嵌 NUL
- L197-212：`receive()` 用 `api.receive(0.0)` 零超时轮询，`receiveMutex` 保护，返回前立即 `assign` 复制
- L229-237：`napi_module.nm_modname = "entry"`
- L240-243：`__attribute__((constructor))` 注册模块

【事实】`entry/src/main/cpp/types/libentry/Index.d.ts:1-8` 导出四个方法：`getTdlibStatus(): string`、`createClient(): number`、`send(clientId, request): void`、`receive(): string`。

【事实】`libtdjson.so` 的产出与打包：

- `scripts/build-tdlib.sh:8-9` 固定 OpenSSL `3.5.9` 与归档 SHA-256
- L25-28 ABI 映射：`arm64-v8a → aarch64-linux-ohos`，另支持 `x86_64`
- L107-120 用 OHOS toolchain 交叉编译 `tdjson`
- L124-128 `cp "$TD_OHOS_BUILD/libtdjson.so" "$ROOT/entry/libs/$OHOS_ARCH/libtdjson.so"`
- L146-153 `package` 阶段复制 TDLib/SQLCipher/OpenSSL/LLVM 许可、项目 GPL 与 `THIRD_PARTY_NOTICES.md`

【事实】`entry/libs` **当前不存在**；`.gitignore` 第 21 行忽略 `/entry/libs/*/*.so`。即：本副本没有任何原生二进制，`getTdlibStatus()` 会返回 `not-linked`。

【事实】`scripts/ci/verify-hap.py:20-24` 把 HAP 内容写死为：

```python
LIBRARIES = ('libentry.so', 'libtdjson.so', 'libc++_shared.so')
LICENSES  = ('TDLib.txt', 'OpenSSL.txt', 'SQLCipher.txt', 'LLVM.txt',
             'Libphonenumber.txt', 'Unicode-CLDR.txt', 'Harlgram-GPL-3.0.txt',
             'Harlgram-Notices.txt')
TD_EXPORTS = frozenset(('td_create_client_id','td_send','td_receive','td_execute'))
```

并且 L128-132 要求三者必须位于 `libs/arm64-v8a/`，L147-151 要求 `libtdjson.so` 的 SONAME 恰为 `libtdjson.so`。【推断】任何新增 `.so` 若不同步改这个白名单，发布门禁会直接失败（详见 §7.3）。

### 1.6 当前工作副本的「缺件」清单

| 缺失项 | 影响 | 【事实】依据 |
| --- | --- | --- |
| 根 `build-profile.json5` | 无法直接 hvigor/DevEco 构建 | `.gitignore:15`，只有 example |
| `entry/libs/arm64-v8a/*.so` | TDLib 不可用；HAP 缺原生库 | `Test-Path entry/libs` 为 False |
| `entry/src/main/ets/config/TelegramBuildConfig.ets` | `Index.ets:19` 的 import 无法解析，ArkTS 编译失败 | 目录 `ets/config` 不存在；由 `scripts/configure-telegram.mjs` 生成，被 `.gitignore` 忽略 |
| 签名配置 | 仅用户本机持有 | 本文不读取、不展开 |

---

## 2. 应用入口与导航

### 2.1 EntryAbility 生命周期

【事实】`entry/src/main/ets/entryability/EntryAbility.ets`：

| 方法 | 行号 | 行为 |
| --- | --- | --- |
| `onCreate` | L12-14 | 仅 hilog |
| `onWindowStageCreate` | L20-28 | 保存 `windowStage`，调用 `loadWindowContent()` |
| `loadWindowContent` | L30-48 | 先 `WindowAppearance.initialize(context)`（失败只 warn，不阻塞），再 `windowStage.loadContent('pages/Index')`，成功后 `WindowAppearance.attach()` |
| `onWindowStageDestroy` | L50-55 | `WindowAppearance.detach()` |
| `onForeground` | L57-65 | `AppStorage.setOrCreate('mediaForeground', true)`、`telegramService.setForeground(true)`、刷新系统外观 |
| `onConfigurationUpdate` | L67-73 | 系统深浅色变化时刷新外观 |
| `onBackground` | L75-80 | `mediaForeground=false`、`telegramService.setForeground(false)` |

【事实】页面入口只有 `entry/src/main/resources/base/profile/main_pages.json` 中的 `pages/Index`。

【推断】VPN 扩展不经过 `EntryAbility`：`VpnExtensionAbility` 由系统在 `vpnExtension.startVpnExtensionAbility(want)` 后独立拉起，拥有自己的 ArkTS 运行时，因此代理状态必须通过 RPC/AppStorage 之外的显式通道回传 UI。

### 2.2 `pages/Index.ets` 的单页多态路由

【事实】`Index` 是单文件巨型组件（约 2400 行），用字符串状态切换顶层页面：

| 位置 | 内容 |
| --- | --- |
| L59-61 | `@Entry @Component struct Index` |
| L62-63 | `@StorageProp('harlgram.darkMode')`、`@StorageProp('harlgram.appearanceMode')` |
| L64-137 | 全部 `@State`（`page` 在 L67，`currentTab` L66，`storageRoute` L65） |
| L137 | `private navigationStack: NavPathStack = new NavPathStack()` |
| L171-... | `aboutToAppear()`：注册 `Environment.envProp('colorMode')`、`KeyboardAvoidMode.RESIZE`、`LocalStore.initialize`、`telegramService.subscribe` |
| L2394-2428 | `build()`：`WithTheme` + `Column` + 分支渲染 + `bindSheet` 转发面板 |

`build()` 的分支顺序（L2399-2416）：

```
!ready → LoadingProgress
page === 'welcome'  → welcomePage()
page === 'account'  → accountPage()
page === 'accounts' → accountManagementPage()
page === 'storage'  → StoragePage(...)
page === 'about'    → aboutPage()
else                → conversationNavigation()   // 主界面（含底部 Tabs）
```

【事实】`windowBackground()`（L351-355）只为 `storage | accounts | account | home(tab 2)` 返回 `pageBackground()`，其余返回 `surface()`；根容器 `Column` 使用该颜色并 `expandSafeArea([SafeAreaType.SYSTEM],[SafeAreaEdge.BOTTOM])`（L2417-2418）。

### 2.3 底部 Tabs

【事实】`masterPane()` L2091-2108：

```ts
Tabs({ barPosition: BarPosition.End, index: $$this.currentTab, barModifier: this.tabBarVisibility() }) {
  TabContent() { this.chatsPage() }      .tabBar(BottomTabBarStyle.of(this.chatTabSymbol, '聊天'))
  TabContent() { this.contactsPage() }   .tabBar(BottomTabBarStyle.of(this.contactsTabSymbol, '联系人'))
  TabContent() { this.settingsPage() }   .tabBar(BottomTabBarStyle.of(this.settingsTabSymbol, '设置'))
}
```

配套：`tabBarStyle: NativeBottomTabsStyle`（L124）、三个 `TabBarSymbol`（L125-136）、`tabBarVisibility()`（L1047-1050，仅切换 `visibility` 以保留官方浮动材质）。

【事实】底部栏固定三项；`currentTab === 2` 即设置页。`onChange`（L2103-2106）切换时关闭会话搜索。

### 2.4 Navigation / NavDestination 结构

【事实】主界面把 `masterPane()` 放进 `Navigation`，聊天页作为唯一 `NavDestination`：

- `conversationNavigation()` L2129-2139：`Navigation(this.navigationStack)`，`mode(NavigationMode.Auto)`、`navBarWidth(this.navigationWidth())`、`navBarWidthRange([280,320])`、`minContentWidth(320)`、`hideTitleBar(true)`、`hideToolBar(true)`、`navDestination(this.destinationContent)`、`onAppear → syncNavigation()`。
- `destinationContent(name)` L2110-2127：`NavDestination()` 内按 `page === 'chat'` 渲染 `chatPage()`，否则空态；`hideTitleBar(true)`、`bindContentCover($$photoViewerVisible, ...)`、`onBackPressed → goBack()`。
- `syncNavigation()` L336-343：窄屏只在 `page === 'chat'` 时 `pushPath({name:'conversation'})`；宽屏（`isWide()`，L327，`viewportWidth >= 600`）常驻；回主界面时 `clear(false)`。
- `viewportWidth` 由根 `Column.onAreaChange` 更新（L2419 → `updateViewport()` L330-334）。

【事实】二级页面（存储、账户管理、关于、账户）**不进入** `NavPathStack`，而是直接替换根 `Column` 的分支，返回由各自的 `onBack: () => this.goBack()` 处理。

### 2.5 设置页与二级页面如何打开

【事实】`settingsBody()` L2194-2257 是设置页唯一内容（`Scroll` + 分组 `Column` + `HdsSettingsRow`）：

| 分组/入口 | 行号 | 打开方式 |
| --- | --- | --- |
| 账户管理 | L2222-2226 | `this.settingRow(..., '账户管理', '', () => { ...; this.page = 'accounts'; })` |
| 「数据与存储」→ 存储管理 | L2230-2234 | `this.page = 'storage'` 并重置 `storageRoute` |
| 「个性化」→ 外观 | L2235-2238 | `chooseAppearance()`（系统 ActionMenu，L370-385） |
| 「账号与数据」→ 收藏夹 / 连接状态 | L2239-2245 | `openSavedMessages()` / `enterAccount()` |
| 「关于」→ 关于 HmChat | L2250-2253 | `this.openAbout()` |
| 退出账号按钮 | L2246-2249 | `confirmLogOut()`（L1096-1104） |

【事实】二级页面容器统一用 `HdsPage`（`components/HdsPage.ets`）：`HdsNavigation` + `titleMode(MINI)` + `hideToolBar(true)`，内容区 `Column` 固定 `padding({top: 56})`（L35），背景按 `surface/dark` 计算（L43）。`aboutPage()` L2086-2089 是最简模板。

【事实】`goBack()` L922-938 是**唯一**二级页返回实现：清理草稿/菜单/预览状态 → `page = telegram.ready || previewMode ? 'home' : 'welcome'` → `navigationStack.clear(false)` → `syncNavigation()`。它不区分来源页。

【事实】`openAbout()` L1106-1110 是打开二级页的标准写法：`persistDraft()` → 若在聊天则 `leaveChat()` → `page = 'about'`。

### 2.6 新增「设置 → 网络代理」页面的具体挂载点

【推断】以下改动全部落在 `entry/src/main/ets/pages/Index.ets`，是改动量最小、与现有 HDS 规范一致的方案：

| 步骤 | 文件/位置 | 具体做法 | 备注 |
| --- | --- | --- | --- |
| ① 页面状态 | `Index.ets:67` 附近（`@State private page`） | 复用 `page` 字符串，新增值 `'proxy'`；如需页内子路由，仿 `@State private storageRoute: string = 'storage'`（L65）新增 `@State private proxyRoute: string = 'overview'` | 不要新增 Tab |
| ② 打开函数 | `Index.ets:1106-1110`（`openAbout()` 之后） | 新增 `private openProxy(): void { this.persistDraft(); if (this.isTelegram && this.page === 'chat') { telegramService.leaveChat(); } this.page = 'proxy'; }` | 与 `openAbout` 同构 |
| ③ 设置入口 | `Index.ets:2230-2234`（「数据与存储」分组） | 在 L2232 的 `存储管理` 行之后插入 `this.settingRow($r('app.media.hg_globe_blue'), '网络代理', this.proxySummary(), () => this.openProxy())`；若要多一行分隔，参照 L2242 的 `Divider()` | 分组标题沿用 `sectionLabel()`（L1406-1410） |
| ④ 页面容器 | `Index.ets:2086-2089`（`aboutPage()` 旁） | 新增 `@Builder private proxyPage() { HdsPage({ title: '网络代理', dark: this.darkMode, onBack: () => this.closeProxy(), content: () => { this.proxyBody() } })... }` | 内容自己 `Scroll` |
| ⑤ 顶层分支 | `Index.ets:2409-2413` | 在 `storage` 与 `about` 分支之间加 `} else if (this.page === 'proxy') { this.proxyPage() }` | 顺序不影响，但建议紧跟 `storage` |
| ⑥ 根背景 | `Index.ets:351-355`（`windowBackground()`） | 条件里加入 `this.page === 'proxy'`，与 `storage` 同组返回 `pageBackground()` | 否则底部安全区与页面背景出现色差 |
| ⑦ 返回语义 | `Index.ets:922-938`（`goBack()`） | 新增 `closeProxy()`：`page = 'home'; currentTab = 2;` 并保留 `navigationStack`；或给 `goBack()` 加 `if (this.page === 'proxy') { this.page='home'; this.currentTab=2; return; }` | **必须改**，否则从代理页返回会落到会话列表且可能丢失设置页上下文 |
| ⑧ 图标资源 | `entry/src/main/resources/base/media/` | 复用现有 `hg_globe_blue`（已用于「连接状态」「存储管理」），或按 `docs/APP_ICON.md` 流程新增 | 新增位图需登记 `config/public-assets.json` |

【推断】不建议把「网络代理」做成第四个底部 Tab：会牵动 `NativeBottomTabsStyle`、`BottomTabBarStyle`、`tabBarVisibility()`、`currentTab` 语义与 `windowBackground()` 的 `tab 2` 判断，且与 `docs/UI_GUIDELINES.md` 的官方三 Tab 结构冲突。

---

## 3. 网络与原生边界

### 3.1 调用链

【事实】

```
Index.ets (UI 动作)
  └─ telegramService (TelegramService.ets:272 单例)
       └─ TelegramClient (TelegramService.ets:27, telegram/TelegramClient.ts:19)
            └─ TdTransport.send/receive (TdTypes.ts:110)
                 └─ NativeTransport (TelegramService.ets:20-24)
                      └─ nativeTdlib(import 'libentry.so') → cpp napi_init.cpp
                           └─ dlopen libtdjson.so → td_send / td_receive
                                └─ Telegram 服务端 + 沙箱加密数据库
```

关键实现：

| 位置 | 【事实】行为 |
| --- | --- |
| `TelegramService.ets:7` | `import nativeTdlib from 'libentry.so'` |
| `TelegramService.ets:20-24` | `class NativeTransport implements TdTransport`，四个方法直接转发到 NAPI |
| `TelegramService.ets:27` | `new TelegramClient(new NativeTransport(), chatRepository)`，单实例 |
| `TelegramClient.ts:144` | 构造函数注入 `transport`、`repository`，无 ArkUI/Kit 依赖 → 可在 Node 上测试 |
| `TelegramClient.ts:186-197` | `request(type, fields, extra)`：生成 `@type`、`@extra` 关联键，`transport.send(clientId, JSON.stringify(...))` |
| `TdTypes.ts:107-110` | `TelegramState`、`TelegramHistoryState`、`TelegramParameters`、`TdTransport` 显式类型 |

### 3.2 TDLib 初始化（唯一入口）

【事实】`TelegramService.connect()` L152-181：

1. L153-156 `nativeTdlib.getTdlibStatus() !== 'available'` → `fail('此安装包尚未包含可用的 TDLib 原生库…')` 并抛错（**不伪造 Ready**）。
2. L157-160 由 `sessionStorageDirectory(context.filesDir, credentials.databaseNamespace)` 计算 `<filesDir>/telegram/session-<32hex>` 与 `/files`，不存在则 `mkdirSync(..., true)`。
3. L161-164 组装 `TelegramParameters { apiId, apiHash, databaseDirectory, filesDirectory, encryptionKey }`。
4. L165 `storageManager.initialize(context, activeAccount)`。
5. L166 `videoEpoch++; client.start(parameters)`。
6. L167-180 启动 60 ms `setInterval` 轮询：`client.drain()`，每 60 s 触发 `storageManager.maintain(false)`；异常则 `fail('协议引擎运行异常…')` 并清定时器。

【事实】`TelegramClient.start()` L164-184：`createClient()` → 立即 `request('getOption', {name:'version'})` 触发 TDLib 开始推送授权状态；30 s 初始化超时。

【事实】`TelegramClient.authorize()` L328-401：收到 `authorizationStateWaitTdlibParameters` 时发送 `setTdlibParameters`（L342-349），字段包括 `database_directory`、`files_directory`、`database_encryption_key`、`use_secret_chats: false`、`api_id`、`api_hash`、`system_language_code: 'zh'`、`device_model: 'HarmonyOS NEXT'`、`application_version: '0.1.0'`；`use_test_dc: false`。

【事实】`CredentialVault.save()` 在 `TelegramService.start()` L146 先落盘 API 身份与数据库密钥，再由 `connect()` 使用；`startDefault()` L118-124 校验 `TELEGRAM_API_ID` / 32 位 hex `TELEGRAM_API_HASH`（来自生成的 `config/TelegramBuildConfig.ets`）。

### 3.3 轮询、限流与线程模型

【事实】`TelegramClient.drain()` L276-325：

- L279-281 清理超时的 `managedRequests`（30 s）
- L290-296 鉴权请求超时（30 s）
- L297-304 初始化超时（30 s）
- L305-324 **每轮最多 64 条或 12 ms**，`transport.receive()` 返回空串即 break；`@client_id` 不匹配的更新丢弃
- L325 有变化才 `emit()`（避免无谓 UI 重绘）

【事实】Native 侧（`napi_init.cpp`）线程约束：

- `receiveMutex`（L34）同时保护 `td_receive` 与 `td_execute`，因为二者会使上次返回指针失效（L33 注释）
- `clientsMutex` + `createdClients`（L35-36）拒绝非本桥创建的 clientId
- `receive()` 固定零超时（L206），注释「never wait on the ArkUI thread」
- TDLib 库不卸载（L59-60），其异步线程持续存在

【推断】该模型与代理内核的关键差别：TDLib 是**拉取式**（JS 定时拉），mihomo 是**推送式**（Go 主动回调）。若把 Go 事件直接映射进 `libentry.so`，需要新增 NAPI ThreadSafeFunction（TSFN）或改为 ArkTS 侧轮询；FlClashX 用 TSFN（队列容量 4）+ 回环 RPC，见 `docs/integration/flclash-baseline.md`。

### 3.4 NAPI 导出与 ArkTS 契约

【事实】`entry/src/main/cpp/types/libentry/Index.d.ts:1-8` 与 `napi_init.cpp:216-221` 一一对应，共 4 个导出。没有事件回调、没有 Promise、没有 buffer 接口。

【推断】新增代理内核建议**不要**扩展现有 4 个导出，而是新增独立模块（见 §7.2），理由：导出语义、错误码与生命周期完全不同；`libentry.so` 已承担 TDLib 动态加载，避免把 Go runtime 的 TLS/线程模型混入同一 `.so`。

### 3.5 外联清单（是否所有外联都经 TDLib）

【事实】对 `entry/src/main/ets/**` 全量检索：

| 结论 | 依据 |
| --- | --- |
| 无 HTTP 客户端 | 无 `@ohos.net.http` / `@kit.NetworkKit` 的 `http` 用法 / `fetch` / `XMLHttpRequest` |
| NetworkKit 仅两处 | `MediaNetworkMonitor.ets:1`（`connection`，读默认网络与能力）、`VideoHttpStream.ets:2`（`socket`，本地回环服务器） |
| 回环服务器不外联 | `VideoHttpStream.ets:16-24`：`server.listen({address:'127.0.0.1', port:0, family:1})`，路径为随机 UUID，仅服务单个已授权视频，供本机 AVPlayer 取流 |
| 网络类型读取不持久化 | `MediaNetworkMonitor.ets:5-6` 注释与 L23-38 实现：只取 `netId / bearerTypes / networkCap / isRoaming`，不保存 SSID/运营商/IP |
| 无 VPN / 代理 / SOCKS 代码 | 全量检索 `proxy|clash|vpn|mihomo` 仅命中 `MediaNetworkMonitor.ets:31` 的 `BEARER_VPN` |

**结论【事实】**：应用的**全部外联**（登录、会话、消息、媒体下载、富文本、存储统计）都经 TDLib；不存在应用自建 HTTP 通道。因此代理只需覆盖 TDLib 的 socket 即可覆盖全部业务流量。

【待确认】AVPlayer 的本地回环取流不受 VPN 影响（目标地址是 127.0.0.1，通常绕过 TUN）；若内核把 loopback 也纳入路由，视频播放会失效。需要在 VPN 路由配置里显式排除 `127.0.0.0/8`。

### 3.6 代理生效位置（两种可选面）

| 方案 | 覆盖范围 | 需要改动 | 依据/风险 |
| --- | --- | --- | --- |
| A. 系统级 VPN（TUN） | 全部应用 socket，含 TDLib 与 AVPlayer | 新增 `VpnExtensionAbility` + Go 内核 + `protect()` | 与 FlClashX 架构一致；需处理自身流量排除、路由、DNS |
| B. TDLib 内置代理 | 仅 Telegram 流量 | `TelegramClient` 增加 `addProxy`/`setProxy` 请求；需 UI 填 SOCKS5/HTTP 代理 | 【待确认】TDLib 1.8.69 固定 schema 是否有对应方法；本副本无 `libtdjson.so` 与源码，无法本地核对 |
| C. A + B | 推荐组合 | VPN 为主，TDLib 代理为「仅 Telegram / 绕过 VPN」开关 | 避免 VPN 未授权时完全不可用 |

【推断】最稳妥的产品形态是 C：默认 A；当用户拒绝 VPN 授权或系统路由异常时，可退化为 B（仅 Telegram 走代理），并在 UI 明确区分两种状态，不得把 B 显示成「全局代理已连接」。

---

## 4. 存储与配置归属

### 4.1 现有持久化清单

| 模块 | 存储介质 | 命名空间 / 键 | 【事实】位置 |
| --- | --- | --- | --- |
| `CredentialVault.ets` | HarmonyOS Asset | alias `harlgram.telegram.v1`（主账户）/ `harlgram.telegram.v1.<32hex accountId>`；secret 为 JSON `{apiId, apiHash, encryptionKey, databaseNamespace}` | L16-19、L63-71；`ACCESSIBILITY=DEVICE_FIRST_UNLOCKED`、`CONFLICT_RESOLUTION=OVERWRITE` |
| `AccountStore.ets` | Asset | alias `harlgram.accounts.v1`；secret 为 JSON `{active, accounts[], pending?, version:2}` | L11、L43-56 |
| `LocalStore.ets` | Preferences | `harlgram_local_v1`，键 `snapshot`（演示快照）、`recovery_snapshot`（损坏备份） | L21-27、L31-43；真实模式下 `save()` 直接 return（L32-33） |
| `AppearancePreferences.ets` | Preferences | `harlgram_appearance_v1`，键 `mode`（`light/dark/system`） | L22、L37-46 |
| TDLib 会话 | 应用沙箱文件 | `<filesDir>/telegram[/session-<32hex>]/` + `/files` | `model/SessionStorage.ts:33-39`、`TelegramService.ets:157-160` |
| 上传/媒体临时文件 | 应用沙箱 | 由 `AttachmentService` / TDLib 管理 | `services/AttachmentService.ets` |
| 代理相关 | — | **不存在** | 全量检索无命中 |

【事实】`SessionStorage.selectSessionStorage()`（L11-31）保证：恢复失败时必然换新 namespace（最多尝试 4 次且不与旧值相同），旧加密 key 不会被拿去开旧目录。

【事实】`AccountStore` 与 `CredentialVault` 都使用单写队列（`writes` Promise 链）串行化，避免旧写入覆盖新值。

### 4.2 代理配置应放哪里（判断）

| 数据类型 | 建议介质 | 理由 |
| --- | --- | --- |
| 订阅 URL（常含 token）、节点密码/UUID、私钥、自定义 headers | **Asset**（新 alias，如 `harlgram.proxy.v1`） | 与 `CredentialVault` 同级敏感度；订阅 URL 泄露等于泄露整套节点。放 Preferences/明文文件不可接受 |
| 生成后的 mihomo 配置文件（含上述秘密） | 沙箱文件，**仅**扩展进程可读，且不导出备份 | `VpnExtensionContext` 有独立 `filesDir`；TDLib 已有「敏感配置不进 Preferences」的既有约定 |
| 规则集、GeoIP/GeoSite、内核缓存 | 沙箱文件 | 体积大、可再生、非秘密；`backup_config` 需排除（见 `entry/src/main/resources/base/profile/backup_config`） |
| 运行时状态（运行/停止、当前选中节点名、延时） | 内存 + 可选 Preferences（仅展示用） | 进程重启即失效，不能当持久真值 |
| 「按账户启用代理」这类轻量偏好 | Preferences（非敏感）或 Asset 同一条 JSON | 设备级 VPN 单实例，账户级只做开关 |

【推断】**作用域应默认全局（设备级）**：系统同一时刻只允许一个 VPN，且 HmChat 同时只连接一个活跃账户（`TelegramService` 单 client，L26-27）。若把节点选择做成账户级，会在账户切换时触发内核重启与 TDLib 重连，成本高且易失败。建议：全局节点/订阅 + 每账户「是否经代理」开关。

【推断】不要把代理状态写入 `LocalStore` 的 `snapshot`：`LocalStore.save()` 在真实模式下直接返回（L32-33），写不进去，且该文件语义是「演示数据」。

【待确认】Asset 单条 secret 的大小上限是否足够容纳完整订阅内容。若不够，只存订阅 URL 与少量凭据，节点列表由内核侧文件持有。

---

## 5. 权限与 Ability

### 5.1 现状

【事实】`entry/src/main/module.json5`：

| 项目 | 值 | 行号 |
| --- | --- | --- |
| `deviceTypes` | `["phone","tablet"]` | L7-10 |
| `requestPermissions` | `ohos.permission.INTERNET`、`ohos.permission.GET_NETWORK_INFO` | L14-17 |
| `abilities` | 仅 `EntryAbility`（`mainElement`，L6），带 home skill | L18-39 |
| `extensionAbilities` | 仅 `EntryBackupAbility`（`type: "backup"`，`exported: false`，metadata 指向 `$profile:backup_config`） | L40-53 |
| `pages` | `$profile:main_pages`（仅 `pages/Index`） | L13 |

【事实】`entry/src/ohosTest/module.json5:1-11` 只声明测试 feature 模块，无权限。

【事实】无 `ohos.permission.KEEP_BACKGROUND_RUNNING`、无通知权限、无 `MANAGE_VPN`。

### 5.2 VPN 需要新增什么

【事实】本机 SDK 26 的声明文件（`ets/api/@ohos.net.vpnExtension.d.ts`）：

- L22-24 模块说明：第三方 VPN 应用负责创建虚拟网卡、配置路由；**隧道进程与内部协议由应用自行实现**。
- L29-46 警告：`VpnExtensionAbility` 内**不得**引用 `@ohos.contact`、`@ohos.geolocation`/`geoLocationManager`、`@ohos.multimedia.audio`、`@ohos.multimedia.camera`、`@ohos.telephony.call`、`@ohos.telephony.sim`、`@ohos.telephony.sms`，否则可能异常退出。
- L93 `startVpnExtensionAbility(want: Want): Promise<void>`；L125 `createVpnConnection(context: VpnExtensionContext): VpnConnection`；L114-118 注释要求先 `startVpnExtensionAbility` 再 `createVpnConnection`。
- 全文**没有** `@permission` 标注。

【事实】`ets/api/@ohos.app.ability.VpnExtensionAbility.d.ts`：`export default class VpnExtensionAbility`，`context: VpnExtensionContext`，`@since 11`，`@stagemodelonly`。

【事实】本机 SDK 26 的 `toolchains/modulecheck/module.json` 中 `extensionAbilities.type` 枚举包含 `"vpn"`。

【事实】本机 SDK 26 的 `toolchains/lib/PermissionDefinitions.json`：

| 权限 | grantMode | availableLevel | availableType |
| --- | --- | --- | --- |
| `ohos.permission.MANAGE_VPN` | `system_grant` | `system_basic` | `SYSTEM` |
| `ohos.permission.INTERNET` | `system_grant` | `normal` | `NORMAL` |
| `ohos.permission.GET_NETWORK_INFO` | `system_grant` | `normal` | `NORMAL` |
| `ohos.permission.KEEP_BACKGROUND_RUNNING` | `system_grant` | `normal` | `NORMAL` |

【推断】`MANAGE_VPN` 是系统级权限（`system_basic` + `SYSTEM`），普通三方应用**不应**声明；`vpnExtension` 的准入靠系统 VPN 授权弹窗（首次 `create()` 时）。因此 `module.json5` 需要新增的是**扩展声明**，而不是 VPN 权限：

```json5
"extensionAbilities": [
  { /* 现有 EntryBackupAbility 保持不变 */ },
  {
    "name": "ClashVpnExtensionAbility",
    "srcEntry": "./ets/vpn/ClashVpnExtensionAbility.ets",
    "type": "vpn",
    "exported": false
  }
]
```

【待确认】应用市场是否对上架应用的 `type: "vpn"` 扩展有额外审核/证书要求；`MANAGE_VPN` 是否在某些设备上必须由 ACL 授予。

【推断】若需要常驻通知/后台保活，再加 `ohos.permission.KEEP_BACKGROUND_RUNNING`（`normal`，可声明）与通知相关权限；这属于产品决策，不是 VPN 必需。

### 5.3 对代码分层的直接影响

【推断】由于 §5.2 的禁用模块限制，`VpnExtensionAbility` 及其同进程代码**不能**复用会间接引用 `@kit.TelephonyKit` 的模块。现有 `MediaNetworkMonitor.ets:2` 引用 `@kit.TelephonyKit` 的 `radio`。若把该文件放进扩展进程，将命中禁用清单（`sim`/`call` 属 telephony 相关模块，是否包含 `radio` 需以 SDK 为准）。**结论：扩展进程代码必须与 UI 侧服务保持文件级隔离**，不要在扩展里 import `TelegramService` 或 `MediaNetworkMonitor`。

【待确认】`@kit.TelephonyKit` 的 `radio`（网络状态）是否属于 L29-46 禁用的 `sim` 模块同一 kit；若属于，扩展侧只能通过 RPC 向 UI 侧请求网络信息。

---

## 6. 构建、测试与产物

### 6.1 脚本入口

| 脚本 | 【事实】行为 | 关键行 |
| --- | --- | --- |
| `scripts/env.sh` | 统一导出 `DEVECO_HOME/DEVECO_SDK_HOME/NODE_HOME/JAVA_HOME/PATH`、`HDC_BIN`、`HARLGRAM_BUNDLE`、`HARLGRAM_ABILITY`；Windows 默认 `HARLGRAM_CACHE_HOME`；提供 `select_device()`（必须 `HDC_TARGET` 才允许在多设备时选择）与 `hdc_device()` | — |
| `scripts/setup.sh` | 从模板复制根 `build-profile.json5` 与 `config/telegram.local.json`（不覆盖已存在文件），配置 Git hooks，调用 `configure-telegram.sh debug` | — |
| `scripts/build.sh` | `configure-telegram.sh <mode>` → 锁 `.hvigor/harlgram-build.lock` → `hvigor --mode module -p product=default -p module=entry@default -p buildMode=<mode> assembleHap --no-daemon` → 打印产物目录 | L18-19、L21 |
| `scripts/install.sh` | 默认安装 `entry/build/default/outputs/default/entry-default-signed.hap`；`hdc install -r`；支持 `HARLGRAM_HDC_TRANSFER=shell` | — |
| `scripts/run.sh` | `hdc shell aa start -a EntryAbility -b <bundle>` | — |
| `scripts/screenshot.sh` | `snapshot_display` + 回传，校验 PNG 头与大小 | — |
| `scripts/test-domain.sh` | 用 DevEco 自带 TypeScript 转译 → `node --test tests/*.test.mjs` | L12-13 |
| `scripts/build-tdlib.sh` | `all/fetch/openssl/generate/tdlib/package/smoke` 分阶段；产物 `entry/libs/<abi>/libtdjson.so` | L124-128 |
| `scripts/ci/verify-hap.py` | 本地/HAP 门禁：检查三个 `.so`、8 份许可、TDLib SONAME 与 4 个导出 | L20-24、L128-160 |
| `scripts/check-public-tree.py` | 提交前公开树/隐私检查 | — |

【事实】CI 只有 `.github/workflows/checks.yml`（调用 `./scripts/test-domain.sh`，注释说明 HAP 编译与设备验收是本地独立步骤）与 `pages.yml`（官网）。`verify-hap.py` **不在** CI 中自动运行，是发布前的人工门禁——但它仍会被 `tests/ci-package.test.mjs` 间接测试。

### 6.2 产物位置

| 产物 | 路径 |
| --- | --- |
| HAP | `entry/build/default/outputs/default/entry-default-signed.hap`（`.gitignore` 忽略 `**/build`；Windows 上 `entry/build` 是指向缓存根的目录联接） |
| 转译后的测试 JS | `artifacts/tests/js/`（`tests/transpile.mjs` L9） |
| TDLib | `entry/libs/arm64-v8a/libtdjson.so`（忽略） |
| 日志/截图 | `artifacts/`、`.local/`（均忽略） |

【事实】Windows 工作副本把 `entry/build`、`oh_modules`、`node_modules`、`.hvigor`、`.local`、`artifacts` 等重定向到缓存根（`AGENTS.md`、`docs/STATUS.md` 首节、`scripts/cache-layout.ps1`）。

### 6.3 宿主机测试组织

【事实】`tests/transpile.mjs`：

- L10-23 的 `files` 白名单（13 个纯 `.ts`）：`model/ChatModels`、`MediaModels`、`StorageModels`、`VideoPlayback`、`MessagePresentation`、`PhoneNumber`、`PhotoTransform`、`data/PhoneCountries`、`DemoData`、`ChatRepository`、`telegram/TdTypes`、`RichMessage`、`TelegramClient`。
- 用 `ts.transpileModule`（`strict: true`, `target ES2020`, `module CommonJS`）输出到 `artifacts/tests/js`，**不做类型检查**（类型检查由 ArkTS/IDE 负责）。

【事实】测试文件 20 个（`tests/*.test.mjs`），涵盖协议、历史、动作、多账户、存储、媒体、响应式模型、公开树与 HAP 门禁。`docs/STATUS.md:15` 记录最近一次为 **316 项通过**。

【推断】代理领域的纯逻辑（订阅解析、节点选择、规则匹配开关、配置序列化）应放 `.ts` 并加入 `transpile.mjs` 的 `files`，才能进入宿主机测试；`.ets` 里的 VPN 扩展与 RPC 只能靠设备验证。

### 6.4 新增原生库后的构建链路改动清单

【推断】按依赖顺序：

1. **内核源码与构建脚本**：新增 `scripts/build-clash-core.sh`（固定 mihomo/flclash 提交 + Go 版本 + 校验和），产出 `libclash_core.so`（c-shared，`GOOS=openharmony`）。
2. **NAPI 桥源码**：`entry/src/main/cpp/` 下新增目录（如 `clash/`），在现有 `CMakeLists.txt` 追加 `add_library(clash_bridge SHARED ...)` 与 `target_link_libraries(clash_bridge PRIVATE libace_napi.z.so ...)`。
3. **链接 Go 内核**：`libclash_core.so` 必须作为 **DT_NEEDED**（FlClashX 注释说明 musl 下 `dlopen` 会触发 `initial-exec TLS resolves to dynamic definition`），因此：
   - CMake 需 `target_link_libraries(clash_bridge PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/../../../libs/${OHOS_ARCH}/libclash_core.so)` 或提供 `-L` + `-lclash_core`；
   - 打包时两个 `.so` 必须同在 `libs/arm64-v8a/`。
4. **ArkTS 类型包**：新增 `entry/src/main/cpp/types/clash_bridge/{oh-package.json5, Index.d.ts}`，并在 `entry/oh-package.json5` 添加 `"libclash_bridge.so": "file:./src/main/cpp/types/clash_bridge"`。
5. **门禁同步**：`scripts/ci/verify-hap.py:20` 的 `LIBRARIES` 与 `tests/ci-package.test.mjs:10` 的 `libraries` 必须一起加 `libclash_bridge.so`、`libclash_core.so`；许可清单 `LICENSES` 也要加新条目，否则 `test-domain.sh` 与发布门禁失败。
6. **release 裁剪**：`entry/build-profile.json5:31-35` 的 `strip: true` 会作用于所有 `.so`；Go c-shared 被 `llvm-strip` 后是否仍能启动【待确认】，必要时按库名加 `exclude`。
7. **ABI**：仍保持 `abiFilters: ["arm64-v8a"]`；x86_64 模拟器需另建内核产物，本轮不扩。

---

## 7. 可集成点与风险清单

### 7.1 放新模块还是放 entry 内

| 方案 | 优点 | 缺点 | 结论 |
| --- | --- | --- | --- |
| A. 全部放 `entry`（新目录 `ets/proxy/`、`ets/vpn/`、`cpp/clash/`） | 不改根 `build-profile.json5`（该文件不在仓库，改了也不进 Git）；复用现有 HDS、设置页、单模块打包 | `entry` 体积与职责变大；VPN 扩展代码与 UI 代码在同一模块但不同进程 | **推荐起步方案** |
| B. 新建 HAR/HSP 模块（如 `proxy/`） | 边界清晰、可独立测试与复用 | 必须在根 `build-profile.json5` 的 `modules` 加条目——而该文件被 `.gitignore` 忽略，每位开发者/CI 都要手工同步；`build-profile.example.json5` 也要改；HSP 还需签名与安装顺序 | 中期重构可选 |

【事实】根 `build-profile.example.json5:28-41` 的 `modules` 只有 `entry`；`.gitignore:15` 忽略根 `build-profile.json5`。这是方案 B 的硬摩擦。

### 7.2 单模块双 NAPI 模块是否可行

【事实】hvigor 侧的模块名由 `oh-package` 本地包的 `name`（`libentry.so`）与 C++ 侧 `napi_module.nm_modname`（`"entry"`）共同决定；两者当前一致（`types/libentry/oh-package.json5:2`、`napi_init.cpp:234`）。

【推断】**可行且推荐**：

- 新建 `libclash_bridge.so`，`nm_modname = "clash_bridge"`，ArkTS 侧 `import clashBridge from 'libclash_bridge.so'`；
- 两个 `.so` 由同一个 `CMakeLists.txt` 生成两个独立 target，hvigor 只配置一个 `externalNativeOptions.path` 即可（会构建该 CMake 工程的全部 target）；
- 优点：Go runtime 与 TDLib 的线程/TLS 模型互不干扰；崩溃域隔离；可按需只在 VPN 扩展进程加载（UI 进程不加载 Go）。

【推断】反方案：把 Go 导出并入 `libentry.so`。缺点是 `libentry.so` 会被迫 `DT_NEEDED libclash_core.so`，UI 进程一 import TDLib 桥就同时把 51 MB 的 Go 内核映射进内存（FlClashX 侧内核约 51 MB，见 `docs/integration/flclash-baseline.md`），且 Go 的 `initial-exec TLS` 与 TDLib 的 `dlopen` 同处一个加载器上下文，风险叠加。

【待确认】hvigor 是否会把 `entry/libs/<abi>/*.so` 全部打包（包括未被任何 NAPI 模块引用的 `libclash_core.so`）。`build-tdlib.sh` 依赖这一行为打包 `libtdjson.so`，但 TDLib 是 `dlopen` 加载，属于「附带文件」；Go 内核是 DT_NEEDED，属于「必需依赖」，两者对打包器要求不同，需实测 HAP 内容。

### 7.3 CMake 与打包合并点

【事实】唯一合并点：`entry/src/main/cpp/CMakeLists.txt:14-17`。当前：

```cmake
add_library(entry SHARED napi_init.cpp)
set_target_properties(entry PROPERTIES CXX_STANDARD 17 ...)
target_link_libraries(entry PRIVATE libace_napi.z.so dl)
```

【推断】追加：

```cmake
add_library(clash_bridge SHARED clash/clash_bridge.cpp)
set_target_properties(clash_bridge PROPERTIES CXX_STANDARD 17 CXX_STANDARD_REQUIRED ON CXX_EXTENSIONS OFF)
target_include_directories(clash_bridge PRIVATE ${NATIVERENDER_ROOT_PATH}/clash)
target_link_libraries(clash_bridge PRIVATE libace_napi.z.so libhilog_ndk.z.so
                      ${NATIVERENDER_ROOT_PATH}/../../../libs/${OHOS_ARCH}/libclash_core.so)
```

【待确认】hvigor 传给 CMake 的 `OHOS_ARCH` 变量名（toolchain 提供）与 `${CMAKE_CURRENT_SOURCE_DIR}` 到 `entry/libs` 的相对层级，需要按实际构建日志确认一次。

【事实】HAP 门禁（`verify-hap.py:128-132`）要求库文件必须在 `libs/arm64-v8a/` 且文件名精确匹配白名单 → 任何新增库必须登记。

### 7.4 进程隔离与 `protect()` 环路

【事实（引自 `docs/integration/flclash-baseline.md`）】FlClashX 的模型是：`libclash_bridge.so`（NAPI，14 个导出）`DT_NEEDED` → `libclash_core.so`（Go c-shared，20 个 C 导出）；Go dialer 在 `connect()` 前同步等待 ArkTS `VpnConnection.protect(fd)` 回执（1500 ms 超时），TSFN 队列容量 4。

【推断】HmChat 必须保留 `protect` 语义，否则代理自身的出站流量会被自己的 TUN 捕获形成环路。落地要点：

1. 扩展进程内，`protect` 的 NAPI 回调必须是**非阻塞投递 + 有界等待**，且超时要能被 Go 侧感知；
2. UI 进程不参与 `protect`（避免 UI 卡顿导致 dial 失败）；
3. 若 HmChat 不引入 Flutter，FlClashX 的 `ClashServiceChannel`（RPC 启停）需用 ArkTS 重写，可复用 `RpcProtocol`/`ClashRpcServer`/`ClashRpcClient` 的协议层，但 `EntryAbility` 不可直接复用。

### 7.5 UI 入口与现有导航的冲突点

| 冲突点 | 事实 | 处理建议 |
| --- | --- | --- |
| 返回语义 | `goBack()` L922-938 硬编码回 `home`/`welcome` | 新增 `closeProxy()` 或给 `goBack()` 加 `page === 'proxy'` 分支 |
| 根背景 | `windowBackground()` L351-355 未包含新页面 | 加入 `proxy` 分支，否则底部手势区色差（`docs/UI_GUIDELINES.md` 明确要求根背景与页面一致） |
| 底栏遮挡 | 设置页内容 `padding bottom: 100`（L2254）以避开浮动 Tab | 代理页若作为二级页不显示 Tab，可用 `HdsPage` 默认全高；若复用设置页布局需保留同样 padding |
| 导航栈 | `syncNavigation()` L336-343 只处理 `home`/`chat` | 代理页覆盖全屏时不会 push `conversation`，无冲突；但不要在代理页置 `page='chat'` |
| 会话中断 | `openAbout()` 的模式会 `leaveChat()` | 从聊天直接进代理页会中断当前会话；建议只在设置页提供入口，或确认后再 `leaveChat` |
| 状态伪造 | `TelegramService` 严格区分 phase/error（L88-116、L152-156） | 代理连接状态必须独立建模（`未授权/准备中/已连接/失败/已停止`），不得复用 `telegram.ready`，也不得在 UI 上把「内核启动成功」写成「已连接」 |

### 7.6 与现有网络监视/存储策略的冲突

【事实】`MediaNetworkMonitor.ets:30-34` 把 `BEARER_VPN` 与 `BEARER_CELLULAR` 并列，且用 `radio.getNetworkState().isRoaming` 判定漫游；未知时按 `roaming`（保守，默认关闭自动下载）。

【推断】启用自有 VPN 后：

1. `getDefaultNet()` 可能返回 VPN 网络（`BEARER_VPN`），导致 `MediaNetwork` 被判为 `mobile`/`roaming`；
2. 从而触发 `configureMediaPolicy()`（`TelegramClient.ts:82-92`）取消自动下载或按漫游策略关闭媒体；
3. `TelegramClient.setMediaNetwork()`（L93-99）会向 TDLib 发送 `setNetworkType(networkTypeMobile)`，可能降低 TDLib 的连接行为（如更省电的轮询）。

【建议】在 VPN 激活时把网络判定为「非计费（wifi 类）」或新增 `proxy` 类型，并显式告知 TDLib 真实底层网络；不要把自有 VPN 当成漫游。**这是融合后必须一起改的地方**，否则用户会看到「代理开启后图片不再自动下载」。

### 7.7 许可证与第三方声明

【事实】项目自有代码为 **GPL-3.0-or-later**（`LICENSE`，`THIRD_PARTY_NOTICES.md:3`，`docs/LICENSING.md:7-11`）。

【待确认】mihomo 的具体许可（通常为 GPL-3.0，需按固定提交核对 `LICENSE`）与 FlClashX 仓库许可。若为 GPL-3.0-only，与 GPL-3.0-or-later 仍兼容（本项目可选择 v3 履行），但**必须**同时满足源码提供义务。

【推断】融合后必须更新的文件：

| 文件 | 变更 |
| --- | --- |
| `THIRD_PARTY_NOTICES.md` | 新增 mihomo（提交/版本）、Go runtime、sing-tun 等依赖条目与许可；说明修改点 |
| `docs/LICENSING.md` | 「实际构建的来源记录」表新增固定提交、Go 版本、构建参数、SHA-256；「将来分发 HAP 时」补充 Go 内核对应源码的提供方式 |
| `entry/src/main/resources/rawfile/licenses/` | 新增 `mihomo.txt`、`Go.txt`（BSD-3-Clause）等；`scripts/build-tdlib.sh:146-153` 或新的 `build-clash-core.sh` 负责复制 |
| `scripts/ci/verify-hap.py:21-23` `LICENSES` | 加入新许可文件名，否则门禁不校验新许可（也让新增许可「看起来」没被要求） |
| `tests/ci-package.test.mjs` | 同步 `libraries` / 许可清单的夹具 |
| `README.md` / `README.en.md` / `docs/FEATURES.md` | 如实标注「代理为可选能力，默认关闭；仅在你自己的网络环境中使用」 |
| `config/public-assets.json` | 若新增代理页截图并公开 |

【事实】`build-tdlib.sh:152-153` 会把 `LICENSE` 与 `THIRD_PARTY_NOTICES.md` 复制进 HAP 的 `rawfile/licenses/`，所以通知文件必须与实际打包的库一致。

【推断】GPL 风险等级：**高**。FlClashX 侧的 `libclash_core.so` 带 `vcs.modified=true` 且缺少源码（见 `docs/integration/flclash-baseline.md`），若直接分发该二进制将无法履行 GPL 对应源码义务。必须拿到 mihomo/flclash 固定源码并自行构建，或把该内核视为「不可分发的参考产物」。

### 7.8 其他风险

| 风险 | 说明 |
| --- | --- |
| 首次 VPN 授权弹窗 | 系统在 `create()` 时弹窗；用户拒绝后必须显示可恢复的错误，不能静默失败 |
| 应用被系统回收 | `VpnExtensionContext` 在 API 12 无 `terminateSelf()`（FlClashX 注释）；进程由系统回收，状态需可从 UI 侧重建 |
| TDLib 已建连 | VPN 在 TDLib 连接后开启，已存在的 socket 是否切到 TUN【待确认】；保守做法是提示「切换网络后建议重新连接」或主动 `close()` 后重连 |
| 账户切换 | `switchAccount()`（`TelegramService.ets:55-71`）会关闭旧 client；VPN 不应随账户重启 |
| 数据目录 | 扩展进程与 UI 进程的 `filesDir` 不同，代理配置/规则文件放哪一侧需固定，避免双份不同步 |
| 测试纪律 | `AGENTS.md` 与 `docs/STATUS.md:108` 明确禁止在持有真实会话的设备做同 bundle ohosTest 安装/卸载；VPN 联调只能用 normal signed HAP 覆盖安装 |
| 体积 | Go 内核 + 规则集会使 HAP 显著增大；`verify-hap.py:25` 单库上限 512 MB，需评估下载/安装体验 |

---

## 8. 事实 / 推断 / 待确认

### 8.1 事实（可直接引用）

1. 单 `entry` Stage 模块；根 `build-profile.json5` 不在仓库，只有 `build-profile.example.json5`（`targetSdkVersion 26.0.0`、`compatibleSdkVersion 6.1.1(24)`、`nativeCompiler BiSheng`）。
2. `entry/build-profile.json5` 只有 `externalNativeOptions`（`cpp/CMakeLists.txt`）、`abiFilters: ["arm64-v8a"]`、release `strip: true`、`targets: default/ohosTest`，**无 signingConfigs**。
3. `entry/oh-package.json5` 唯一依赖是本地包 `libentry.so`；`cpp/types/libentry/Index.d.ts` 导出 4 个同步方法。
4. `entry/src/main/cpp/CMakeLists.txt` 只构建 `entry` 一个 target，链 `libace_napi.z.so` 与 `dl`；`napi_init.cpp` 用 `dlopen("libtdjson.so")` 动态加载 TDLib。
5. `entry/libs` 不存在；`.gitignore` 忽略 `/entry/libs/*/*.so`；`build-tdlib.sh` 把 TDLib 复制到 `entry/libs/<abi>/`。
6. `module.json5` 权限仅 `INTERNET`、`GET_NETWORK_INFO`；扩展仅 `EntryBackupAbility`（`type: backup`）；`deviceTypes: phone/tablet`。
7. `Index.ets` 是单页字符串路由（`page`）+ 顶层 `build()` 分支；设置页 `settingsBody()` 用 `HdsSettingsRow` 打开二级页；返回统一走 `goBack()`。
8. `TelegramService` 单 client、单 60 ms 轮询；`TelegramClient.drain()` 每轮 ≤64 条 / ≤12 ms；TDLib `receive` 零超时、`receiveMutex` 串行。
9. 应用外联只有 TDLib；无 HTTP 客户端；NetworkKit 仅用于网络类型与 `127.0.0.1` 回环视频流。
10. Asset 存凭据（`harlgram.telegram.v1[.<accountId>]`、`harlgram.accounts.v1`）；Preferences 存演示快照（`harlgram_local_v1`）与外观（`harlgram_appearance_v1`）；TDLib 数据在 `filesDir/telegram[/session-<hex>]`。
11. 本机 SDK 26 提供 `VpnExtensionAbility`、`@ohos.net.vpnExtension`；`extensionAbilities.type` 允许 `"vpn"`；`MANAGE_VPN` 为 `system_basic/SYSTEM`；VPN 扩展内禁用 contacts/geo/audio/camera/call/sim/sms 模块。
12. `verify-hap.py` 把 HAP 原生库写死为 `libentry.so/libtdjson.so/libc++_shared.so` 且必须在 `libs/arm64-v8a/`；`tests/transpile.mjs` 维护 13 个可测 `.ts` 白名单。

### 8.2 推断（有依据但未验证）

1. 双 NAPI 模块（`libentry.so` + `libclash_bridge.so`）在 hvigor 单 `externalNativeOptions` 下可行，且优于合并到 `libentry.so`。
2. Go c-shared 必须以 DT_NEEDED 方式链接，不能运行时 `dlopen`（TLS 模型限制，源自 FlClashX 注释）。
3. 代理配置默认应为**全局（设备级）**，账户级只做开关。
4. 代理页应作为「设置 → 网络代理」二级页，而非第四个底部 Tab。
5. 现有 `windowBackground()` 与 `goBack()` 必须为新页面同步修改，否则出现背景色差与返回落点错误。
6. `MediaNetworkMonitor` 会把自有 VPN 误判为蜂窝/漫游，从而抑制自动下载，需要在融合时一并修正。
7. 新增原生库会同时打破 `verify-hap.py` 与 `tests/ci-package.test.mjs`，必须成对修改。
8. 直接复用 FlClashX 的预编译 `libclash_core.so` 无法满足 GPL 源码义务，必须自建。

### 8.3 待确认（必须先查清才能动工）

1. 固定 TDLib 1.8.69 schema 是否提供 `addProxy`/`setProxy`/`getProxies`，字段名与 `proxyType` 枚举；本副本无源码与 `.so`，无法本地核对。
2. mihomo 与 FlClashX 的准确许可与固定提交；`libclash_core.so` 的可重建性。
3. hvigor 是否把 `entry/libs/arm64-v8a/` 下所有 `.so` 打进 HAP（尤其未被 NAPI 直接引用的 DT_NEEDED 依赖）。
4. `llvm-strip` 对 Go c-shared 的影响（release `strip: true`）。
5. VPN 开启/关闭对**已建立** TDLib socket 的生效时机；是否需要主动重连。
6. `MANAGE_VPN` 是否可通过 ACL/证书在非系统应用上获得；商店对 `type: "vpn"` 的审核要求。
7. `@kit.TelephonyKit`（`radio`）是否属于 VPN 扩展禁用模块清单。
8. 本机 SDK CMake 工具链向 `CMakeLists.txt` 暴露的 ABI 变量名（用于拼接 `entry/libs/<abi>` 路径）。
9. 扩展进程 `VpnExtensionContext.filesDir` 的具体路径与可写范围（用于放配置与规则集）。
10. 首次 VPN 授权被拒绝后的系统行为与可重试性。

---

## 附录 A：关键文件路径与行号索引

| 主题 | 文件:行 |
| --- | --- |
| 应用标识 | `AppScope/app.json5:1-10` |
| 模块与权限 | `entry/src/main/module.json5:7-10`、`:14-17`、`:18-39`、`:40-53` |
| 构建选项 | `entry/build-profile.json5:2`、`:9-16`、`:18-37`、`:39-46` |
| SDK/产品 | `build-profile.example.json5:7-15`、`:28-41` |
| NAPI 桥 | `entry/src/main/cpp/napi_init.cpp:38-62`、`:109-138`、`:140-195`、`:197-212`、`:216-221`、`:229-243` |
| NAPI 类型 | `entry/src/main/cpp/types/libentry/Index.d.ts:1-8` |
| CMake | `entry/src/main/cpp/CMakeLists.txt:14-17` |
| 生命周期 | `entry/src/main/ets/entryability/EntryAbility.ets:12-14`、`:20-48`、`:50-55`、`:57-80` |
| 页面状态 | `entry/src/main/ets/pages/Index.ets:59-137` |
| 路由分支 | 同上 `:2394-2428` |
| 设置页 | 同上 `:2194-2257`（分组 `2230`/`2235`/`2239`/`2250`） |
| 二级页模板 | 同上 `:2086-2089`（关于）、`:1437-1440`（账户管理）、`:2081-2084`（账户） |
| 返回 | 同上 `:922-938` |
| 背景同步 | 同上 `:351-355`、`:2417-2418` |
| 底部 Tabs | 同上 `:2091-2108`、`:1047-1050`、`:124-136` |
| Navigation | 同上 `:2129-2139`、`:2110-2127`、`:336-343` |
| 打开二级页 | 同上 `:1106-1110`、`:1112-1120` |
| 协议客户端 | `entry/src/main/ets/telegram/TelegramClient.ts:144`、`:164-184`、`:186-197`、`:276-325`、`:328-401`、`:82-99` |
| 协议类型 | `entry/src/main/ets/telegram/TdTypes.ts:107-110` |
| 系统适配 | `entry/src/main/ets/services/TelegramService.ets:7`、`:20-24`、`:55-71`、`:118-124`、`:152-181`、`:272` |
| 凭据 | `entry/src/main/ets/services/CredentialVault.ets:16-25`、`:49-72` |
| 账户 | `entry/src/main/ets/services/AccountStore.ets:11`、`:43-56` |
| 演示存储 | `entry/src/main/ets/services/LocalStore.ets:21-28`、`:31-43` |
| 外观 | `entry/src/main/ets/services/AppearancePreferences.ets:22`、`:37-46` |
| 会话目录 | `entry/src/main/ets/model/SessionStorage.ts:11-31`、`:33-39` |
| 网络监视 | `entry/src/main/ets/services/MediaNetworkMonitor.ets:5-6`、`:23-38` |
| 回环视频 | `entry/src/main/ets/services/VideoHttpStream.ets:16-24` |
| HDS 标题 | `entry/src/main/ets/components/HdsPage.ets:33-44` |
| HDS 设置行 | `entry/src/main/ets/components/HdsSettingsRow.ets:11-19` |
| 构建 | `scripts/build.sh:18-21`、`scripts/env.sh`、`scripts/setup.sh` |
| 测试 | `scripts/test-domain.sh:12-13`、`tests/transpile.mjs:10-23` |
| TDLib 构建 | `scripts/build-tdlib.sh:8-9`、`:25-28`、`:107-120`、`:124-128`、`:146-153` |
| HAP 门禁 | `scripts/ci/verify-hap.py:20-24`、`:128-132`、`:147-160` |
| CI | `.github/workflows/checks.yml:35` |
| 许可 | `LICENSE`、`THIRD_PARTY_NOTICES.md:3`、`:9-16`、`docs/LICENSING.md:7-11`、`:17-28` |
| FlClashX 基线 | `docs/integration/flclash-baseline.md` |

## 附录 B：建议的下一步（不改代码即可做）

1. 补齐构建前置：`scripts/setup.sh` → `scripts/build-tdlib.sh package` → 确认 `entry/libs/arm64-v8a/libtdjson.so` 存在；再跑 `scripts/build.sh` 得到当前基线 HAP。
2. 只读获取 TDLib 1.8.69 固定 schema，确认 `addProxy`/`setProxy` 是否可用（决定是否保留「仅 Telegram 代理」退路）。
3. 在 `docs/integration/flclash-baseline.md` 基础上固定 mihomo/flclash 的源码提交与构建脚本方案，先做「能从源码重建 `libclash_core.so`」的实验。
4. 设计「网络代理」页面的字段与状态机（未授权 / 准备中 / 已连接 / 失败 / 已停止），先写纯 `.ts` 模型并加入 `tests/transpile.mjs`，在宿主机验证。
5. 评估 `libclash_core.so` 体积与规则集体积对 HAP 的影响，再决定是否分包或按需下载（后者会引入外部下载，需先确认与 Telegram API 条款/隐私政策不冲突）。