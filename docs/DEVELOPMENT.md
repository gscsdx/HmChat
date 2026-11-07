# 本地开发与验证

## 前置环境

安装 DevEco Studio 及工程要求的 HarmonyOS SDK，保留已有 `build-profile.json5` 签名配置。当前工程的 `targetSdkVersion` 为 `26.0.0`，兼容版本为 `6.1.1(24)`；这属于本机已有基础工程配置。

所有脚本使用 Bash，支持含空格的路径，可从任意工作目录执行。默认工具目录是 `/Applications/DevEco-Studio.app/Contents`，优先使用其自带 Node、JBR、Hvigor 和 SDK hdc。不要求全局安装 Node、Java、Hvigor。

```bash
./scripts/doctor.sh
./scripts/build.sh
./scripts/install.sh
./scripts/run.sh
./scripts/screenshot.sh
```

`build.sh` 默认构建 debug，可传入 `release`。构建包含原生 C++、ArkTS 编译与 HAP 签名。默认安装产物：`entry/build/default/outputs/default/entry-default-signed.hap`；`install.sh /绝对路径/文件.hap` 可指定产物。安装采用更新方式，不主动卸载或清除应用数据。

脚本不会打印或修改签名密码。签名成功需以 Hvigor 的 `SignHap` 和最终 `BUILD SUCCESSFUL` 输出为准。不要将完整签名配置贴到聊天、日志或提交记录。不要并发启动多个构建；`build.sh` 带有本工程的进程锁。如果异常中断留下锁，确认没有正在运行的构建后才移除 `.hvigor/harlgram-build.lock`。

## 设备与模拟器

```bash
./scripts/emulator.sh list
./scripts/emulator.sh start "Pura 90 Pro"
./scripts/doctor.sh
```

`start` 仅启动已经存在的同名实例，不新建、不重置、不下载镜像。启动命令可能持续运行以维持模拟器进程，建议在单独终端执行。模拟器首次启动需稍等，直到 `doctor.sh` 的设备列表出现目标。当前机器已有 `Pura 90 Pro`，使用 HarmonyOS 7.0.0 / API 26 arm64 镜像；该名称并非其他机器的默认要求。

当前开发约定优先使用用户连接的真机。2026-10-29 通过只读系统参数确认该真机型号为 `HOP-AL00`、API 为 `26`、系统标识为 `OpenHarmony-7.0.0.105`。后续安装和验收用 `HDC_TARGET` 明确选定真机，不因模拟器在线而更换验证目标。设备序列号属于本机环境信息，不写入工程默认值。

设备只有一个时自动选择；多个设备时必须显式传入 `HDC_TARGET`，脚本校验目标存在，不猜测设备：

```bash
HDC_TARGET='127.0.0.1:5555' ./scripts/install.sh
HDC_TARGET='127.0.0.1:5555' ./scripts/run.sh
HDC_TARGET='127.0.0.1:5555' ./scripts/screenshot.sh artifacts/screenshots/chats.png
```

截图通过设备 `snapshot_display` 生成并取回，默认保存在 `artifacts/screenshots/`。截图可能包含消息或个人信息，提交前先检查。截图脚本仅清理自己生成的设备临时文件。

## 路径覆盖与依赖安装

```bash
DEVECO_HOME='/Applications/DevEco-Studio.app' ./scripts/doctor.sh
DEVECO_HOME='/Applications/DevEco-Studio.app/Contents' ./scripts/build.sh
```

可按需要设置 `DEVECO_SDK_HOME`、`HARLGRAM_NODE_HOME`、`HARLGRAM_JAVA_HOME`、`HVIGOR_BIN`、`HDC_BIN`、`EMULATOR_BIN`。脚本用专用覆盖变量设置 `NODE_HOME`、`JAVA_HOME`，避免 shell 中其他工程的旧版 Java 影响 DevEco 构建。应用标识可用 `HARLGRAM_BUNDLE`、`HARLGRAM_ABILITY` 覆盖，默认与工程一致。切换 SDK 或 DevEco 后，先运行环境检查再构建。

首次获取工程如果没有 `oh_modules/`，在项目根目录执行：

```bash
bash -c 'source scripts/env.sh; ohpm install'
```

不要修改 lockfile 以绕过编译问题。`local.properties` 属于机器配置，不提交。

## 缓存目录布局（Windows）

本机把工程内可再生的缓存、日志、构建产物与依赖目录统一放到工程外的缓存根（`<cache-root>`），工程目录只保留源码与配置。工程内仍保留同名入口，通过 Windows 目录联接指向缓存根，因此脚本、测试和 DevEco 继续使用原有相对路径：

| 工程内入口 | 缓存根目录 | 内容 |
| --- | --- | --- |
| `.local/` | `local/` | TDLib/OpenSSL 源码、编译缓存、离线数据 |
| `artifacts/` | `artifacts/` | 测试日志、截图、设备布局等本机证据 |
| `.hvigor/` | `project-cache/` | 构建锁与 hvigor 工程缓存 |
| `.appanalyzer/` | `appanalyzer/` | DevEco 分析器缓存 |
| `entry/build/` | `build/` | HAP 构建产物 |
| `entry/.cxx/`、`entry/.preview/`、`entry/.test/` | `cxx/`、`preview/`、`test/` | Native、预览与测试缓存 |
| `oh_modules/`、`node_modules/` | 同名目录 | 工程依赖 |

初始化或修复联接：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\cache-layout.ps1
```

首次迁移用户级 hvigor 缓存（复制到缓存根，原目录保留）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\cache-layout.ps1 -MigrateUserHome
```

`scripts/env.sh` 在 Windows 上默认 `HARLGRAM_CACHE_HOME=<cache-root>`，并只为本仓库脚本导出 `HVIGOR_USER_HOME=<缓存根>/user-home`；不修改系统环境变量，也不影响其他鸿蒙工程。可用 `HARLGRAM_CACHE_HOME` 覆盖缓存根。

DevEco 的 clean 或重新安装依赖可能删除联接并在工程内重建真实目录。`build.sh` 会在构建前自动修复；从 DevEco 直接构建前若发现缓存又回到工程内，重新运行 `cache-layout.ps1` 即可。脚本不会自动删除非空真实目录，而是提示先迁移数据。

## 验证记录与排障

2026-10-29 已在本机通过原始 Hello World 工程的命令行 `assembleHap` 和 `SignHap`，确认无需操作 DevEco UI 即可构建和签名。工具版本为 Node `v24.14.1`、JBR `25.0.2`。基线 HAP 在上述 Pura 90 Pro 模拟器完成脚本安装、启动与 1256 × 2760 PNG 截图验证。该系统的 `snapshot_display` 默认要求 JPEG，脚本通过 `-t png` 显式选择 PNG。功能代码的最终构建和交互验收须以本轮实际验证记录为准，基线成功不表示后续代码已验证。

- 构建缺少 SDK：检查 `DEVECO_SDK_HOME` 与 DevEco SDK Manager 中已安装版本。
- 安装失败：先确认运行的是 signed HAP，再检查设备系统 API、签名与设备授权。
- 没有设备：启动已有模拟器，或连接已开启调试并完成授权的真机。
- 页面空白或崩溃：结合设备 `hdc shell hilog` 与 `aa start` 输出诊断，不把安装成功当作功能验收。
- UI 验证应覆盖会话列表、搜索、聊天输入与返回、设置及重启后的本地状态，并保存必要截图。

涉及 Telegram 登录、验证码、二步验证密码或真实发送消息时，使用专门测试账号与明确授权，不能把本地演示收发写成网络验证通过。

## 当前设备授权与去敏采集

2026-10-29 用户明确授权拔掉真机后启动手机模拟器继续功能测试，已使用 Pura 90 Pro。每次仍显式指定 HDC_TARGET，不能把模拟器通过写成真机通过。`scripts/device-layout.sh` 只输出组件数量与几何摘要，原始树写入 ignored artifacts；空树表示目标窗口未在前台或测试结束，不应据此推断账号退出。

不得在已登录用户账号的设备上安装/卸载同 bundle 的 ohosTest 包。本轮尝试的恢复测试已撤回，测试框架结果没有计为通过。设备原生包装测试需在无用户数据的隔离环境运行。

当模拟器 HDC 文件传输卡住但 shell 可用时，可显式运行 `python3 scripts/install-via-shell.py <hdc路径> <目标> <signed.hap>`。该脚本仅在自有临时目录分块传输，比对完整 SHA-256 后由 bm install 覆盖安装；不会终止其他 HDC 客户端。正常传输仍优先 install.sh。

安装、截图、布局采集均可设置 `HARLGRAM_HDC_TRANSFER=shell`，用于本轮模拟器的文件通道故障；普通模式仍优先HDC file命令。

## 官网进度文档

现有功能维护在 `docs/FEATURES.md` / `docs/FEATURES.en.md`，路线图维护在 `docs/ROADMAP.md` / `docs/ROADMAP.en.md`，更新日志维护在根目录 `CHANGELOG.md` / `CHANGELOG.en.md`。更新后执行 `python3 scripts/build-website.py`，提交 Markdown 和生成的官网页面。`python3 scripts/build-website.py --check` 检查是否同步；CI 会拒绝过期页面。官网只部署 `website/`，不上传整个工程。中文为默认语言，独立页面无需 JavaScript 也可阅读；英文通过原有语言按钮切换。
