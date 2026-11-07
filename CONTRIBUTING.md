# 参与 HmChat

欢迎问题报告、原生交互改进、协议回归测试、文档和功能贡献。项目处于早期开发阶段，当前目标是用 HarmonyOS 官方 ArkUI 对齐 Telegram Web A 手机尺寸的功能。开始前请读 [README](README.md)、[AGENTS.md](AGENTS.md)、[当前状态](docs/STATUS.md) 和 [功能矩阵](docs/TELEGRAM_WEB_PARITY.md)。

中文和英文 Issue / PR 均可。English contributors can start with [README.en.md](README.en.md); the workflow below applies to both human and AI-assisted contributions.

## 选择一个可验收的改动

先搜索已有 Issue 和功能矩阵。较大功能建议先开 Issue，说明用户场景、Web A 的对应行为、鸿蒙原生交互和预期范围。小修复可以直接提交 PR。安全漏洞不要开公开 Issue，使用 [安全报告流程](SECURITY.md)。

问题报告请提供：版本或 commit、OS/API 版本、设备类别或窗口宽度、预期行为、实际行为和最小复现步骤。请区分离线演示、Preview mock 与真实账号；纯 UI 现象不一定是服务端问题。日志只保留必要的去敏错误类别和调用阶段，截图使用虚构内容或彻底遮挡。

## 本机开发

按 [README 的源码构建步骤](README.md#从源码开始) 初始化。首次 `setup.sh` 会复制缺失模板并启用 `.githooks`，不覆盖已有 API 或签名。完整环境、原生依赖和设备脚本见 [开发手册](docs/DEVELOPMENT.md)。

- 只有构建者需要自有 Telegram API 身份；真实值只写入被忽略的 `config/telegram.local.json`。
- 不提交 `build-profile.json5`、证书、生成 API 配置、Native 二进制、设备数据和构建产物。
- API 配置、签名和用户登录分别管理，不为方便联调替换别人的签名。
- 不同时运行多个 Hvigor 构建。共享工作目录时先约定文件所有权，不回退其他贡献者或 agent 的改动。

## 实现原则

1. **先核对源码。** TDLib 请求以固定版本 schema 为准，保留 `int64` 字符串语义、请求关联、延迟回包和错误处理。升级依赖时同步来源、哈希、许可与回归用例。
2. **保持模块边界。** 可独立测试的模型与协议逻辑放 `.ts`，HarmonyOS Kit 与生命周期放 `.ets`；C++ 桥只负责受控传输。ArkTS 需要实际 SDK 编译，不能以普通 TypeScript 检查替代。
3. **采用平台组件。** 导航、菜单、弹层、系统选择器与底栏优先使用 SDK 26 官方能力；不引入 Android UI 或 WebView 作为客户端界面的替代实现。
4. **等待真实结果。** 不用本地写入、`ok` 或 mock 返回伪造云端发送、认证或权限成功。失败时保留用户可以继续编辑的内容。
5. **记录实际范围。** 按可用窗口宽度适配；静态展开截图不等于折叠切换验收。未完成项继续标为未验证。

## 运行相关验证

领域与配置检查不需要真实账号：

```bash
./scripts/test-domain.sh
python3 scripts/check-public-tree.py
```

仅需纯逻辑开发、没有 DevEco 时，可使用 Node 22 与本地固定版本 TypeScript，方式与 CI 一致：

```bash
npm install --prefix .local/ci --no-audit --no-fund --ignore-scripts --save-exact typescript@5.8.3
export HARLGRAM_NODE_HOME="$(dirname "$(dirname "$(command -v node)")")"
export HARLGRAM_TYPESCRIPT="$PWD/.local/ci/node_modules/typescript/lib/typescript.js"
./scripts/test-domain.sh
```

修改 ArkTS / Native 后，在具备对应 SDK 和签名的环境执行：

```bash
./scripts/build.sh
HDC_TARGET='<device-id>' ./scripts/install.sh
HDC_TARGET='<device-id>' ./scripts/run.sh
```

这三类结果分别报告：**宿主机测试、SDK 构建、设备与服务端验收**。没有设备时如实写「未执行」，不要把 CI 绿灯当作真机通过。测试应覆盖有风险的行为，例如草稿竞争、权限刷新和失败恢复；纯文档修改无需为了凑检查而运行设备流程。

`check-public-tree.py` 检查 Git 索引中的公开文件；提交前运行 `python3 scripts/check-public-tree.py --staged` 并人工审阅暂存内容。扫描器不能替代对截图、二进制和上下文的人工检查，也不代表已审查完整历史。

## 保护真实账号与数据

默认使用虚构夹具。真实账号操作需要账号所有者对具体场景的授权；本人输入手机号、验证码与密码。不要自动向联系人发消息，不上传私人照片，不使用他人的账号内容作为破坏性测试材料。

设备验收优先指定真机，所有命令明确 `HDC_TARGET`。保留已有草稿与登录状态，安装使用相同身份的正常 HAP 覆盖方式。**不得在持有真实账号的实例上循环安装/卸载同 bundle 的 ohosTest，不得清数据库、导出密钥或用新密钥尝试旧数据库。** 需要测试包时，使用无用户数据的隔离实例。详见 [设备记录](docs/DEVICE_TESTING.md)。

## 提交 PR

一个 PR 解决一个清楚的问题，说明变更前后的行为、主要实现决策和相关验证。UI 改动附安全的截图或录屏；协议改动列出固定 schema 依据；依赖或素材改动补来源与许可。

在 PR 中明确未验证的设备、错误路径及后续工作。更新相关说明和 `docs/STATUS.md`；只有完成独立验收后才调整功能矩阵的状态。不要加入真实设备序列号、本机用户名路径、账号标识或消息正文。

AI 辅助贡献遵守同样的审查标准：贡献者负责核对生成代码、依赖、测试结果和许可，不能把工具声称成功当作执行证据。详细接力规则见 [AI_WORKFLOW.md](docs/AI_WORKFLOW.md)。

贡献需与本项目 [GPL-3.0-or-later](LICENSE) 及相关第三方许可兼容。不要提交无权公开的代码、资产或账号数据；参考实现与实际复制代码必须在来源记录中区分。
