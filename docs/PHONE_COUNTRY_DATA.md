# 国家区号离线数据

登录区号选择器使用 `entry/src/main/ets/data/PhoneCountries.ts` 中的静态数据，共 245 个国家和地区。运行时没有网络查询、第三方 npm 包或 libphonenumber 运行库依赖。

## 固定来源与许可

- 区号与地区标识：[Google libphonenumber v9.0.18 PhoneNumberMetadata.xml](https://github.com/google/libphonenumber/blob/v9.0.18/resources/PhoneNumberMetadata.xml)。提取每个地理 `territory` 的 `id`、`countryCode` 和 `mainCountryForCode`，排除非地理全球服务的 `001`。Copyright (C) 2009 The Libphonenumber Authors，Apache License 2.0。完整许可随应用保存为 `rawfile/licenses/Libphonenumber.txt`。
- 中文、英文名称：[Unicode CLDR release-47 zh.xml](https://github.com/unicode-org/cldr/blob/release-47/common/main/zh.xml) 与 [en.xml](https://github.com/unicode-org/cldr/blob/release-47/common/main/en.xml)。提取非 `alt` 的地区显示名称，保留上游名称。使用 [Unicode License V3](https://github.com/unicode-org/cldr/blob/release-47/LICENSE)，完整许可随应用保存为 `rawfile/licenses/Unicode-CLDR.txt`。

这是一份固定、可复现的数据快照，不宣称是最新号码规划。生成结果包含源版本、版权与许可注释。以后更新版本时必须更新 SHA-256、覆盖数量、生成数据和对应测试；不能手工猜测区号。共享区号的默认地区取上游 `mainCountryForCode`，不会根据号码归属或语言推断用户国籍。

## 再生成与核验

```bash
# 首次获取固定来源；仅使用 Python 标准库，不全局安装依赖。
python3 scripts/generate-phone-countries.py
# 缓存齐全后可完全离线再生成、核验已提交的数据与许可文本。
python3 scripts/generate-phone-countries.py --offline
python3 scripts/generate-phone-countries.py --offline --check
./scripts/test-domain.sh
```

原始 XML 和许可缓存在被忽略的 `.local/third_party/phone-country-data/`。生成脚本对下载和每次缓存读取均检查固定 SHA-256；不匹配时失败，拒绝覆盖生成结果。所有来源和完整校验值写在脚本 `SOURCES` 中。

## 手机号逻辑边界

`model/PhoneNumber.ts` 导出 `PhoneCountry`、`PHONE_COUNTRIES`、`findPhoneCountry`、`searchPhoneCountries`、`PhoneInputParts`、`splitInternationalPhone`、`PhoneNormalization` 和 `normalizePhoneNumber`。

- 只有明确以 `+` 或 `00` 开头的完整国际号码才拆分；普通号码开头与某个国家区号相同，不触发自动换国家。
- 共享区号优先保留当前已选且区号匹配的地区，否则使用上游明确主地区；未明确的共享情况返回空 `countryIso`，不凭空选择。
- 完整国际号码优先于区号输入框，不重复拼区号。手动区号允许 1—3 位非零开头数字，不要求出现在国家列表中。
- 去空白、括号、句点和连字符等常见分隔符；字母、嵌入的加号和超长号码会返回中文错误。合计 6—15 位数字，与当前 TelegramClient 的提交格式约束一致。
- 保留本地号码中的前导零，包括意大利号码中的有效零；不按猜测删除其他国家的国内长途前缀。该模块只检查输入格式，不验证号码是否已分配、支持移动业务或拥有 Telegram 账号，最终由 Telegram 鉴权处理。

回归覆盖中国号码组合、国家切换、北美共享区号、英国国际号码粘贴、空值/非法文本/超长号码、意大利前导零与中英文/ISO/区号搜索。
