# 公开配图与隐私审查

更新：2026-10-29。

## 当前公开素材

| 文件 | 来源与处理 |
| --- | --- |
| `website/assets/app-phone.png` | Pura X Max 未展开真机的会话列表；所有头像、名称、消息摘要、时间、未读数与系统状态栏均遮挡，随后合成机身示意。 |
| `website/assets/app-unfolded.png` | 同一真机展开并打开会话后的双栏画面；会话列表、聊天标题、发送者、消息、引用和时间均遮挡，随后合成机身示意。 |
| `website/assets/icon.png` | 已采用的独立黑白图标，与应用图标同一设计；512×512 等比缩放版，用于网页与 favicon。设计记录见 [BRANDING.md](BRANDING.md)。 |
| `AppScope/resources/base/media/harlgram_icon.png` | 应用图标定稿，已移除不影响像素的生成元数据。 |

截图使用内置 **imagegen** 做隐私遮挡与机身合成。遮挡采用不透明色块，未用仍可辨认原始文字的轻度模糊。成品逐张人工查看，并使用本机 OCR 复核；识别结果仅含公开界面标签及图标误识别，没有账号名称、群名、消息、链接或号码。机身为示意合成，不是设备实物照片或华为官方素材；生成处理可能改变局部像素，不用于像素级 UI 验收。展开图仅证明采集时双栏显示，不代表折叠切换、旋转和多窗口完整验收。

形态比例参考[华为官方 Pura X Max 参数](https://consumer.huawei.com/cn/phones/pura-x-max/specs/)，外屏采集尺寸为 1264 × 1848，内屏为 2584 × 1828。机身合成图不用于设备尺寸测量。未复制华为产品宣传图片。

原始截图、布局树和诊断日志只保留在被 Git 忽略的本机目录，不能用于公开网站、Issue 或 PR 附件。公开目录不包含原图、缩略原图、定位、EXIF、文字注释或生成素材链容器。`strip-image-metadata.py` 逐块移除 PNG 非必要元数据，保留压缩像素数据和必要颜色信息，不做重新绘制或像素修改。

## 后续更换图片

1. 本机采集后先完成隐私遮挡，覆盖头像、用户名、手机号、验证码、群名、消息、引用、媒体、通知和键盘内容；检查边缘截断区域与半透明组件下方。
2. 逐张人工检查，OCR 仅为辅助，不能用「没有识别到文字」替代人工确认。
3. 执行 `python3 scripts/strip-image-metadata.py <成品.png>`，只将脱敏成品复制到公开路径。
4. 人工复核后更新 [config/public-assets.json](../config/public-assets.json) 中对应 SHA-256。清单只表示该特定文件经过审查，不能自动批准新的文件内容。
5. 暂存后运行 `python3 scripts/check-public-tree.py --staged`。检查器读取完整 Git index 与 index 内的清单，拒绝未审查的图片或含非必要元数据的 PNG。当前公开栅格图只接受 PNG，并严格核对魔数/扩展名、CRC、文件结构和像素压缩流；未知二进制与压缩归档拒绝进入公开树。

安全检查也覆盖私密路径、API 密钥、签名文件、常见访问令牌、个人主目录和大文件/二进制中的秘密。它不是所有隐私内容的自动识别器；公开前仍需检查文本语义与每个可视资产。授权公开的项目维护者身份为 GitHub 用户名和安全联系邮箱，不应扩展为其他个人资料。

## 使用的编辑提示词

以下保留本次内置工具的编辑要求；原提示中的采集区域坐标及实际未读数字已省略，不包含真实账号内容。

### 未展开画面脱敏

```text
Use case: precise-object-edit. Asset: privacy-redacted REAL HmChat screenshot for an open-source README, not a UI redesign. Preserve screenshot's aspect ratio, all app chrome, Chinese navigation labels, icons, spacing, white background, floating bottom glass tabs and bottom gesture bar exactly. Redact irreversibly with completely opaque pale blue-gray solid shapes, never blur or pixelate existing pixels. Clear the entire top status bar strip (top 0–100 pixels) to plain white. Cover the unread count next to 未读. Throughout the chat list, remove EVERY chat avatar including partial circles, every chat/group title, every message-preview text, timestamp, unread numerical badge contents. Replace each avatar with a flat uniform pale blue-gray circle; replace title and preview with flat opaque rounded bars of uniform deliberate lengths. Remove all tiny clipped remnants at top and bottom and any original text showing through the glass bottom tabs. Keep static group icon, separator lines, bell icons and bottom tabs readable. No real identity, group name, username, message text, avatar, membership clue, timestamp or count may remain. Do not invent readable fictional chat titles or new app features. Keep original static labels HmChat, 全部, 未读, 群组, 频道, 聊天, 联系人, 设置. This is privacy masking only. No extra labels, no device frame, no watermarks. Preserve all unaffected UI faithfully.
```

### 未展开机身合成

```text
Use case: compositing. Use the supplied already privacy-redacted HmChat screenshot as the exact screen content, do NOT redesign, crop or replace the UI. Add a realistic minimal front-facing Huawei Pura X Max FOLDED hardware frame around it, no perspective: unusually wide short phone, physical width85mm height120mm, external screen1264x1848. Slim dark titanium edge and black screen bezel with softly rounded outer corners, slight hinge edge on left, tiny side buttons right, centered tiny punch-hole camera in blank statusbar. Frame only, no text or Huawei logo. Retain the complete supplied white screen, every visible Chinese navigation label and floating bottom tabs and opaque redaction bars. The redaction bars must remain completely opaque, no personal content ever. Orthographic clean product render with delicate material highlight, no reflections covering UI. Make device large with narrow transparent margins on all four sides. Truly TRANSPARENT background outside device; no background plane, no baked checkerboard, no extra captions, no new features. This is an illustrative device frame to display a privacy-masked real app capture.
```

### 展开画面脱敏及机身合成

```text
Use case: precise-object-edit and compositing. This is a REAL HmChat split-view screenshot on unfolded Huawei Pura X Max, used for a privacy-safe open-source README. FIRST irreversibly redact all private content with completely opaque pale blue-gray solid shapes, never transparent blur. Preserve original static UI and geometry. Screenshot screen proportion2584x1828 landscape, chatlist left34%, chat area right66%. Remove entire statusbar strip (all time/icons) to white. In left list, replace EVERY avatar (including bottom partial) by flat uniform gray circle, EVERY group title and message snippet with opaque rounded bars; cover ALL timestamps and unread numbers, including count by 未读. At top of right chat, avatar and group title must be opaque neutral circle and bar. In right chat body, cover EVERY message text, sender name, quoted name/text and timestamps with opaque solid bars WITHIN original bubble rectangles; preserve positions/sizes of white and blue bubbles and blue reply accent, but NO original legible message characters or identity may remain. Redact original text showing through floating glass tabs. Preserve static HmChat, 全部, 未读, 群组, 频道, 群组 subtitle, 聊天, 联系人, 设置, 输入消息…, icons, separators, toolbar, composition and background colors. No fictional readable messages or features. THEN fit this complete privacy-masked screen into a very slim dark titanium Huawei Pura X Max UNFOLDED frame shown straight-on orthographic with softly rounded corners: body166.5mm wide120mm high, landscape wide-fold, subtle central hinge cues at top/bottom edge, slim black bezel, tiny unobtrusive punchhole camera in blank topbar, no logos or model text. Exact split-view geometry and original bubble arrangement unchanged. Frame only; true TRANSPARENT background outside device with narrow margins, no scene, no tabletop, no extra captions, no watermarks. Keep all unaffected UI faithful. No private original text, avatar or numbers may survive anywhere in output.
```
