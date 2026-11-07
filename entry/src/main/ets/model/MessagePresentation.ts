import { ChatMessage, MessageEntity } from './ChatModels';

export interface MessageRun {
  text: string; bold: boolean; italic: boolean; underline: boolean; strike: boolean;
  mono: boolean; spoiler: boolean; link: string;
}
export interface MessageBlock { kind: string; runs: MessageRun[]; }
export interface MediaFrame { index: number; x: number; y: number; width: number; height: number; }
export interface MediaLayout { width: number; height: number; frames: MediaFrame[]; }

export function safeMessageLink(value: string): string {
  const url = value.trim();
  return /^(https?:\/\/|mailto:|tel:)/i.test(url) && !/[\u0000-\u0020\u007f]/.test(url) ? url : '';
}
function entityLink(text: string, entity: MessageEntity): string {
  const label = text.slice(entity.offset, entity.offset + entity.length);
  if (entity.type === 'textEntityTypeTextUrl') { return safeMessageLink(entity.url || ''); }
  if (entity.type === 'textEntityTypeUrl') { return safeMessageLink(/^https?:\/\//i.test(label) ? label : 'https://' + label); }
  if (entity.type === 'textEntityTypeMention') { return /^@[a-zA-Z0-9_]+$/.test(label) ? 'https://t.me/' + label.slice(1) : ''; }
  if (entity.type === 'textEntityTypeEmailAddress') { return safeMessageLink('mailto:' + label); }
  if (entity.type === 'textEntityTypePhoneNumber') { return safeMessageLink('tel:' + label.replace(/[^+\d]/g, '')); }
  return '';
}
function splitsSurrogate(text: string, offset: number): boolean {
  return offset > 0 && offset < text.length && /[\uD800-\uDBFF]/.test(text[offset - 1]) && /[\uDC00-\uDFFF]/.test(text[offset]);
}
export function messageRuns(text: string, entities: MessageEntity[] = []): MessageRun[] {
  const valid = entities.filter((e: MessageEntity) => Number.isSafeInteger(e.offset) && Number.isSafeInteger(e.length) &&
    e.offset >= 0 && e.length > 0 && e.offset + e.length <= text.length && !splitsSurrogate(text, e.offset) && !splitsSurrogate(text, e.offset + e.length));
  const points: number[] = [0, text.length];
  valid.forEach((e: MessageEntity) => { points.push(e.offset, e.offset + e.length); });
  const sorted = points.filter((p: number, i: number) => points.indexOf(p) === i).sort((a: number, b: number) => a - b);
  const runs: MessageRun[] = [];
  for (let i = 0; i < sorted.length - 1; i++) {
    const start = sorted[i], end = sorted[i + 1];
    if (end <= start) { continue; }
    const active = valid.filter((e: MessageEntity) => e.offset <= start && e.offset + e.length >= end);
    const has = (kind: string): boolean => active.some((e: MessageEntity) => e.type === 'textEntityType' + kind);
    const linked = active.find((e: MessageEntity) => entityLink(text, e).length > 0);
    runs.push({ text: text.slice(start, end), bold: has('Bold'), italic: has('Italic'), underline: has('Underline'),
      strike: has('Strikethrough'), mono: has('Code') || has('Pre') || has('PreCode'), spoiler: has('Spoiler'),
      link: linked ? entityLink(text, linked) : '' });
  }
  return runs;
}
export function messageBlocks(text: string, entities: MessageEntity[] = []): MessageBlock[] {
  const blockEntities = entities.filter((e: MessageEntity) => ['textEntityTypeBlockQuote', 'textEntityTypeExpandableBlockQuote', 'textEntityTypePre', 'textEntityTypePreCode'].includes(e.type) &&
    Number.isSafeInteger(e.offset) && Number.isSafeInteger(e.length) && e.offset >= 0 && e.length > 0 && e.offset + e.length <= text.length)
    .slice().sort((a: MessageEntity, b: MessageEntity) => a.offset - b.offset);
  const blocks: MessageBlock[] = [];
  let cursor = 0;
  const append = (start: number, end: number, kind: string): void => {
    if (end <= start) { return; }
    const local = entities.filter((e: MessageEntity) => e.offset >= start && e.offset + e.length <= end)
      .map((e: MessageEntity): MessageEntity => ({ offset: e.offset - start, length: e.length, type: e.type, url: e.url }));
    blocks.push({ kind: kind, runs: messageRuns(text.slice(start, end), local) });
  };
  blockEntities.forEach((e: MessageEntity) => {
    if (e.offset < cursor) { return; }
    append(cursor, e.offset, 'text'); append(e.offset, e.offset + e.length, e.type.includes('Quote') ? 'quote' : 'code');
    cursor = e.offset + e.length;
  });
  append(cursor, text.length, 'text');
  return blocks;
}
export function messagesGrouped(a: ChatMessage | undefined, b: ChatMessage | undefined): boolean {
  return !!a && !!b && !a.service && !b.service && a.chatId === b.chatId && a.outgoing === b.outgoing &&
    a.senderId === b.senderId && a.forwardName === b.forwardName && !!a.date && !!b.date &&
    b.date >= a.date && b.date - a.date <= 300 && new Date(a.date * 1000).toDateString() === new Date(b.date * 1000).toDateString();
}
export function mediaAspect(message: ChatMessage): number {
  const ratio = (message.mediaWidth || 0) / (message.mediaHeight || 0);
  return Number.isFinite(ratio) && ratio > 0 ? Math.min(2.4, Math.max(0.5, ratio)) : 1;
}
export function singleMediaSize(message: ChatMessage, maxWidth: number): MediaLayout {
  const aspect = mediaAspect(message);
  const height = Math.min(420, maxWidth / aspect);
  return { width: Math.min(maxWidth, height * aspect), height: height, frames: [] };
}
/** Aspect-aware rows, preserving order and filling every row, including odd counts. */
export function albumLayout(items: ChatMessage[], width: number): MediaLayout {
  const count = items.length, gap = 2;
  if (!count) { return { width: width, height: 0, frames: [] }; }
  const ratios = items.map((item: ChatMessage) => mediaAspect(item));
  if (count === 3) {
    if (ratios[0] < 0.8) {
      const left = (width - gap) * 0.55, right = width - left - gap;
      const height = Math.min(width * 1.15, left / ratios[0]);
      const upper = (height - gap) / 2;
      return { width: width, height: height, frames: [
        { index: 0, x: 0, y: 0, width: left, height: height },
        { index: 1, x: left + gap, y: 0, width: right, height: upper },
        { index: 2, x: left + gap, y: upper + gap, width: right, height: height - upper - gap }
      ] };
    }
    const top = Math.min(width / ratios[0], width * 0.66);
    const half = (width - gap) / 2;
    const bottom = Math.min(half / ratios[1], half / ratios[2], width - top - gap);
    return { width: width, height: top + gap + bottom, frames: [
      { index: 0, x: 0, y: 0, width: width, height: top },
      { index: 1, x: 0, y: top + gap, width: half, height: bottom },
      { index: 2, x: half + gap, y: top + gap, width: width - half - gap, height: bottom }
    ] };
  }
  let rows: number[][] = [];
  if (count === 2) { rows = ratios.every((r: number) => r > 1.4) && Math.abs(ratios[0] - ratios[1]) < 0.2 ? [[0], [1]] : [[0, 1]]; }
  else if (count === 3) { rows = [[0], [1, 2]]; }
  else if (count === 4) { rows = [[0, 1], [2, 3]]; }
  else {
    for (let i = 0; i < count;) {
      const remaining = count - i;
      const take = remaining === 4 ? 2 : Math.min(3, remaining);
      const row: number[] = [];
      for (let j = 0; j < take; j++) { row.push(i++); }
      rows.push(row);
    }
  }
  const frames: MediaFrame[] = [];
  let y = 0;
  rows.forEach((row: number[]) => {
    const sum = row.reduce((total: number, index: number) => total + ratios[index], 0);
    const height = Math.min(width * 0.66, (width - gap * (row.length - 1)) / sum);
    let x = 0;
    row.forEach((index: number, column: number) => {
      const cellWidth = column === row.length - 1 ? width - x : (width - gap * (row.length - 1)) * ratios[index] / sum;
      frames.push({ index: index, x: x, y: y, width: cellWidth, height: height }); x += cellWidth + gap;
    });
    y += height + gap;
  });
  return { width: width, height: Math.max(0, y - gap), frames: frames };
}

export function concealedMessageText(text: string, entities: MessageEntity[] = []): string {
  let result = text;
  entities.filter((e: MessageEntity) => e.type === 'textEntityTypeSpoiler' && Number.isSafeInteger(e.offset) && Number.isSafeInteger(e.length) &&
    e.offset >= 0 && e.length > 0 && e.offset + e.length <= text.length).forEach((e: MessageEntity) => {
    result = result.slice(0, e.offset) + '•'.repeat(e.length) + result.slice(e.offset + e.length);
  });
  return result;
}
