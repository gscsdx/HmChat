# 第三方来源与许可

Harlgram 是独立、非官方的 HarmonyOS NEXT Telegram 客户端，不代表 Telegram，也不隶属于 Telegram。除下列第三方材料或文件内另有声明的部分，项目自有代码、脚本、文档和资源采用 **GNU GPL v3 或更高版本（GPL-3.0-or-later）**，完整文本见 [LICENSE](LICENSE)。第三方材料保留各自版权与许可，不因放入本仓库而改用 GPL。

核验日期：2026-10-29。此清单区分源码参考、实际运行依赖和构建工具；开源与后续二进制分发要求见 [许可与分发说明](docs/LICENSING.md)。本次初始公开提供源码，不发布 HAP，也不表示已满足完整 Telegram 客户端的所有功能和 API 条款。

## 实际运行依赖与数据

| 组件 | 固定来源与用途 | 许可及随包全文 |
| --- | --- | --- |
| TDLib 1.8.69 | [tdlib/td，4c6377aa7386c39217878a9a56d581922ad37ca4](https://github.com/tdlib/td/tree/4c6377aa7386c39217878a9a56d581922ad37ca4)；OHOS 构建的 `libtdjson.so` | Boost Software License 1.0；[TDLib.txt](entry/src/main/resources/rawfile/licenses/TDLib.txt) |
| TDLib 内置 SQLCipher / SQLite | 同一 TDLib 提交中的 [sqlite/sqlite](https://github.com/tdlib/td/tree/4c6377aa7386c39217878a9a56d581922ad37ca4/sqlite/sqlite)；编译为 `tdsqlite` 并静态链接，启用 `SQLITE_HAS_CODEC`。底层 SQLite amalgamation 标注 3.31.0，不据此猜测 SQLCipher 的独立发行版本 | SQLCipher 为 BSD-3-Clause；[SQLCipher.txt](entry/src/main/resources/rawfile/licenses/SQLCipher.txt)。SQLite 原始部分为公有领域声明；含加密扩展的整体不能仅标成 SQLite 公有领域 |
| OpenSSL 3.5.9 | [官方版本源码](https://github.com/openssl/openssl/tree/openssl-3.5.9)；`libssl.a` / `libcrypto.a` 静态链接进 TDLib | Apache License 2.0；[OpenSSL.txt](entry/src/main/resources/rawfile/licenses/OpenSSL.txt) |
| LLVM C++ runtime | DevEco Native SDK `26.0.0.105` 提供、随 HAP 打包的 `libc++_shared.so`，包含 libc++ / libc++abi 运行支持 | Apache License 2.0 with LLVM Exceptions，并保留 SDK 通知中的历史许可；[LLVM.txt](entry/src/main/resources/rawfile/licenses/LLVM.txt) 为该 SDK `llvm/NOTICE` 的完整副本 |
| Google libphonenumber 数据 | [v9.0.18 元数据](https://github.com/google/libphonenumber/blob/v9.0.18/resources/PhoneNumberMetadata.xml)；生成地理地区与电话区号，无 libphonenumber 运行库 | Apache License 2.0；[Libphonenumber.txt](entry/src/main/resources/rawfile/licenses/Libphonenumber.txt) |
| Unicode CLDR 数据 | [release-47](https://github.com/unicode-org/cldr/tree/release-47)；生成中文、英文地区名称 | Unicode License V3；[Unicode-CLDR.txt](entry/src/main/resources/rawfile/licenses/Unicode-CLDR.txt) |

TDLib 已检查源码的版权头为 Copyright Aliaksei Levin, Arseny Smirnov 2014–2026；各文件原始署名仍以固定源码为准。SQLCipher 许可声明为 Copyright (c) 2008, ZETETIC LLC，源码内的后续年份署名随源代码保留。OpenSSL 上游声明 Copyright (c) 1998–2026 The OpenSSL Project Authors；Copyright (c) 1995–1998 Eric A. Young, Tim J. Hudson。LLVM 原作者、贡献者和历史版权声明保留在完整通知中。

`scripts/build-tdlib.sh` 固定 TDLib 提交、OpenSSL 压缩包 SHA-256 和两个 OHOS 兼容补丁。`package` 阶段更新 TDLib、SQLCipher、OpenSSL、SDK LLVM 的许可副本，以及项目 GPL 全文和本通知。电话数据生成与校验见 [PHONE_COUNTRY_DATA.md](docs/PHONE_COUNTRY_DATA.md)。原生二进制和第三方源码缓存不提交 Git。

当前加密依赖是 **OpenSSL，不是 BoringSSL**。参考 Android 仓库中的 BoringSSL、Web A 的 Teact / GramJS 及 npm 依赖没有因此进入本应用。当前 TDLib 构建未启用 Abseil 或外部 CRC32C。动态链接的 `libz.so`、`libc.so` 以及 HarmonyOS API 来自目标系统；构建脚本没有把这些系统库复制进 `entry/libs`。SDK zlib 头标注 1.3.1，版权所有者 Jean-loup Gailly、Mark Adler；它使用 zlib 许可。若更换为自行分发的系统库，应重新核对对应来源与通知。

LLVM.txt 保留了 SDK 的完整 LLVM 通知集合，含工具链其他组件条目；保留这些条目不表示所有工具链组件都被打包。DevEco Studio 和 HarmonyOS SDK 的安装、使用及非开源部分仍受供应方条款约束，本仓库不重新授权这些工具。

## 设计与行为参考

- **Telegram Android**：[DrKLO/Telegram，3de37c8cfb039452be7398909461da6288babf15](https://github.com/DrKLO/Telegram/tree/3de37c8cfb039452be7398909461da6288babf15)。仓库 [LICENSE](https://github.com/DrKLO/Telegram/blob/3de37c8cfb039452be7398909461da6288babf15/LICENSE) 是 GPL v2 全文；已阅读的 [ChatActivity.java 文件头](https://github.com/DrKLO/Telegram/blob/3de37c8cfb039452be7398909461da6288babf15/TMessagesProj/src/main/java/org/telegram/ui/ChatActivity.java#L1-L6) 明确允许 GPL v2 或更高版本，即 GPL-2.0-or-later。其第三方目录可能另有许可，不能概括为所有文件均只有 GPL。阅读范围与映射见 [TELEGRAM_SOURCE_MAP.md](docs/TELEGRAM_SOURCE_MAP.md)。
- **Telegram Web A**：[Ajaxy/telegram-tt，6002824b6532f3d913997ce496d9ab5f9b86bc22](https://github.com/Ajaxy/telegram-tt/tree/6002824b6532f3d913997ce496d9ab5f9b86bc22)，版本 12.0.48；[package.json](https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/package.json#L1-L6) 声明 GPL-3.0-or-later、作者 Alexander Zinchuk。[LICENSE](https://github.com/Ajaxy/telegram-tt/blob/6002824b6532f3d913997ce496d9ab5f9b86bc22/LICENSE) 提供 GPL v3 全文。功能对照见 [TELEGRAM_WEB_PARITY.md](docs/TELEGRAM_WEB_PARITY.md)。

按当前实现记录和源码审查，Android / Web A 用于理解架构、交互与功能，没有直接将其 Java / JNI 或 TypeScript / CSS 源文件、官方图标、用户数据或应用凭据复制进 Harlgram。ArkUI 呈现、领域逻辑与 Node-API 桥在本工程实现；协议字段以 TDLib schema 为依据。这是当前来源记录，不是对未来贡献的默认来源保证。以后复制、翻译或改编上游实现时，必须在具体文件保留作者、许可、固定来源与改动声明，并更新此清单。

## 仅用于构建的工具

TDLib 自带的 [tl-parser](https://github.com/tdlib/td/tree/4c6377aa7386c39217878a9a56d581922ad37ca4/td/generate/tl-parser) 源文件声明 GPL-2.0-or-later，原始版权包括 Vitaly Valtman 和 Vkontakte Ltd；它在宿主机构建并生成协议代码，不作为可执行程序链接或打包进 HAP。分发完整 TDLib 源码时仍须保留其目录内的 GPL 许可与源码头。CMake、Ninja、编译器、gperf、Python 和 Perl 等开发工具由开发者安装，不随应用分发。

## 名称、图标与 API

本项目的代码许可不授予 Telegram、HarmonyOS、Huawei 或其他第三方商标的使用权，也不表示官方认可。Harlgram 使用独立名称与项目图标；Telegram API 身份由开发者自行申请。商标、应用身份、内容与 AI 用途、频道赞助消息等另受 [Telegram API 条款](https://core.telegram.org/api/terms) 约束，不能用开源许可证替代这些条件。
