import { PHONE_COUNTRIES, PHONE_MAIN_COUNTRY_ISOS, PhoneCountry } from '../data/PhoneCountries';

export { PHONE_COUNTRIES, PhoneCountry } from '../data/PhoneCountries';
export interface PhoneInputParts { dialCode: string; number: string; countryIso: string; }
export interface PhoneNormalization { value: string; error: string; }

function compact(value: string): string { return value.replace(/[\s().\-–—（）]/g, ''); }
function international(value: string): string {
  return value.startsWith('00') ? '+' + value.slice(2) : value;
}

export function findPhoneCountry(iso: string): PhoneCountry | undefined {
  const code = iso.trim().toUpperCase();
  return PHONE_COUNTRIES.find((country: PhoneCountry) => country.iso === code);
}

export function searchPhoneCountries(query: string): PhoneCountry[] {
  const text = query.trim().toLowerCase();
  if (!text) { return PHONE_COUNTRIES.slice(); }
  const digits = international(compact(text)).replace(/^\+/, '');
  return PHONE_COUNTRIES.filter((country: PhoneCountry) => country.name.toLowerCase().includes(text) ||
    country.englishName.toLowerCase().includes(text) || country.iso.toLowerCase().includes(text) ||
    (/^\d+$/.test(digits) && country.dialCode.slice(1).startsWith(digits)));
}

/** Normalize an editable calling code; anything but 1–3 non-zero leading digits is rejected. */
function normalizeDialCode(dialCode: string): string {
  const raw = dialCode.replace(/\s+/g, '');
  const code = raw.startsWith('00') ? '+' + raw.slice(2) : raw.startsWith('+') ? raw : '+' + raw;
  return /^\+[1-9]\d{0,2}$/.test(code) ? code : '';
}

/**
 * Resolve the country/region implied by an editable calling code.
 * Shared codes prefer the user's current region, then the upstream main region.
 */
export function matchPhoneCountryByDialCode(dialCode: string, preferredIso: string): PhoneCountry | undefined {
  const code = normalizeDialCode(dialCode);
  if (!code) { return undefined; }
  const candidates = PHONE_COUNTRIES.filter((country: PhoneCountry) => country.dialCode === code);
  if (candidates.length === 0) { return undefined; }
  const preferred = candidates.find((country: PhoneCountry) => country.iso === preferredIso.trim().toUpperCase());
  if (preferred) { return preferred; }
  if (candidates.length === 1) { return candidates[0]; }
  const main = candidates.find((country: PhoneCountry) => PHONE_MAIN_COUNTRY_ISOS.includes(country.iso));
  return main || candidates[0];
}

/** Split only an explicit international prefix; a national number never implies a country change. */
export function splitInternationalPhone(value: string, preferredIso: string): PhoneInputParts | undefined {
  const input = compact(value);
  if (!input.startsWith('+') && !input.startsWith('00')) { return undefined; }
  const phone = international(input);
  if (!/^\+[1-9]\d{1,14}$/.test(phone)) { return undefined; }
  const matches = PHONE_COUNTRIES.filter((country: PhoneCountry) => phone.startsWith(country.dialCode) && phone.length > country.dialCode.length);
  if (matches.length === 0) { return undefined; }
  const longest = Math.max(...matches.map((country: PhoneCountry) => country.dialCode.length));
  const candidates = matches.filter((country: PhoneCountry) => country.dialCode.length === longest);
  const preferred = candidates.find((country: PhoneCountry) => country.iso === preferredIso.trim().toUpperCase());
  const main = candidates.find((country: PhoneCountry) => PHONE_MAIN_COUNTRY_ISOS.includes(country.iso));
  const chosen = preferred || main || (candidates.length === 1 ? candidates[0] : undefined);
  const dialCode = candidates[0].dialCode;
  return { dialCode: dialCode, number: phone.slice(dialCode.length), countryIso: chosen?.iso || '' };
}

/** Formatting validation only; the server decides whether a complete number belongs to an account. */
export function normalizePhoneNumber(dialCode: string, number: string): PhoneNormalization {
  const national = compact(number);
  if (!national) { return { value: '', error: '请输入手机号。' }; }
  let value = '';
  if (national.startsWith('+') || national.startsWith('00')) {
    value = international(national);
  } else {
    if (!/^\d+$/.test(national)) { return { value: '', error: '手机号只能包含数字和常见分隔符。' }; }
    const selected = international(compact(dialCode));
    const code = selected.startsWith('+') ? selected : '+' + selected;
    if (!/^\+[1-9]\d{0,2}$/.test(code)) { return { value: '', error: '请输入有效的国家区号，例如 +86。' }; }
    value = code + national;
  }
  if (!/^\+[1-9]\d*$/.test(value)) { return { value: '', error: '国际号码应以 + 或 00 开头，后面只包含数字。' }; }
  if (value.length - 1 > 15) { return { value: '', error: '国家区号和手机号合计不能超过 15 位数字。' }; }
  if (value.length - 1 < 6) { return { value: '', error: '手机号过短，请检查国家区号和号码。' }; }
  return { value: value, error: '' };
}
