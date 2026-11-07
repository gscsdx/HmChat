import { ChatMessage, MessageEntity, RichContentBlock } from '../model/ChatModels';
import { TdPageBlock, TdRichText, TdFile, TdPhotoSize } from './TdTypes';

export interface RichTextResult { text: string; entities: MessageEntity[]; }
export interface DecodedRichBlock { block: RichContentBlock; file?: TdFile; thumbnail?: TdFile; }

/** Decode the fixed TDLib RichText tree, bounded for malformed or deeply nested data. */
export function decodeRichText(node: TdRichText | undefined, depth: number = 0): RichTextResult {
  if (!node || depth > 24) { return { text: '', entities: [] }; }
  const type = node['@type'];
  if (type === 'richTextPlain') { return { text: typeof node.text === 'string' ? node.text : '', entities: [] }; }
  if (type === 'richTextCustomEmoji') { return { text: node.alternative_text || '◈', entities: [] }; }
  if (type === 'richTextMathematicalExpression') { return { text: node.expression || '', entities: [] }; }
  if (type === 'richTexts') {
    let text = ''; const entities: MessageEntity[] = [];
    (node.texts || []).slice(0, 1000).forEach((child: TdRichText) => {
      const value = decodeRichText(child, depth + 1), offset = text.length;
      value.entities.forEach((entity: MessageEntity) => entities.push({ ...entity, offset: entity.offset + offset }));
      text += value.text;
    });
    return { text: text, entities: entities };
  }
  const child = decodeRichText(typeof node.text === 'object' ? node.text : undefined, depth + 1);
  let entityType = '', url = '';
  if (type === 'richTextBold') { entityType = 'Bold'; }
  if (type === 'richTextItalic') { entityType = 'Italic'; }
  if (type === 'richTextUnderline') { entityType = 'Underline'; }
  if (type === 'richTextStrikethrough') { entityType = 'Strikethrough'; }
  if (type === 'richTextSpoiler') { entityType = 'Spoiler'; }
  if (type === 'richTextFixed') { entityType = 'Code'; }
  if (type === 'richTextUrl' || type === 'richTextReferenceLink' || type === 'richTextAnchorLink') { entityType = 'TextUrl'; url = node.url || ''; }
  if (type === 'richTextMention') { entityType = 'TextUrl'; url = 'https://t.me/' + (node.username || ''); }
  if (type === 'richTextEmailAddress') { entityType = 'TextUrl'; url = 'mailto:' + (node.email_address || ''); }
  if (type === 'richTextPhoneNumber') { entityType = 'TextUrl'; url = 'tel:' + (node.phone_number || ''); }
  if (entityType && child.text.length) { child.entities.push({ offset: 0, length: child.text.length, type: 'textEntityType' + entityType, url: url || undefined }); }
  return child;
}

export function decodeRichBlocks(blocks: TdPageBlock[], parent: ChatMessage): DecodedRichBlock[] {
  const output: DecodedRichBlock[] = [];
  const appendText = (node: TdRichText | undefined, kind: string = 'text', level: number = 0, prefix: string = ''): void => {
    const value = decodeRichText(node);
    if (!value.text && !prefix) { return; }
    const entities = value.entities.map((entity: MessageEntity): MessageEntity => ({ ...entity, offset: entity.offset + prefix.length }));
    if (kind === 'quote' || kind === 'code') { entities.push({ offset: 0, length: prefix.length + value.text.length,
      type: kind === 'quote' ? 'textEntityTypeBlockQuote' : 'textEntityTypePre' }); }
    if (kind === 'heading') { entities.push({ offset: 0, length: prefix.length + value.text.length, type: 'textEntityTypeBold' }); }
    output.push({ block: { kind: kind, text: prefix + value.text, entities: entities, level: level } });
  };
  const visit = (block: TdPageBlock, depth: number = 0): void => {
    if (depth > 16 || output.length >= 200) { return; }
    const type = block['@type'];
    if (['pageBlockTitle', 'pageBlockHeader', 'pageBlockSectionHeading', 'pageBlockSubtitle', 'pageBlockSubheader'].includes(type)) {
      appendText(block.title || block.header || block.text || block.subtitle || block.subheader, 'heading', type === 'pageBlockSectionHeading' ? Math.max(1, Math.min(6, block.size || 1)) : type === 'pageBlockTitle' ? 1 : 2); return;
    }
    if (type === 'pageBlockDivider') { output.push({ block: { kind: 'divider', text: '', entities: [], level: 0 } }); return; }
    if (type === 'pageBlockAnchor') { return; }
    if (type === 'pageBlockList') {
      (block.items || []).slice(0, 100).forEach((item) => {
        const start = output.length; (item.blocks || []).forEach((child: TdPageBlock) => visit(child, depth + 1));
        const first = output[start]?.block;
        if (first) { const label = item.has_checkbox ? item.is_checked ? '☑ ' : '☐ ' : (item.label || '•') + ' ';
          first.text = label + first.text; first.entities = first.entities.map((e: MessageEntity) => ({ ...e, offset: e.offset + label.length })); }
      }); return;
    }
    if (type === 'pageBlockBlockQuote') {
      (block.blocks || []).forEach((child: TdPageBlock) => {
        const start = output.length; visit(child, depth + 1);
        for (let i = start; i < output.length; i++) { const value = output[i].block;
          value.kind = 'quote'; if (value.text) { value.entities.push({ offset: 0, length: value.text.length, type: 'textEntityTypeBlockQuote' }); } }
      }); return;
    }
    if (block.cover) { visit(block.cover, depth + 1); return; }
    if (block.blocks) {
      appendText(block.header); block.blocks.forEach((child: TdPageBlock) => visit(child, depth + 1)); return;
    }
    if (type === 'pageBlockPhoto' || type === 'pageBlockVideo' || type === 'pageBlockAnimation') {
      const photo = block.photo?.sizes.filter((size: TdPhotoSize) => size.photo.size <= 20 * 1024 * 1024 && size.photo.expected_size <= 20 * 1024 * 1024)
        .slice().sort((a: TdPhotoSize, b: TdPhotoSize) => b.width * b.height - a.width * a.height)[0];
      const video = block.video, animation = block.animation;
      const file = photo?.photo || video?.video || animation?.animation;
      const caption = decodeRichText(block.caption?.text);
      if (file && !block.has_spoiler) {
        const media: ChatMessage = { id: `${parent.id}:rich:${output.length}`, chatId: parent.chatId, sourceMessageId: parent.id,
          text: caption.text, caption: caption.text, entities: caption.entities, time: parent.time, status: parent.status, outgoing: parent.outgoing,
          canSave: parent.canSave, mediaKind: photo ? 'photo' : 'video', mediaFileId: file.id, mediaSize: file.size || file.expected_size,
          mediaWidth: photo?.width || video?.width || animation?.width, mediaHeight: photo?.height || video?.height || animation?.height,
          mediaDuration: video?.duration || animation?.duration,
          mediaPath: file.local.is_downloading_completed ? file.local.path : undefined };
        output.push({ block: { kind: 'media', text: caption.text, entities: caption.entities, level: 0, media: media },
          file: file, thumbnail: video?.thumbnail?.file || animation?.thumbnail?.file });
      } else { appendText({ '@type': 'richTextPlain', text: block.has_spoiler ? '[剧透媒体]' : '[媒体暂不可用]' }); }
      return;
    }
    if (type === 'pageBlockTable') {
      (block.cells || []).slice(0, 50).forEach((row) => appendText({ '@type': 'richTextPlain', text: row.map((cell) => decodeRichText(cell.text).text).join(' │ ') })); return;
    }
    if (block.document) { appendText({ '@type': 'richTextPlain', text: '📄 ' + block.document.file_name }); }
    const rich = block.text || block.footer || block.kicker || block.author;
    if (rich) { appendText(rich, type === 'pageBlockPreformatted' ? 'code' : type.includes('Quote') ? 'quote' : 'text'); }
    else if (block.expression) { appendText({ '@type': 'richTextPlain', text: block.expression }, 'code'); }
    else if (block.url) { appendText({ '@type': 'richTextUrl', text: { '@type': 'richTextPlain', text: block.url }, url: block.url }); }
    else if (!block.document) { appendText({ '@type': 'richTextPlain', text: '[暂不支持的内容区块]' }); }
    if (block.caption) { appendText(block.caption.text); }
  };
  blocks.slice(0, 200).forEach((block: TdPageBlock) => visit(block));
  return output;
}
