# Telegram 真实账号接入设计

核验日期：2026-10-29。本文记录官方接口核验、原生库构建结果与账号接入约束。编译成功与真实账号接通是不同的验收项。

## 本次已完成的原生构建

已通过 `scripts/build-tdlib.sh` 分阶段构建并打包 OHOS arm64-v8a TDLib。`fetch`、`openssl`、`generate`、`tdlib`、`package` 阶段均获得成功退出码；没有全局安装软件。产物为 `entry/libs/arm64-v8a/libtdjson.so`。

| 项目 | 验证结果 |
| --- | --- |
| SDK | DevEco 内置 Native 26.0.0.105，Clang 15.0.4 |
| TDLib | 1.8.69，固定提交见下文 |
| OpenSSL | 3.5.9 LTS，静态 PIC 链接 |
| ELF | AArch64，SONAME 为 libtdjson.so |
| 动态依赖 | libz.so、libc++_shared.so、libc.so |
| 导出接口 | td_create_client_id、td_send、td_receive、td_execute 均存在 |
| strip 后大小 | 36,930,608 字节 |
| SHA-256 | d966db88b4aaf00312f1889ff530444f73a159c1cf4ce31e22e23328271c5c1e |

可复现命令：

```sh
scripts/build-tdlib.sh all
# 默认只编译 arm64；需要 x86_64 时单独执行：
OHOS_ARCH=x86_64 scripts/build-tdlib.sh all
```

构建缓存与日志位于被忽略的 `.local/third_party/`。其中 `td-arm64-build.log` 保存主体编译过程，`td-arm64-v8a-evidence.txt` 保存 SDK、ELF、依赖与哈希结果。OpenSSL 源码压缩包固定 SHA-256 为 `603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a`，与官方发布校验文件核对一致。[OpenSSL 官方下载](https://openssl-library.org/source/)

脚本维护两个最小 TDLib 补丁：OHOS 缺少 pthread CPU 亲和性接口，故在 `__OHOS__` 下关闭可选的线程绑核能力；同时去掉共享库的版本化 SONAME，以匹配 HAP 的 `libtdjson.so` 打包名称。宿主机存在损坏的 Homebrew ccache，脚本通过 CMake 配置禁用 ccache，并未修改系统安装。

当前 OpenSSL 构建关闭汇编、异步引擎、动态 provider 模块与可选 secure heap，使用可移植实现；TDLib 本身未调用 OpenSSL secure heap 初始化。此配置优先验证 OHOS 平台接入，仍需后续性能、加密接口与真实网络回归，不能从链接成功推断这些验证已经完成。许可材料保存在 `entry/src/main/resources/rawfile/licenses/`，`package` 阶段复制 TDLib、内置 SQLCipher、OpenSSL 与 SDK LLVM 通知，以及项目 GPL 和第三方通知。当前公开源码不分发 HAP；以后发布编译包时需核对最终包与同行文档包含完整通知和对应源码提供方式，见 [LICENSING.md](LICENSING.md)。

`scripts/build-tdlib.sh smoke` 可在允许执行 shell ELF 的开发设备上验证无账号的引擎创建和关闭。本次连接的真机拒绝执行 `/data/local/tmp` 下的 smoke ELF，返回 `Permission denied`；未绕过系统保护。因此该检查没有通过，实际运行验证应通过安装后的 HAP / Node-API 桥继续进行。HAP 运行与真实账号认证结果以项目验证记录为准。

## 技术选择

采用 ArkTS / ArkUI + 鸿蒙 Node-API + TDLib C JSON 接口。TDLib 是 Telegram 官方提供的客户端库，负责连接、协议、加密、更新顺序和本地数据库；Bot API 面向机器人，不能用来实现普通用户的 Telegram 客户端。[官方介绍](https://core.telegram.org/tdlib)

本次核验的 TDLib 基线是 [4c6377aa7386c39217878a9a56d581922ad37ca4](https://github.com/tdlib/td/commit/4c6377aa7386c39217878a9a56d581922ad37ca4)，其 [CMakeLists.txt](https://github.com/tdlib/td/blob/4c6377aa7386c39217878a9a56d581922ad37ca4/CMakeLists.txt#L3) 声明版本 1.8.69。实际集成时固定一个已验证提交，禁止默默使用移动的 master。

TDLib 官方支持列表未明确列出 HarmonyOS NEXT；本方案是基于 C ABI 与 OHOS Native 工具链的移植判断。可以进行交叉编译，不等于已证明全部运行时行为兼容。

## 已确认的本机条件

本机 DevEco Studio SDK 中存在：

```text
/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native/
  build/cmake/ohos.toolchain.cmake
  llvm/bin/clang++
  sysroot/usr/include/zlib.h
  sysroot/usr/include/pthread.h
  sysroot/usr/include/sys/epoll.h
```

本次检查未在该 sysroot 的常见 include 位置发现 OpenSSL 头文件。因此不能直接用 macOS Homebrew OpenSSL 链接 OHOS 产物；必须单独准备相同 ABI 的 OpenSSL 构建。系统提供 CMake 和 gperf；Ninja 可使用 DevEco 随附工具或显式配置安装位置。

当前已构建和验证的原生目标为 arm64-v8a；使用 arm64 模拟器。其他 ABI 需要独立构建对应的 OHOS ELF 库。Android arm64 库、macOS dylib 和 OHOS arm64 库不能仅因 CPU 架构相同而互换。[OpenHarmony NDK 构建文档](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/napi/build-with-ndk-overview.md)

## 原生构建计划

TDLib 依赖 C++17、OpenSSL、zlib，构建阶段依赖 CMake 与 gperf。源码已经包含 SQLite 相关模块。基线 CMake 提供 `prepare_cross_compiling` 目标，先在宿主机生成协议相关 C++ 文件，再用目标工具链构建。[TDLib 构建说明](https://github.com/tdlib/td/blob/4c6377aa7386c39217878a9a56d581922ad37ca4/README.md)

以下命令是供实现脚本使用的构建草案，前提是已准备固定提交源码、目标 ABI 的 OpenSSL 和明确的安装目录：

```sh
# 第一步：macOS 宿主机生成源码，不要给此阶段设置 OHOS toolchain。
cmake -S "$TD_SOURCE" -B "$TD_HOST_BUILD" \
  -DTD_GENERATE_SOURCE_FILES=ON
cmake --build "$TD_HOST_BUILD" --target prepare_cross_compiling

# 第二步：使用 OHOS 库与头文件，禁止混入宿主机 OpenSSL。
cmake -S "$TD_SOURCE" -B "$TD_OHOS_BUILD" \
  -DCMAKE_TOOLCHAIN_FILE="$OHOS_NATIVE/build/cmake/ohos.toolchain.cmake" \
  -DOHOS_ARCH=arm64-v8a \
  -DOHOS_STL=c++_shared \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$TD_INSTALL" \
  -DOPENSSL_ROOT_DIR="$OPENSSL_OHOS" \
  -DOPENSSL_INCLUDE_DIR="$OPENSSL_OHOS/include" \
  -DOPENSSL_CRYPTO_LIBRARY="$OPENSSL_OHOS/lib/libcrypto.a" \
  -DOPENSSL_SSL_LIBRARY="$OPENSSL_OHOS/lib/libssl.a"
cmake --build "$TD_OHOS_BUILD" --target tdjson
```

注意事项：

- 上述目录变量均为任务变量，脚本应校验非空与目录存在后再运行。
- 静态 OpenSSL 必须启用 PIC；为每个 ABI 单独生成，不能交叉复用。
- 通过 CMake find 结果确认 zlib 来自目标 sysroot；不要通过全局编译参数掩盖宿主机依赖污染。
- 基线 TDLib 的平台识别没有专门的 OHOS 分支，需要验证编译器宏、poll/epoll、网络与线程实现；只有实际失败后再维护最小补丁，保留上游出处。
- 所有 Native 库的 C++ 运行时链接方式保持一致；检查 `libc++_shared.so` 和其他动态依赖是否正确打包。
- 当前 TDLib 给共享库设置版本化 SOVERSION。打包前检查 ELF 的 SONAME / NEEDED，确保 HAP 中的文件名与动态加载器解析一致，不能只把版本化文件随意重命名。
- 保存构建版本、SDK、ABI、OpenSSL 版本、补丁、产物 SHA-256 和符号检查结果；以此作为可复现记录。

## Node-API 边界

新集成使用 `td_create_client_id`、`td_send`、`td_receive`、`td_execute`。旧的 `td_json_client_*` 接口仍存在，但官方已标为旧接口，不建议新项目依赖。[C JSON 接口文档](https://core.telegram.org/tdlib/docs/td__json__client_8h.html)

桥接层只负责：创建客户端、发送 JSON、顺序接收更新、复制消息、生命周期和错误映射。不要在 C++ 中复刻 UI 状态或把 ArkUI 组件传入原生层。

实现约束：

1. `td_receive` 只能有一个消费者，不能多线程同时调用；接收后立即复制字符串，再派发给 ArkTS。不得把 TDLib 拥有的 char 指针留给异步回调。
2. 阻塞 receive 必须放到专用原生线程；也可先用有界的零超时接收作为原型，但不能把秒级等待放在 UI 线程。
3. 使用 `@extra` 关联请求与响应，用 `@client_id` 区分账号；按接收顺序归并更新。
4. JSON `int64` 字段是字符串，`int53` 是数字。尤其会话排序字段不可随意转为 JavaScript Number；模型必须按 schema 区分。
5. `td_execute` 仅用于官方明确支持同步的函数，不能拿它发送普通异步消息。
6. 退出时发送 `close` 并等待 Closed 状态，停止接收循环后释放线程和 Node-API 回调；超时退出须有明确策略。

## 认证状态机

当前应用明确使用 `use_test_dc: false`，连接 Telegram 生产数据中心，用于开发者自己授权的真实账号登录；这与 DevEco 的 debug/release 构建类型无关。debug HAP 仍然可以连接生产环境，不能仅凭 debug 标志把真实手机号请求自动切到测试服务器。

Telegram 的 Test DC 使用独立测试账号和数据，保留测试号码只在测试服务器有效；测试数据可能被周期清除，也不用于保存私密信息。未来如新增端到端协议测试，应单独配置 `use_test_dc: true`，使用独立数据库目录、文件目录与认证状态，不与真实账号的加密数据库和会话混用。当前未提供测试环境切换入口，也未宣称已完成 Test DC 账号认证验证。[官方测试账号说明](https://core.telegram.org/api/auth#test-accounts)

账号认证以 `updateAuthorizationState` 为准。请求成功的 Ok 仅表示该请求被接受，不等于账号已登录。[官方入门文档](https://core.telegram.org/tdlib/getting-started)

| 收到状态 | 客户端动作 |
| --- | --- |
| WaitTdlibParameters | 发送应用 API ID / API Hash、应用版本、设备信息、沙箱数据库目录和数据库加密密钥。 |
| WaitPhoneNumber | 用户输入国际格式手机号，提交手机号请求。 |
| WaitCode | 按服务器返回的验证码渠道、长度与超时显示界面；提交用户输入的验证码。 |
| WaitPassword | 展示二次验证密码输入；不得记录或持久化明文密码。 |
| WaitEmailAddress / WaitEmailCode | 展示并处理邮箱验证流程；不能错误地当作普通短信验证码。 |
| WaitOtherDeviceConfirmation | 展示对应设备确认链接或二维码，不在本地伪造成功。 |
| WaitRegistration / WaitPremiumPurchase | 按服务端要求提供完整对应流程，或明确显示当前未支持的下一步。 |
| Ready | 开始加载真实会话，移除登录遮罩，启用账号功能。 |
| LoggingOut / Closing / Closed | 停用发送，结束旧账号状态；按退出原因决定是否清除本地数据库。 |

以上名称是便于阅读的缩写，代码中使用 schema 的完整类型名。所有错误、限流、断网与不支持状态必须可见，不能回退到演示模式并继续显示真实账号状态。

基线 [td_api.tl](https://github.com/tdlib/td/blob/4c6377aa7386c39217878a9a56d581922ad37ca4/td/generate/scheme/td_api.tl) 已发生接口演进：`setTdlibParameters` 的字段直接位于请求对象内，并包含 `database_encryption_key`；不要沿用旧版嵌套 parameters 示例。`sendMessage` 使用 `topic_id`，升级 TDLib 时必须同步请求模型。

## 首个云端消息闭环

实现顺序为：Ready → `loadChats` → 归并聊天更新 → 选择会话 → `getChatHistory` → `sendMessage` → 处理发送成功或失败更新 → 处理新消息。历史分页使用上一批末尾消息 ID；第一次返回数量少于 limit 不必然意味着没有更多历史。

会话数据维护来自新聊天、标题、位置、最后消息、已读与未读等更新。排序使用该列表中的 position.order，并以 chat.id 处理同序值；不能只按最后消息时间排序。发送中的临时消息必须在成功回执后替换为服务端消息，不能简单追加造成重复。

上述行为应分别建立领域测试：乱序输入防护、重复回执幂等、发送失败重试、分页去重、账号切换、重连后恢复。界面测试使用本地夹具；真实账号测试单独进行并去敏记录。[官方聊天与消息指南](https://core.telegram.org/tdlib/getting-started)

### 当前源码中的分页、草稿与图片边界

`TelegramClient` 提供 `loadMoreChats()`、`loadOlderMessages(chatId)`、`setDraft(chatId, text)` 和 `sendPhoto(chatId, path, caption)`。主会话列表按请求串行加载，收到其关联的 404 才记为列表尾部。历史请求按会话分别限制一个在途请求，用 `@extra` 关联响应，使用已加载最旧的 int53 消息 ID 续页；短页不等于尾部。旧历史空页停止，连续两次游标不前进也停止，避免重复加载同一锚点。

当前 TDLib schema 的草稿结构为 `draftMessage.content` 包含 `draftMessageContentText`。初始化从真实会话草稿恢复；本地编辑立即进入仓储，远端写入按会话串行，后续输入合并为最新版本。为保证迟到的服务器回声不会覆盖正在输入的文字，本次客户端会话内一旦编辑某会话草稿，就以本地草稿为准；其他设备之后的草稿改动会在下次客户端启动时重新恢复。当前不提供跨设备草稿冲突合并。

真实头像使用 `chat.photo.small`、`user.profile_photo.small`。所有已加载会话与真实联系人的小头像按文件 ID 去重，限制每个文件最多 512 KiB；`updateFile` 完成后回填 `ChatSummary.avatarPath` 和 `Contact.avatarPath`。没有头像或下载失败时才保留文字占位。

图片发送采用当前 schema 的两层结构：`inputMessagePhoto.photo` 是 `inputPhoto`，其中的 `photo` 才是 `inputFileLocal`。系统选择器负责将文件复制到应用沙箱并检查上传大小；官方 `inputPhoto` 上限为 10 MB。领域层接收本地绝对路径和最多 1024 字符的说明，发送失败时保留所选路径与说明为失败消息。待发送和发送结果继续以 TDLib 的消息更新为准。

接收图片从 `messagePhoto.photo.sizes` 选择可下载的最大尺寸，仅在活动聊天中自动下载，单文件限制 20 MiB；`updateFile` 完成后回填消息 `mediaPath`。非活动群组不会因此批量下载图片。带剧透或私密标志的图片当前保持未揭示状态，不自动下载或显示。

上述行为已由 `tests/telegram-history.test.mjs` 的虚构数据场景覆盖，该批场景已通过回归；最新测试总数见 [STATUS.md](STATUS.md)。此结果验证请求结构、状态归并和竞态防护；新增头像、照片、分页和草稿的实际 HAP 构建与真机服务端验收，仍以最终集成验证记录为准。

## 凭据、数据与应用标识

API ID / API Hash 需要应用开发者从 [my.telegram.org](https://my.telegram.org) 的 API development tools 申请；DevEco 的应用签名不能代替 Telegram API 凭据。[申请说明](https://core.telegram.org/api/obtaining_api_id)

普通用户的界面应直接进入手机号登录；API ID / API Hash 属于应用开发者的构建配置，不要求每个普通用户申请。开发者把自行申请的应用身份写入被 Git 忽略的 `config/telegram.local.json`，构建脚本生成同样被忽略的 `TelegramBuildConfig.ets`，由应用读取。开源仓库只提供无真实值的配置样例。

无配置时仍可构建并验证原生 UI、Node-API 桥和 TDLib 加载，但不能把缺少应用身份的状态显示成可真实登录。真实账号认证必须使用开发者自己的配置，release 构建应拒绝缺失配置。项目不内置官方 Android 源码中的应用身份；[BuildVars.java](https://github.com/DrKLO/Telegram/blob/3de37c8cfb039452be7398909461da6288babf15/TMessagesProj/src/main/java/org/telegram/messenger/BuildVars.java) 中的公开值也不应被称为已获通用授权的测试凭据。

手机号、验证码、密码、认证密钥和消息内容不进入日志、截图夹具、agent 上下文或测试快照。数据库放在应用沙箱内，加密密钥由设备安全存储保护；演示数据与账号数据分库。卸载、退出账号、切换账号与清空演示数据应有各自明确语义。

TDLib 主体采用 [Boost Software License 1.0](https://github.com/tdlib/td/blob/4c6377aa7386c39217878a9a56d581922ad37ca4/LICENSE_1_0.txt)，但其内置 SQLCipher 另有 BSD-3-Clause 许可，宿主机 tl-parser 工具为 GPL-2.0-or-later。实际运行库还静态链接 OpenSSL 3.5.9（Apache-2.0），HAP 打包 SDK 的 LLVM C++ runtime（Apache-2.0 with LLVM Exceptions，含历史通知）。不能把整个产物仅标成 Boost 许可，也不能把 Android 参考工程的 BoringSSL 当成本工程依赖。来源、完整许可与本地补丁记录见 [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)。

HmChat 应在介绍中明确其 Telegram 第三方客户端身份，使用自己的名称与图标。AI-native 在本项目指 agent 可读规范、可复现脚本和可验证开发过程；它不表示向 AI 提供用户消息的授权。Telegram API 条款对平台数据的 AI / ML 用途有独立限制，范围包括训练、开发、增强和部署，不仅是训练。条款还要求基本功能正确互通，并要求可访问频道内容的客户端支持官方赞助消息；当前仍缺输入状态、赞助消息等能力，源码公开不等于正式客户端全部条款已验收。[Telegram API 条款](https://core.telegram.org/api/terms)；具体分发边界见 [LICENSING.md](LICENSING.md)。

## 接通完成的定义

只有同时满足以下条件，才能在项目状态中标记「真实 Telegram 已接通」：

- 至少一个目标 OHOS ABI 完成可复现构建，HAP 加载 TDLib 无链接错误。
- 使用开发者自己的 API 配置完成真实账号认证，重启后可恢复会话。
- 会话列表和历史来自服务端；文本消息能在另一 Telegram 客户端收到，入站消息也能显示。
- 错误、断网、二次验证、退出登录有可见行为，没有伪造成功或静默切换演示数据。
- 证据注明设备与版本，日志去敏；未覆盖的媒体、通话、推送、后台与其他功能继续明确列为待实现。
