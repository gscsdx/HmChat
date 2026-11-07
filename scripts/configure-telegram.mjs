import fs from 'node:fs';
import path from 'node:path';

/**
 * Generates the git-ignored `entry/src/main/ets/config/TelegramBuildConfig.ets` from the
 * private `config/telegram.local.json` file.
 *
 * Input shape (see `config/telegram.example.json`, which only carries placeholder values):
 *   {
 *     "apiId": 0,
 *     "apiHash": "",
 *     "presets": [
 *       { "id": 123456, "hash": "<32 hex chars>", "label": "optional display name" }
 *     ]
 *   }
 *
 * - `presets` is optional and may hold up to {@link MAX_PRESETS} entries.
 * - Each entry needs `id` in 1..2147483647 and `hash` with exactly 32 hex characters.
 * - `label` is optional; it is rendered as a plain display name and never filled from the
 *   credentials, so labels cannot smuggle a full API identity into the UI.
 * - When `presets` is missing or empty, the legacy `apiId` / `apiHash` pair becomes the only
 *   preset, which keeps older local configuration files working.
 *
 * Diagnostics only report counts and configuration state: neither IDs nor hashes are printed.
 */
const root = process.env.HARLGRAM_ROOT || path.resolve(import.meta.dirname, '..');
const file = path.join(root, 'config/telegram.local.json');
const target = path.join(root, 'entry/src/main/ets/config/TelegramBuildConfig.ets');
const mode = process.argv[2] || 'debug';
const MAX_PRESETS = 20;
const MAX_PRESET_ID = 2147483647;
const MAX_LABEL_LENGTH = 40;

function isValidId(value) {
  return Number.isSafeInteger(value) && value > 0 && value <= MAX_PRESET_ID;
}

function isValidHash(value) {
  return typeof value === 'string' && /^[0-9a-f]{32}$/i.test(value);
}

/** Keeps a label human readable and free of control characters; never derives it from credentials. */
function sanitizeLabel(value, positionText) {
  if (value === undefined) { return ''; }
  if (typeof value !== 'string') { throw new Error(`${positionText}预设的 label 类型不正确`); }
  const cleaned = value.replace(/[\u0000-\u001f\u007f]/g, '').trim();
  return cleaned.length > MAX_LABEL_LENGTH ? cleaned.slice(0, MAX_LABEL_LENGTH) : cleaned;
}

/** Validates the `presets` array. Errors mention positions only, never the offending values. */
function parsePresets(config) {
  const raw = config.presets;
  if (raw === undefined || raw === null) { return []; }
  if (!Array.isArray(raw)) { throw new Error('presets 字段应为数组'); }
  if (raw.length > MAX_PRESETS) { throw new Error(`presets 最多支持 ${MAX_PRESETS} 组`); }
  return raw.map((item, position) => {
    const positionText = `第 ${position + 1} 组`;
    if (!item || typeof item !== 'object' || Array.isArray(item)) { throw new Error(`${positionText}预设应为对象`); }
    if (!isValidId(item.id)) { throw new Error(`${positionText}预设的 id 应为 1..${MAX_PRESET_ID} 的整数`); }
    if (!isValidHash(item.hash)) { throw new Error(`${positionText}预设的 hash 应为 32 位十六进制字符串`); }
    return { id: item.id, hash: item.hash, label: sanitizeLabel(item.label, positionText) };
  });
}

/** Legacy single-identity configuration, used only when `presets` is absent or empty. */
function legacyPreset(config) {
  const empty = config.apiId === 0 && config.apiHash === '';
  if (!empty && (!isValidId(config.apiId) || !isValidHash(config.apiHash))) { throw new Error('格式不正确'); }
  return empty ? [] : [{ id: config.apiId, hash: config.apiHash, label: '' }];
}

function renderPresets(presets) {
  if (presets.length === 0) { return '[]'; }
  const entries = presets.map((preset) =>
    `  { id: ${preset.id}, hash: ${JSON.stringify(preset.hash)}, label: ${JSON.stringify(preset.label)} }`);
  return `[\n${entries.join(',\n')}\n]`;
}

let config = { apiId: 0, apiHash: '', presets: [] };
try {
  if (fs.existsSync(file)) {
    try { config = JSON.parse(fs.readFileSync(file, 'utf8')); }
    catch { throw new Error('配置 JSON 无法解析'); }
  }
  if (!config || typeof config !== 'object' || Array.isArray(config)) throw new Error('配置字段类型不正确');
  const parsed = parsePresets(config);
  const presets = parsed.length > 0 ? parsed : legacyPreset(config);
  const empty = presets.length === 0;
  if (mode === 'release' && (empty || presets.some((preset) => preset.id === 4))) throw new Error('release 构建必须配置自己的 Telegram API 身份');
  fs.mkdirSync(path.dirname(target), { recursive: true });
  const source = '// Generated locally. Never commit this file.\n' +
    'export interface TelegramApiPreset {\n' +
    '  readonly id: number;\n' +
    '  readonly hash: string;\n' +
    '  readonly label: string;\n' +
    '}\n' +
    `export const TELEGRAM_API_PRESETS: TelegramApiPreset[] = ${renderPresets(presets)};\n` +
    'export const TELEGRAM_API_ID: number = TELEGRAM_API_PRESETS.length > 0 ? TELEGRAM_API_PRESETS[0].id : 0;\n' +
    "export const TELEGRAM_API_HASH: string = TELEGRAM_API_PRESETS.length > 0 ? TELEGRAM_API_PRESETS[0].hash : '';\n";
  if (!fs.existsSync(target) || fs.readFileSync(target, 'utf8') !== source) fs.writeFileSync(target, source, { mode: 0o600 });
  fs.chmodSync(target, 0o600);
  console.log(empty
    ? 'Telegram API 身份未配置；本次构建可用于界面和原生库验证。'
    : `Telegram 本地构建配置已生成，共 ${presets.length} 组 API 预设（不输出凭据）。`);
} catch (error) {
  console.error(`Telegram 配置检查失败：${error.message}。请检查 config/telegram.local.json。`);
  process.exit(1);
}