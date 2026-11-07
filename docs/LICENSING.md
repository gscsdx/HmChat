# 许可、来源与分发边界

核验日期：2026-10-29。本文对应本仓库当前源码、固定原生依赖和已安装 Native SDK，不是对所有未来贡献或所有应用市场的合规认证。本次初始公开只提供源码，不发布二进制 HAP；真实账号联调成功不等于具备完整客户端功能或已完成发布审查。

## 项目许可

除文件内或 [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) 另有声明的第三方材料外，HmChat 项目自有代码、脚本、文档和资源按 **GPL-3.0-or-later** 授权：可依 GNU General Public License 第 3 版，或自行选择任何更高版本使用、修改和分发；不提供保证。英文授权表述为：

> HmChat is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

[LICENSE](../LICENSE) 保留完整 GPL v3 文本，包括责任限制；上面的「或更高版本」是本项目的授权选择。第三方数据与库继续适用各自许可，不重写其版权或移除上游通知。项目开放代码与资源不表示授予 Telegram、Huawei 等第三方商标权。

Android 已检查源码头允许 GPL-2.0-or-later，Web A 明确为 GPL-3.0-or-later。当前工程记录为行为与架构参考，未直接复制这些客户端实现文件；不能将其称为已完成的 Android / Web A 源码移植。以后复制或翻译实现时应按具体文件核对权利、保留原始署名和改动声明；单纯选择 GPL v3 不替代来源记录。实际引入的 TDLib、OpenSSL、SQLCipher、LLVM runtime 和电话数据分别记录在第三方通知中。

## 实际构建的来源记录

| 输入 | 固定标识与可复查来源 |
| --- | --- |
| TDLib | 1.8.69；[4c6377aa7386c39217878a9a56d581922ad37ca4](https://github.com/tdlib/td/tree/4c6377aa7386c39217878a9a56d581922ad37ca4)；包括同一提交内 SQLCipher / SQLite 代码与宿主机 tl-parser |
| TDLib 本地修改 | [build-tdlib.sh](../scripts/build-tdlib.sh) 内可重复应用的两处补丁：无版本 SONAME；OHOS 下禁用可选 pthread affinity。上游作者与许可头不变 |
| OpenSSL | [openssl-3.5.9.tar.gz](https://github.com/openssl/openssl/releases/download/openssl-3.5.9/openssl-3.5.9.tar.gz)；SHA-256 `603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a`；配置参数保存在构建脚本 |
| LLVM runtime | 本机 DevEco Native SDK 26.0.0.105，编译器显示 Clang 15.0.4；SDK 自带 `llvm/NOTICE`，SHA-256 `22208a1d78a9271ec1d6eaf7d21db5dda6049ed14af09d7d0f8d7787b6bffb77`。不能从编译器版本反推出供应方运行库的准确 LLVM Git 提交 |
| arm64 runtime 原件 | SDK `llvm/lib/aarch64-linux-ohos/libc++_shared.so`，SHA-256 `f69947af100b652e349ae51e4a4888bcc7a327db9085272d318176ef1782bf0f`。打包工具若 strip 会改变文件哈希，此值用于识别 SDK 输入，不是所有 HAP 内文件的保证值 |
| 电话数据 | libphonenumber v9.0.18 / CLDR release-47；各输入 URL、SHA-256 与生成命令见 [PHONE_COUNTRY_DATA.md](PHONE_COUNTRY_DATA.md) |

实际 TDLib 链接配置启用了 OpenSSL 和 zlib，未启用 Abseil / 外部 CRC32C。TDLib 的 `tdsqlite` 编入加密扩展，不能只列为公有领域 SQLite。`libc++_shared.so` 随 HAP 分发，不能因为由 SDK 提供就省略其许可。BoringSSL 只存在于 Android 参考工程的依赖范围，不是本构建的加密库。

许可全文保存在 [rawfile/licenses](../entry/src/main/resources/rawfile/licenses)。`package` 阶段逐份复制对应来源文件，含 SQLCipher、SDK LLVM 完整通知、项目 GPL 及第三方通知。SDK LLVM 集合中的 libc++ / libc++abi 条目保留 Apache 2.0、LLVM Exceptions 和历史 MIT / University of Illinois 声明；[LLVM 上游 libc++abi 许可](https://github.com/llvm/llvm-project/blob/llvmorg-15.0.4/libcxxabi/LICENSE.TXT) 可辅助解释许可结构，但不能当作本机供应方 SDK 源码提交的证明。

## 将来分发 HAP 时

源码公开和发布编译包是不同的交付动作。将来提供 HAP 前，发布者应完成以下具体材料与检查；这里没有声明它们已经全部完成：

1. 选择与二进制对应的公开 Git 提交，提供 GPL 要求的完整对应源代码及控制编译、安装所需脚本，保留文件通知与修改记录。对被包含、修改的第三方源代码同时保留其各自许可。固定上游 URL 有助于重建，但不自动等同于已经履行 GPL 第 6 条的源代码提供方式；发布者需保证接收者能够按采用的分发方式实际取得对应源码，不能仅依赖随时可能失效的外部链接。
2. 检查最终 HAP 和同行分发文档确实含许可与版权通知，包括 SQLCipher、OpenSSL、LLVM runtime、电话数据以及项目 GPL。更换 SDK、ABI、静态链接项或数据版本后重新核对；不得以库顶层单一许可证代替其内嵌第三方通知。
3. 保存实际版本、构建选项、补丁和包哈希，说明所需 DevEco / SDK 及获取途径。构建脚本目前支持复现构建步骤，不承诺不同主机上字节完全一致；SDK 的非开源部分不由本项目重新分发或授权。GPL 对 System Libraries 和通用构建工具的边界以许可原文为准，不把整个系统 SDK 误称为项目对应源码。
4. 使用发布者自行申请的 Telegram API 身份，并复查下面的服务条款与功能缺口。检查商店描述、应用内介绍、隐私说明与实际行为一致，再决定是否发布。当前无 HAP release，不应把 GitHub 源码仓库标成已通过正式发行验收。

## Telegram API、商标与数据

代码许可证不等于 Telegram 服务接入许可。[Telegram API Terms of Service](https://core.telegram.org/api/terms) 是独立约束；以下是与本项目直接有关的摘要，实际使用仍应核对官方当时条款：

- 自行申请应用 API ID，显著说明使用 Telegram API 与第三方身份；标题、官方图标和品牌使用有独立限制。HmChat 不使用官方应用凭据；本地配置与生成配置不进 Git。
- 客户端基本行为须与其他客户端正确互通，不得干扰已读、在线、输入状态或自毁内容等行为。当前工程仍缺输入状态等完整能力，不能因基础收发通过就宣称已验证全部要求。
- 允许查看频道内容的应用须支持官方赞助消息。本工程目前可以打开频道，但尚未实现相应展示、交互与统计链路；这是正式客户端分发前必须解决并验证的明确缺口，不将其包装成屏蔽广告功能。
- 内容与 AI 用途另受 [Content Licensing and AI Scraping 条款](https://telegram.org/tos/content-licensing) 约束。该限制不只涉及模型训练；API 条款还涉及利用平台数据开展 AI / ML 开发、增强和部署。仓库的「AI-native」表示 agent 协作开发、脚本与证据流程，不表示把用户 Telegram 数据交给模型处理，也不声称获得这样的授权。

完整功能与验证缺口以 [Web A 对照矩阵](TELEGRAM_WEB_PARITY.md) 和 [STATUS.md](STATUS.md) 为准。功能基线、开源许可和平台服务条款需要分别满足；一个维度通过不能代替其他维度。
