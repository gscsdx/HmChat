# 当前开发状态

更新：2026-11-05。此文件为 AI / 开发者接力入口，不含私有配置或账号内容。

## 本机缓存目录重定向（2026-11-05）

本机 Windows 工作副本把可再生的缓存与产物统一放到工程外的缓存根（`<cache-root>`）：`.local`、`artifacts`、`.hvigor`、`.appanalyzer`、`entry/build`、`entry/.cxx`、`entry/.preview`、`entry/.test`、`oh_modules`、`node_modules` 均是指向该缓存根的 Windows 目录联接，工程内路径不变，源码与配置仍留在工程目录。新增 `scripts/cache-layout.ps1` 幂等建立/修复联接，`-MigrateUserHome` 复制用户级 hvigor 缓存并保留源目录；`scripts/env.sh` 在 Windows 上默认 `HARLGRAM_CACHE_HOME`，仅为本仓库脚本导出 `HVIGOR_USER_HOME`，不写系统环境变量。`build.sh` 构建前自动修复联接，`device-layout.sh` 的隐私路径校验同时接受工程内与缓存根两个受信位置。

已实际建立 10 个联接，并用只读 `Get-Item` 核对 `LinkType=Junction` 与目标路径一致；Git Bash 的 `pwd -P` 也解析到缓存根，`device-layout.sh` 的受信路径判断匹配。`%USERPROFILE%\.hvigor` 已用 robocopy 复制到缓存根 `user-home`（源目录保留，目标 36,797 个文件 / 468.1 MB；`Copy-Item` 会因 MAX_PATH 长路径失败，脚本已改用 robocopy）。联接写入落点未在沙箱内实测，需在本机普通终端构建确认。本轮未执行 DevEco 构建、hvigor clean 或设备验证。

## 当前开发：mihomo 网络代理融合（2026-11-05）

交付文档已落盘：[clash-proxy-spec.md](integration/clash-proxy-spec.md)（132 条 EARS）、[clash-proxy-design.md](integration/clash-proxy-design.md)（1729 行）、[clash-proxy-tasks.md](integration/clash-proxy-tasks.md)（82 项任务），以及 [harlgram-baseline.md](integration/harlgram-baseline.md)、[flclash-baseline.md](integration/flclash-baseline.md)、[flclash-core-lib-baseline.md](integration/flclash-core-lib-baseline.md)。

源码已实现：11 个纯 `.ts` 模型与规则文件（ClashModels、ClashError、ClashStateMachine、ClashProfileRules、ClashRedaction、ClashActionFactory、ClashSubscriptionParser、ClashGroupDeriver、ClashDelayMap、ClashConfigPatch、ClashVpnConfig）及 `services/clash/ClashRpcProtocol.ts`；S2 服务层（RPC 双端、会话文件、CoreBridge、ProfileStore、SubscriptionFetcher、ConfigBuilder、EventDecoder、Diagnostics、AssetInstaller、KeepAlive、ClashService）；S3 原生桥（`entry/src/main/cpp/clash/clash_bridge.cpp`，双 TSFN 与 protect，CMake 双 target）；S4 VPN 扩展、会话与通知；S5 ProxyPage / ProxyRows 及 Index 挂载；S6 `scripts/build-clash-core.sh` 与 HAP 门禁。

验证：`node --test tests/clash/*.test.mjs` 161 项全通过；`tests/media-models` 7/7；`tests/ci-package` 100 pass / 1 skip；`tests/clash/extension-isolation` 5/5；`scripts/test-domain.sh` 已把 `tests/clash/` 纳入门禁：默认 locale 下 523 项、521 pass / 1 fail / 1 skip，唯一失败为 `website-docs` 用 Python GBK 读取 UTF-8 文件，与本次无关；`PYTHONUTF8=1` 下 523 项、522 pass / 0 fail / 1 skip，退出码 0。真实 `libclash_core.so` 已用本机 OHOS Go 1.24.5 + NDK 重建（51,155,664 bytes，SHA-256 `a466ab9b0a3e3fda3631680f6b326dd1032b14a42becdd4b7d1a1380917739db`，ELF64 AArch64，SONAME=libclash_core.so，NEEDED=libhilog_ndk.z.so / libc.so，无 RUNPATH；mihomo v1.19.28、Go 1.24.5、GOOS=openharmony、GOARCH=arm64、with_gvisor、无 vcs 脏标记；关键符号 initClashSync / quickStart / startTUN / registerCallbacks / freeCString 存在）；仓库外无用户签名副本用真实内核实跑 `assembleHap` 成功（unsigned debug HAP 56,524,062 bytes），HAP 内内核为 hvigor `DoNativeStrip` 后的 51,155,472 bytes / SHA-256 `4a4ac8cf…527311a`，已用 `llvm-strip` 在副本上逐字节证明是同一内核的 strip-all 结果；`libclash_bridge.so` SONAME 正确、NEEDED 含 `libclash_core.so`、无 RUNPATH。

### 设备安装与启动（2026-11-06）

- TDLib 1.8.69 + OpenSSL 3.5.9 已用 `scripts/build-tdlib.sh` 构建出 `entry/libs/arm64-v8a/libtdjson.so`；为补齐宿主工具安装了 MSYS2 的 perl/make/gperf/gcc，未改工程脚本、源码或签名。
- signed HAP 已构建：`entry-default-signed.hap` 94,258,310 B；包内含 `libtdjson.so` 36,914,008 B、`libclash_core.so` 51,155,472 B、`libclash_bridge.so` 149,840 B。
- 在 `HDC_TARGET=<指定真机>`（SGT-AL10 / arm64-v8a / API 26）上普通 signed HAP 覆盖安装成功（`install bundle successfully`），未卸载、未清数据、未跑 ohosTest。
- 解锁后 `run.sh` 退出码 0（`start ability successfully.`）；应用进程存在（PID 20020328）；截图 `artifacts/screenshots/20261106-013536.png`，1320×2848，273,106 B。截图内容未做人工/OCR 检查，避免读取账号或消息。
- 尚未验证：系统 VPN 授权弹窗、代理启停、protect 计数/降级、通知、后台保活、真实订阅、release strip 后运行；GPL 源码包/许可仍缺。

### 未登录默认设置页与 API 预设（2026-11-06）

- 已取消欢迎页：不再有品牌落地页或「开始聊天」按钮。`Index.ets` 冷启动默认 `home + currentTab=2`，未登录直接呈现设置 Tab；会话恢复成功（`becameReady`）后切到 `home + currentTab=0` 聊天 Tab；退出登录回设置 Tab。设置页保留「登录 Telegram」入口与「网络代理」。
- `config/telegram.local.json`（gitignored）已配置 10 组 API 预设，`scripts/configure-telegram.sh debug` 生成 10 组；设置页只显示 `ID ****末四位 / Hash ****末四位`，选择结果仅持久化索引。`entry/src/main/ets/config/TelegramBuildConfig.ets` 与本地配置均被 `.gitignore` 排除，未写入文档、日志或提交。
- `./scripts/build.sh` 真实 SDK 26 编译通过；signed HAP 已覆盖安装到指定真机，包内三库齐全，启动成功。`tests/domain` 在本轮路由改动后 531 项、530 pass / 0 fail / 1 skip。
- 真机界面证据：`artifacts/clash-evidence/default-settings/01-cold-settings.png`、`02-login.png`、`03-api-options.png`；冷启动停在设置页，API 凭据以掩码显示，登录入口进入手机号页。已登录会话自动切聊天 Tab 因当前设备无已登录会话，未做设备实测；仅源码路径与编译通过。API 预设来自用户提供，已随 signed HAP 内置；公开分发前需确认凭据使用条款与轮换策略。

### 聊天筛选栏与区号自动匹配（2026-11-06）

- 聊天页筛选栏改为固定等宽 4 项，设置 `barWidth('100%')`，自定义 tab 不使用 SubTabBar 侧边距；真机实测「全部/未读/群组/频道」完整可见、可切换，选中条跟随。空态文案原先把条件表达式传入子 Builder，首次构建后不刷新；已改为按筛选分支生成独立空态，真机复测「未读」显示「没有未读消息 / 所有会话都已读」，其余显示「没有找到会话」。
- 超级群分类修复：`TdChatType` 补 `is_megagroup`，`TelegramClient.syncChat` 将 `is_channel && is_megagroup` 归 `group`，广播频道归 `channel`，私聊归 `private`；避免超级群从「群组」消失、混入「频道」。领域测试新增用例，`tests/telegram-history.test.mjs` 42/42 通过。
- 区号输入自动匹配国家/地区：新增 `matchPhoneCountryByDialCode`，共享区号优先保留当前国家，其次 `PHONE_MAIN_COUNTRY_ISOS`；真机实测 `+1→美国`、`+7→俄罗斯`、`+86→中国`，国家选择器同步。登录提交仍走原 `normalizePhoneNumber`，未改协议。
- 验证：真实 SDK 26 编译通过；signed HAP 覆盖安装、启动成功，三库齐全；`PYTHONUTF8=1 ./scripts/test-domain.sh` 534 项、533 pass / 0 fail / 1 skip。截图与 dump 在 `artifacts/clash-evidence/filters-dial/`。当前离线预览无已登录会话，会话总数为 0，超级群/频道在真实账号下的显示未做设备实测。

### 品牌更名 HmChat 与新图标（2026-11-06）

- 用户确认将应用用户可见品牌统一为 HmChat，并用「纯黑底、白色圆环、下方白色横线」替换原纸飞机图标。源图 500×500 PNG 已高质量缩放为 1254×1254，覆盖 `AppScope/resources/base/media/harlgram_icon.png`；资源名与清单引用保持不变。
- 已改可见文案：AppScope/entry 字符串、聊天页标题、关于页、Logo 无障碍文本、代理 UA 与范围文案、代理通知标题、演示欢迎语、附件保存文件名。
- 按要求 bundleName 已从 `xyz.3333189.harlgram` 改为 `com.hmchat.app`，签名 profile 与新包名匹配；`scripts/env.sh` 的默认安装包名同步。新包是独立应用，旧包数据不自动迁移，旧包未卸载，可共存。内部 `harlgram.*` 持久化键、`harlgramOnly` scope 与日志 TAG 未改。
- 设置页「关于 HmChat」已移动到「退出 Telegram 账号」之前；未登录时退出按钮不显示，源码顺序为账号与数据 → 关于 HmChat → 退出。真机新包设置页与关于页显示 HmChat，关于页正文和版本正确；桌面未找到 HmChat 快捷方式，桌面图标截图和已登录状态下的退出按钮实际排列未采集。
- 真实 SDK 26 编译与 signed HAP 安装成功；`bm dump` 确认 `com.hmchat.app` 的 label 为 `HmChat`、旧包 `xyz.3333189.harlgram` 仍在。新包启动后 PID 6323。

### 官网 HmChat 更新（2026-11-06）

- 官网四处可见品牌改为 HmChat：`website/index.html`、`website/app.js`、生成脚本标题/描述、`docs/FEATURES*.md` 与 `CHANGELOG*.md`；GitHub/Pages URL、仓库路径与 `harlgram.site.language` 内部键保持不变，避免链接和语言偏好失效。
- 新图标已同步生成 `website/assets/icon.png`（512×512 等比缩放）；`app-phone.png` 与 `app-unfolded.png` 原尺寸不变，仅把可见头部品牌文字原位改为 HmChat，隐私遮挡保持；`config/public-assets.json` 四个哈希全部更新并在真实验算中匹配。
- 内容更新：FEATURES 增加聊天筛选、超级群/频道分类、区号自动匹配和 mihomo 网络代理能力及限制；验证基线改为 534 项（533 pass / 1 skip）；CHANGELOG 增加 2026-11-06 段。
- 验证：`PYTHONUTF8=1 python3 scripts/build-website.py --check` 通过，`node --check website/app.js` 通过；官网一致性测试通过；1440/390 宽截图已生成到 `artifacts/website-verify/`，CDP 实测 390 宽 `scrollWidth=390`，无页面级横向溢出；图标/截图/清单哈希 4/4 匹配。

未验证/阻断：`scripts/package-clash-source.sh` 不存在，`rawfile/licenses/clash/*` 缺 mihomo/sing-tun/Go/FlClashX 许可，`THIRD_PARTY_NOTICES.md` / `docs/LICENSING.md` 尚未登记；真实订阅未验证；系统 VPN 授权、代理启停、protect 计数/降级、通知、后台保活均未设备验证；release strip 后的实际运行未验证；设计文档 6.8 / 6.9 中部分能力未实现。

结论：本机调试，不可分发。VERDICT: PARTIAL。

下一步：补 GPL 对应源码包与许可并登记第三方通知 → 在已安装的真实 HAP 上验证系统 VPN 授权、启停、protect 计数与降级、通知和后台保活 → 用用户授权订阅验证节点/组/测速 → 最后在 release 构建中复验 strip 后的真实启停。

## 当前开发：原生设置与导航（2026-11-01）

共用 HdsPage / HdsSettingsRow 已用于聊天列表、联系人、设置、账户、关于、存储和自动下载页面，采用官方标题、菜单、搜索、选择及按钮层级。聊天详情保留原紧凑标题、头像、操作展开区和原 Navigation。设计与逐页设备记录见 UI_GUIDELINES.md、RESPONSIVE_VALIDATION.md。

历史真机覆盖安装、启动、页面返回、键盘与原草稿保留通过；本轮 316 项领域测试、真实 SDK 26 signed HAP 编译、指定手机模拟器普通覆盖安装及启动通过；官网生成一致性与脚本语法检查通过。模拟器连接状态仍显示连接中，本轮未重新验证真实服务端消息收发。不将已有记录视作本次重新验证真实消息收发。

## 当前目标与设备

完整目标是功能对齐用户已登录的 Telegram Web A 手机尺寸界面，逐项范围见 [TELEGRAM_WEB_PARITY.md](TELEGRAM_WEB_PARITY.md)。功能与用户意图参考 Web A，协议使用固定 TDLib，UI/UX 采用鸿蒙官方 ArkUI。基础聊天或一批操作通过不代表全面完成。

先完成手机单栏、用户阔折叠真机未展开形态；展开和其他设备形态后置。用户真机拔除后已授权使用手机模拟器继续验证；历史真机与本轮模拟器证据分别记录，仅在用户明确配合时采集展开形态。多个设备在线时必须显式指定 HDC_TARGET。

## 当前开发：公开进度文档与合入准备（2026-10-31）

README 中英文新增现有功能、路线图、更新日志的独立文档与官网入口；功能页依据 Web A 矩阵区分实现、真机证据与缺口，路线图按优先级/验收条件维护，CHANGELOG 记录本批源码变化而不宣称已发行 HAP。官网提供四个独立地址的导航页，中英文内容由 `scripts/build-website.py` 从对应 Markdown 生成，CI/Pages 拒绝过期产物，仍仅发布 `website/`。未启用云端 HAP 打包。

本轮 `./scripts/test-domain.sh` 316 项通过，`node --check website/app.js` 与生成一致性检查通过。浏览器核对桌面与 390px 手机宽度、四项导航、中文默认、英文切换与跨页偏好；表格在本地容器横向滚动，不撑宽整页。未新增公开图片，沿用已审查清单。原始截图、日志、配置、签名和会话仍被忽略。本轮再次通过真实 SDK 26 编译签名（`artifacts/publication-build.log`），未重做手机功能动作；安装/云端证据见下方对应记录。

提交前须检查完整实际 index，合入与线上部署结果以 GitHub PR / Actions 为准，不以本段计划当作已合入证据。

## 当前开发：视频边下边播与 B 站式播放器（2026-10-31）

已实现并在指定 HOP-AL00 / API 26 未展开真机验证：TDLib 按需字节窗口边下边播；拖到未缓存区域，缓冲后按原播放/暂停意图恢复；七档倍速、长按临时 2×/松手恢复原倍速；前后 30 秒；B 站式单击显隐、双击播放暂停、横滑预览/定位和底部自动收起控件；静音、重播、播放亮屏与后台暂停。完整边界见 [VIDEO_PLAYER.md](VIDEO_PLAYER.md)，没有宣称全 B 站功能或全设备通过。

### 分层验证

- **源码**：VideoPlayback、VideoHttpStream、VideoPlayer 与 TelegramClient/TelegramService 接入完成。临时通道只绑定 127.0.0.1、系统分配端口和每查看器独立随机路径，固定一个已授权视频，退出关闭；远端获取仍经 TDLib，缓存仍归原存储管理。未采用的 MediaSourceLoader 尝试已从工程移除，失败记录仅在 ignored artifacts。
- **宿主机**：`./scripts/test-domain.sh` **314 项通过**；覆盖字节范围/稀疏空洞、前缀证明、有界下载、冷缓存、HTTP 206/HEAD/拒绝错误或重复范围、连接取消/超时与背压、账户/连接代数隔离、磁盘检查期间切换账户、定位合并和已有完整下载任务保留。日志 `artifacts/video-stream-tests.log`。
- **SDK**：真实 SDK 26 编译和签名通过，最终 `artifacts/video-stream-build.log`；不是以宿主转译替代 ArkTS 编译。没有修改签名、API 私密配置、TDLib 版本或 Native ABI。
- **设备安装/启动**：正常 signed HAP 指定真机覆盖安装和 EntryAbility 启动通过，登录/原草稿保持；`video-stream-install.log`、`video-stream-run.log`。没有 ohosTest、卸载、清数据库或模拟器验收。
- **真实云端/冷缓存**：自己的收藏夹经 Web A 上传 150 秒、46,510,579 字节的合成测试视频；说明仅数字标识，原正文草稿保留并恢复。清理收藏夹视频缓存实际释放 32.3 MB 后重新读取，native prepared/playing 出现在 **1,572,864 / 46,510,579 字节**（约 3.4%）时；没有等待完整文件。GC 后残留的 TDLib 部分路径先用文件可访问性检查和 downloadFile 触发本地位置重校验，未绕过前缀证明去读空洞。
- **未缓存定位与自动继续**：实际请求过约 36 MB 位置的缺片；另一次从开头跳到未缓存中段，不补按播放，时钟从 0:58 推进到 1:03、1:10。横滑定位至约 1:20 后继续跨多个新下载片段，从 1:28 推进到 1:51，并最终到 2:30 完成。UI 目标变化不作为通过，结合原生 seekDone、字节窗口请求与后续时钟推进；证据 `video-stream-device.log`、`video-gestures-device.log`。
- **倍速/30 秒**：实际选择 1.5×（native speed enum 6），长按切到 2×（enum 4、hold=true），松手恢复 1.5×（enum 6、hold=false）；暂停状态下约 0:08 → 0:38 → 0:08。最终覆盖安装后再次复核，`video-stream-device-final.log`、`video-final-smoke.log`。
- **手势/生命周期**：单击显隐、双击开始播放/再次双击暂停后时钟稳定、横滑与控件自动收起均真机通过。结束重播后 Home，返回时 0:01 持续保持不自动播放；关闭后原草稿逐字 true。原始截图仅 ignored `artifacts/video-player-final.png` 等，不加入公开资产。

### 修复与范围

修复了无真实时长时创建进度条、旧 timeUpdate 覆盖定位目标、并发 seek、播放/暂停意图竞争、缓存 GC 残留路径导致读失败，以及控制栏错误居中的问题。源失败/超时提供重试与完整下载退路，账户切换和关闭不能把旧文件数据发给新播放器。最新中英文 README、媒体/架构/UI/响应式规范、Web A F03 和路线图同步范围。

真机曾锁屏及网络「连接中」，由用户自行解锁/恢复，之后才继续云端验收；没有把本地旧素材播放当作冷缓存远端证据。仅当前未展开形态与这段 H.264/AAC 合成 MP4 有本轮完整证据；更多编码、非 faststart 容器、真实断网/来电边界、画中画、字幕/多音轨、清晰度切换、完整多形态仍需独立验收。上传暂存仍保留，不新增观看历史持久化。

此前功能验收结束时工程尚未提交/推送。使用隔离临时 index 对完整工作树公开快照做安全检查通过（191 个文件），不改用户真实 index；截图、合成素材、日志、草稿、私密配置仍忽略。手机最终停留在合成视频的暂停播放器，供用户复验。

## 当前开发：消息展示与群聊内容对照

使用用户指定的主账户，对照 Telegram Web A 手机 460px 视口及真机未展开形态，浏览三个群聊。修复了 `messageRichMessage` 未解析造成整条内容丢失、文本实体丢失、群头像和连续发言、转发来源、回复摘要、联系人/表情/贴纸预览、时间固定另占一行、固定媒体高度和奇数相册空格。富内容中的照片/视频可进入同一原生查看器，文件归属由原消息验证；长文提供服务端全文读取、失败重试和超时。细节和剩余差距见 [MESSAGE_DISPLAY.md](MESSAGE_DISPLAY.md)。

三组真实群聊已在真机打开并截图，真实富文本、成员头像、连续短句、回复原文以及同段照片/相册已有呈现证据。所有操作只读，未向群发送；群截图和布局只在 ignored artifacts，不作公开配图。当前保持用户指定主账户，其他形态后置。最新 280 项宿主机测试、SDK 26 编译签名、指定真机覆盖安装/启动分别通过。底部跟随修复后最后照片说明完整可见；向上翻历史后弹出/收起键盘，6 个可见消息锚点位置比对保持。合成收藏夹媒体、时间靠右与原草稿逐字保持已复核；原始群内容未公开。

## 当前开发：图片、相册与视频

已实现系统最多 10 项图片/视频混选、逐项移除、说明、单项/分组发送，聊天相册网格、缩略图、按需视频下载与进度/取消/重试、前后媒体浏览及经系统确认保存。视频使用官方 AVPlayer + XComponent，含进度拖动、静音、倍速、后台暂停和释放。失败整组保留，正文草稿独立。范围和限制见 [MEDIA.md](MEDIA.md)。

最新 263 项宿主机测试及 SDK 26 编译签名通过；真机覆盖安装/启动通过。真机与 Web A 同账号双向验证两图加视频相册，并验证独立视频发送；真机播放/暂停、静音、1.5 倍速、点击/拖动进度、退后台暂停且恢复不自动播放、前后浏览及系统保存通过。测试只使用生成的色块图片和测试视频、自己的收藏夹，原正文草稿逐字保持。秘密/剧透媒体不自动揭示；边下边播、原文件、编辑/压缩、画中画及完整缓存管理未实现，其他形态后置。最终正常 signed HAP 覆盖安装后，原正文草稿逐字比对为 true，两个账户登录保留，并恢复测试前的第二账户。合成测试消息及保存的三项合成素材暂留供用户复验。证据为 ignored `artifacts/media-tests.log`、`media-build.log`、`media-install.log`、`media-run.log`、`media-player-final.png`、`media-web-synthetic-proof.png`；未加入公开资产。

## 当前开发：多账户登录

分支 `feat/multi-account`。账户管理已移为二级页面，设置页只保留入口；管理页显示各账户头像、名称、当前账户勾选和添加入口。各账户的头像元数据及沙箱缓存路径存放在 Asset，切换后保留；缺图或无头像时显示姓名占位。未完成登录不列入账户，只保留隔离的私有 pending 状态。

用户已自行完成第二账户登录。SDK 26 编译签名及真机覆盖安装通过；已验证两个真实账户往返切换无需重新登录、切换后留在管理页、返回设置、正常冷启动恢复最后选中账户与两个真实头像。验证未发送消息。最新宿主机 256 项通过（含此前未提交的打包检查测试），新增头像按账户隔离和保留的回归。头像与账户截图含隐私，仅存 ignored artifacts。

当前仅活动账户连接，切换通过 close 等待 Closed，不注销其他账户；独立安全凭据、加密数据库目录与文本草稿保存。未完成图片/回复/编辑时先阻止切换；跨账户草稿、未读、文件和完整退出隔离仍需更多验收，非活动账户实时同步/通知未实现。注册、重发与 30 秒超时分支已有实现及合成回归，不能用第二账户登录成功推断所有收码/注册场景都已通过。细节见 [MULTI_ACCOUNT.md](MULTI_ACCOUNT.md)。已暂停的 Actions 打包和 Worker 推送保持待办。

## 开源交付准备

- 中英文 README（默认中文）、贡献与安全政策、Issue/PR 模板、纯静态双语官网及 GitHub Pages workflow 已准备；官网使用默认 `gscsdx.github.io/HmChat/`，不使用自定义域名。
- 从完整公开 index 导出的隔离源码副本，在没有个人 API、签名、原生库与依赖缓存的条件下，setup、ohpm install、178 项测试及 SDK debug 构建均通过，生成未签名且无 TDLib 的惰性调试包。它验证公开模板可初始化/编译，不能代替真实账号或服务端验收。
- 真机普通/展开画面已采集；用户自行展开并打开会话，当前双栏可见。公开图经不透明隐私遮挡、Pura X Max 机身示意合成、人工/OCR 复核及元数据移除。图为宣传展示，不用于像素级验收，完整形态交互仍待测试。
- 清理 18 个无引用资源及未采用的图标稿；保留定稿图标与生成来源。清理后 SDK 26 编译与签名、真机覆盖安装与设置/聊天入口检查通过，账号登录保持。
- 补齐 SQLCipher、LLVM runtime、项目 GPL 和随包第三方许可；当前只公开源码，不发布 HAP。
- Git 检查覆盖完整 index、私密文件/令牌、二进制中的本机 API 秘密、图片审查清单与 PNG 元数据，共 40 项公开安全回归；公开资产政策见 [PUBLIC_ASSETS.md](PUBLIC_ASSETS.md)。

## 已确认结果

- 2026-10-31 设置区块更名「账户管理」，未完成登录改为私有 pending 状态，不再出现在账户列表；旧占位条目自动迁移，仅在认证 Ready 并取得用户资料后新增正式账户。最新 255 项测试、SDK 编译签名与真机覆盖安装通过；真机确认占位消失、旧账号可切回且登录保持，添加/返回不再出现假账户。

- 2026-10-31 欢迎首屏、登录/注册页及关于页改用黑白定稿 Logo，复用 AppScope 资源。SDK 26 编译签名和真机覆盖安装/启动通过，欢迎与手机号登录页截图已复核；关于页未单独真机打开。见 [APP_ICON.md](APP_ICON.md)。

- 已登录设置页的独立「账号信息」按钮已移除；离线预览保留登录入口。浮动 Tab 使用官方 `barBottomMargin: 12`，比原默认值下移 16vp；本机点击区域实测整体下移 44px，仍在手势区上方。SDK 构建、真机覆盖安装、三个入口切换及设置尾部「关于」打开/返回通过，登录保持。
- 用户确认的黑白轻拟物图标已接入 AppScope，应用、EntryAbility 与启动图标统一引用。SDK 26 构建、指定真机覆盖安装及从新桌面图标启动通过，登录保持；圆环/直角横条裁切完整，用户已现场确认。详情见 [APP_ICON.md](APP_ICON.md)。
- OHOS arm64 TDLib 1.8.69 / OpenSSL 3.5.9 已编译打包，现有 DevEco 签名保留。最新主 HAP SDK 26 构建、真机覆盖安装与启动通过，原生库加载正常；本轮连续覆盖安装后登录保持。
- 最新 178 项宿主机领域与公开文件安全回归通过，包含外观迁移、固定/系统模式切换与延迟读取竞态；包含 40 项公开快照/图片隐私安全检查；原有覆盖协议、消息操作权限、草稿、手机号、存储隔离与图片几何。它们不能替代真实服务端或设备交互证据。
- 真机真实头像、系统栏与底部黑边修复已复验。用户随后指出底栏外观不佳：原实现虽为官方 Tabs，但宽高、圆角和 SVG 是工程自定义。现已改为 API 26 官方 `barFloatingStyle`、系统 Symbol 和原生标签样式，移除手工 94% 宽/64vp 高/圆角 30，SDK 编译、真机覆盖安装、三入口切换及深浅色均已通过。主题已恢复用户原来的浅色；API 24 回退尚无对应设备实测。
- 底栏灰雾与手势区色差进一步修复：保留官方 ULTRA_THIN 玻璃，将额外渐变 mask 设为透明；根背景随当前页面同步到底部安全区。真机聊天页、设置页的上/下边界空白像素已一致。外观改为浅色/深色/跟随系统，独立 Preferences 在真实账号下持久保存；覆盖安装保持深色、正常重启保持跟随系统和浅色均通过。控制中心切换深/浅后无需重启即可跟随，固定浅色在系统深色下仍保持。补主窗口获焦与渲染环境事件，修复原配置回调遗漏控制中心路径；系统定时自动切色未专门实测。最终已恢复手机系统原深色、应用原浅色，登录保持。
- 聊天列表常驻搜索框已移除，改为右上角独立系统搜索按钮；点击进入官方 Search，搜索期间隐藏底栏及其渐变遮罩。真机 SDK 构建、覆盖安装、自动聚焦/键盘、无结果、取消与系统 Back 通过；稳定频道列表的三行锚点在取消与 Back 后内容及像素位置一致，原筛选保留。搜索结果独立滚动、支持继续加载会话，但数据仍只匹配已加载标题/最后消息摘要，不是服务器全局搜索。从结果进入聊天再返回的完整链路本轮未实测。
- 手机号国家/地区、区号、号码分开输入；245 地区可搜索，完整国际号码粘贴自动拆分，鉴权提交去重。用户本人完成登录，不代输号码、验证码或密码。
- 真实会话、联系人、基础文本收发、草稿、群发送者姓名、日期分隔、历史分页及单张图片收发已实现。模拟器曾验证搜索无结果/清空、本地筛选、联系人打开、系统图片选择取消及发送；这些不是服务器搜索或完整媒体能力。
- 本轮真机文本编辑、回复、单条转发到收藏夹、仅为自己删除均已由 Web A 同账号核对同步。回复保留原消息引用；此前 Saved Messages topic 导致的 400 已修正并真实复测成功。仅验证合成测试内容与收藏夹，不能扩展为所有消息类型、权限和删除范围都通过。
- 长按编辑后的输入框在真机键盘上方，取消与保存编辑均保留普通草稿。消息复制菜单存在且受权限约束，但未实际执行复制，用户剪贴板未改。
- 图片查看器已在真机验证打开、双击放大、放大后拖动、Back 和关闭按钮；退出保持原收藏夹及草稿。修复 Sheet 与 ContentCover 同节点导致弹层立即关闭，改为不同挂载节点；读取实际系统避让区修复关闭按钮和图片顶部裁切。
- 转发列表中已加载的收藏夹置顶，真机确认无需滚动可见；取消不发送。当前收件人范围仍是已加载会话，不是完整服务器搜索。
- 原收藏夹草稿已恢复，Web SHA-256 布尔比对为 true；最终真机覆盖安装、编辑保存/取消及图片关闭后逐字比对均为 true。本轮新增回复和转发测试消息已删除，Web 数量归零；此前基线测试数字已编辑恢复，Web 确认同步。未发送原草稿、未向联系人代发、未上传私人相册内容。

详细设备步骤及本地截图路径见 [DEVICE_TESTING.md](DEVICE_TESTING.md)。原始截图、布局、日志与草稿备份仅在 ignored artifacts/ 与 .local/，不得加入 Git。

## 关键修复与接力约束

曾在持有真实会话的设备尝试同 bundle 的 ohosTest 安装/卸载，随后出现安全存储与数据库解锁异常。Driver 初始化失败，未计为测试通过；新增测试已撤回。**严禁在用户登录实例重复同 bundle 测试安装/卸载、卸载主应用、清空沙箱或导出密钥。** 使用正常 signed HAP 覆盖安装和限定 bundle 的 UI 操作。

已修复初始化错误仍停在 starting 且 UI 隐藏错误的问题。旧凭据沿旧目录；缺凭据时新密钥仅使用新 namespace；恢复动作保留旧缓存并选独立新目录，不用新密钥尝试原数据库。用户本轮已重新登录真机，正常覆盖安装恢复通过，但不能据此声称旧密钥丢失的所有外部原因已解决。

草稿保留两项边界：未改正文的进出聊天不重写远端回复/格式/预览属性；旧保存请求失败时继续提交排队的新版本，当前版本失败不无限重试。当前客户端会话中发生本地编辑后仍优先本地版本，完整跨端富草稿编辑属于后续差距。

图片捏合已实现手指焦点补偿和单指/双指衔接，几何回归通过。当前 shell UI 输入只支持单指操作；**偏心双指捏合及单指加入第二指的连续手势未取得真机操作证据**，不能把双击缩放和数学测试当作这两项通过。

## 可复现命令

```bash
./scripts/test-domain.sh
./scripts/build.sh
HDC_TARGET='<指定真机>' ./scripts/install.sh
HDC_TARGET='<指定真机>' ./scripts/run.sh
HDC_TARGET='<指定真机>' ./scripts/screenshot.sh
HDC_TARGET='<指定真机>' ./scripts/device-layout.sh
python3 scripts/check-public-tree.py --staged
```

不并发 Hvigor。旧模拟器曾 HDC file 通道异常，脚本支持显式 HARLGRAM_HDC_TRANSFER=shell；当前真机使用正常传输，不沿用模拟器目标。

Git main 已初始化，hooks、公开模板、LICENSE、CI 已准备。API 本地配置、生成配置、签名、原生二进制、数据库、截图与测试夹具均忽略。GitHub 目标仓库为 gscsdx/HmChat；仓库本地提交身份为 HmChat 与用户授权公开的邮箱。初次公开将历史整理为唯一的 init 提交，旧历史备份仅保留本机忽略目录。

## 后续工作与缺口

通知权限、后台送达和点击同步仍属于后续工作，须独立实现及真机验证。

按完整 Web A 矩阵继续推进真实文件夹/归档、服务器搜索、完整资料与共享媒体、消息多选/置顶/反应、贴纸/GIF、文件/语音/视频、完整设置、群与频道管理、多账号、通知后台及通话。不可操作的占位入口不能算完成，普通本地筛选不能代替云端文件夹或搜索。

现有链路仍需覆盖历史跨页精确锚点、分页中切换聊天、完整引用上下文定位、双端已读语义、媒体异常和取消缓存清理、图片说明编辑、其他聊天类型的转发/删除权限及复制。引用点击仅在短历史中观察到滚动变化，不代表跨页定位已完成。图片双指连续手势待实测。其他形态后置，不能用本机单栏通过推断全设备通过。

## 搜索可发现性（2026-10-31）

统一 GitHub 简介、中英文 README 首段与官网标题/描述，明确「鸿蒙 HarmonyOS NEXT 原生 Telegram 第三方客户端」；官网中英文切换同步 metadata。新增官网 sitemap，仅列 canonical 首页，不将同页语言切换虚构成独立 URL。此次发布仅包含搜索介绍调整，不包含本机未提交的多账号、媒体等功能。

Google Search Console 的 URL 前缀属性验证、网址检查与申请收录仍需拥有者 Google 账号完成；没有将发布或 sitemap 当作 Google 已收录的证据。

验证：`node --check website/app.js`、中英文 metadata 切换检查、HTML metadata 与 sitemap 一致性、`git diff --cached --check` 以及隔离完整 index 的公开安全检查通过（163 个文件）。仅文档/网站改动，未运行应用编译或设备测试。

发布结果：搜索介绍专用提交 `4c80480` 已推送远端 main；GitHub Pages run `41186208825` 成功，线上首页标题、中英文 metadata 脚本及 sitemap 均 HTTP 200 并核对内容通过。GitHub About 简介已更新。本机仍留在原 `feat/multi-account` 分支、保留既有未提交改动与 index；远端 main 已前进，后续集成应先检查分支差异。Google 收录仍未验证。

## 2026-10-31 存储管理

已新增真实账户「设置 → 数据与存储 → 存储管理」，参考用户提供的 Nicegram 截图，使用 SDK 26 ArkUI 原生圆环、分类 Checkbox、响应式设置行、Toggle 和确认弹层。TDLib 负责真实分类统计、按类别/会话清理和网络用量；增加每账户独立的私聊/群组/频道保留期限、媒体缓存上限及 Wi-Fi/移动/漫游的图片/视频/动图自动下载策略。未知网络/文件大小默认不自动下载；视频/动图默认按需手动下载，漫游默认关闭。组件状态刷新与已保存偏好分开处理，失败可见。

所有清理经 optimizeStorage 的非空文件类型白名单，显式填写限制，禁止隐式默认广泛清理；跳过当前/待发送会话，秘密/安全/未知文件不可选择。自动维护排除秘密和未知类型会话、归属不明文件，TTL/上限不交叉启用 TDLib 默认限制。旧账户请求和忙状态不能污染新账户，统计/清理提供 30 秒超时及迟到响应隔离。清理后重新读取文件状态，不删除云端消息、数据库、Asset 或上传暂存。

验证层次：

- **源码实现**：StorageModels、StorageManager、MediaNetworkMonitor、StoragePage、TelegramClient 与设置入口完成；新增正常权限 GET_NETWORK_INFO，未修改签名或 API 私密配置。
- **宿主机验证**：`./scripts/test-domain.sh` 292 项全部通过，覆盖类型白名单、网络/大小策略、超时、GC 文件刷新、账户隔离与切换竞态、TTL/上限独立限制及秘密/未知会话保护。结果 `artifacts/storage-tests.log`。
- **SDK 编译**：`./scripts/build.sh` 真实 SDK 26 编译签名通过；最终 `artifacts/storage-build.log`。不能用宿主转译代替该结果。
- **设备安装/启动**：指定 HOP-AL00 / API 26 未展开真机，正常 signed HAP 覆盖安装和 EntryAbility 启动通过，登录保持；`storage-install.log`、`storage-run.log`。未运行 ohosTest 或卸载循环。
- **真实 TDLib/云端媒体验证**：读取媒体缓存初始 10.0 MB、设备剩余空间及累计网络用量；只选视频，取消确认后保留，再按收藏夹范围清理，TDLib 实际释放 816 KB、分类统计移除视频、总量降至 9.2 MB。重开合成测试视频，AVPlayer 播放至 0:08；该素材可能仍使用已保留的上传暂存，不能单独作为云端重下载证据，网络重新下载待专项验收。既有云端测试消息保留，没有发送新消息或删除云端内容。收藏夹原草稿逐字比对保持 true。
- **设置实测**：修正 Builder 参数导致的开关/摘要刷新问题，图片自动下载关闭后正常冷启动仍关闭，重新开启正常；大小选择已从 20 MB 改为 5 MB 并跨冷启动读取，最终恢复 20 MB，视频/动图保持关闭；私聊期限五个选项真实弹出后取消。TTL 实际老文件淘汰、缓存达到上限时的真实大容量淘汰和网络切换/真实漫游尚未取得设备证据，仅有协议/逻辑回归。

原始存储、设置、收藏夹及播放截图都只在 ignored artifacts，不登记为公开资产；中英文 README、架构、UI、响应式记录、路线图和 Web A F09 已同步范围。完整说明见 [STORAGE_MANAGEMENT.md](STORAGE_MANAGEMENT.md)。

限制：仅维护当前连接账户；自动清理在应用进程运行/进入前台时尝试，非杀进程后的后台定时保证。受保护/正在使用文件可能令总量高于所选上限。上传暂存只读且保留，安全回收索引、逐媒体浏览清理、联系人级下载例外、自动保存相册、边下边播及多形态实测仍待实现。未宣称 Nicegram 全设置或 Web A 全面对齐。

存储验收操作说明：一次固定坐标测试在页面切换完成前打开了设置页的退出确认，已取消，未执行退出；之后改为检查收藏夹 TextArea/草稿后再操作媒体。最终覆盖安装后登录保持，存储页的「当前账户缓存」已再次检查，手机留在该页。后续设备脚本不要只靠固定延迟或背景中的同名文本判断页面已进入。
