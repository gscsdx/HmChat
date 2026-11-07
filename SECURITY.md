# 安全政策 / Security policy

HmChat 是早期、实验性的非官方 Telegram 客户端。当前没有稳定版本维护矩阵、安全审计认证或修复时限承诺；安全修复主要面向默认开发分支。具体已知限制以 [当前状态](docs/STATUS.md) 为准。

## 私下报告漏洞

请发送邮件至 **[garychangcn@hotmail.com](mailto:garychangcn@hotmail.com)**，主题建议为 `HmChat security report`。不要在公开 Issue、PR 或讨论中发布可利用细节、密钥或用户数据。普通功能问题可使用 GitHub Issues。

初次报告请包含：

- 受影响的 commit / 版本、OS/API 版本和相关功能。
- 影响、必要前提，以及使用虚构数据的最小复现步骤。
- 去敏错误类别或最小代码片段；如有修复建议可一并说明。
- 方便回复的联系方式及希望采用的公开署名；不希望公开身份可说明。

不要发送 API Hash、验证码、密码、会话文件、数据库、数据库密钥、签名私钥、未遮挡截图或真实消息。首次报告以文字描述为主；不要直接通过邮件附带含敏感内容的原始产物。若确需进一步材料，先与维护者商议最小化与安全交付方式。

收到报告后，维护者会根据可复现性、影响与可用时间评估处理；目前不承诺固定响应时限或奖金。请在细节公开前协调披露时间，避免让尚未修复的问题影响使用者。

## 测试边界

只对你拥有或明确获授权的账号、设备和环境测试。不要获取他人的消息或认证材料，不要向真实联系人群发或发送测试内容，不进行服务滥用或破坏性测试。使用隔离数据，不以清空用户沙箱或卸载已登录应用作为排障手段。

发现数据暴露时应停止扩大访问，只记录足以说明问题的去敏证据。已经公开的秘密即使删除提交也可能已被复制；应通过对应服务或签名管理工具撤销、轮换并审查暴露范围，不把移除文件视为完整补救。

## 数据与加密说明

数据库密钥由 HarmonyOS Asset 管理，TDLib 数据库保存在应用沙箱中。此设计不等于本项目已经完成独立安全审计，也不表示普通 Telegram 云端聊天具有端到端加密。当前没有实现 Secret Chats。

构建时 API 身份需要随客户端运行使用，不能当作永不离开服务器的秘密。它仍不应出现在源码仓库或诊断输出中；更不能在构建配置中存放用户密码、验证码或会话密钥。

AI-native 是开发流程，不授权工具读取或发布真实账号数据。公开展示图片只能使用虚构内容或经过人工确认的隐私遮挡版本。

---

## English

HmChat is an experimental, unofficial client. There is no stable-version support matrix, independent security-audit certification, guaranteed response time, or bounty program. Security fixes currently target the default development branch.

Report suspected vulnerabilities privately to **[garychangcn@hotmail.com](mailto:garychangcn@hotmail.com)** with the subject `HmChat security report`. Include the affected commit/version, OS/API version, impact, prerequisites, and minimal reproduction steps using fictional data. Include only sanitized evidence and coordinate disclosure before publishing exploit details.

Do not send API hashes, verification codes, passwords, session files, databases, encryption/signing keys, real messages, or unredacted screenshots. Describe the issue first; agree on a minimal, safe transfer method before sharing any sensitive artifact. Reports are assessed according to reproducibility, impact, and maintainer availability.

Test only accounts and environments you own or are explicitly authorized to use. Do not access others' data, send test messages to real contacts, abuse services, or clear a signed-in user's app data. Stop expanding access if you discover exposure. Deleting a leaked secret from Git does not revoke it; rotate or revoke it through the relevant service and assess exposure separately.

Asset-backed key storage and TDLib's sandbox database are not an audit claim or a claim that ordinary cloud chats are end-to-end encrypted. Secret Chats are not implemented. Build-time API identity is used by the distributed client and is not a server-only secret; it must still stay out of public source and diagnostics. AI-assisted development does not authorize access to or publication of account data.
