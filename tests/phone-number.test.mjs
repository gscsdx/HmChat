import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { PHONE_COUNTRIES, findPhoneCountry, searchPhoneCountries, matchPhoneCountryByDialCode,
  splitInternationalPhone, normalizePhoneNumber } = require('../artifacts/tests/js/model/PhoneNumber.js');
const { PHONE_MAIN_COUNTRY_ISOS } = require('../artifacts/tests/js/data/PhoneCountries.js');

test('generated country data covers every geographical metadata territory with unique ISO identifiers', () => {
  assert.equal(PHONE_COUNTRIES.length, 245);
  assert.equal(new Set(PHONE_COUNTRIES.map(country => country.iso)).size, 245);
  for (const country of PHONE_COUNTRIES) {
    assert.match(country.iso, /^[A-Z]{2}$/);
    assert.match(country.dialCode, /^\+[1-9]\d{0,2}$/);
    assert.ok(country.name); assert.ok(country.englishName);
  }
  assert.equal(findPhoneCountry(' cn ').dialCode, '+86');
  assert.equal(findPhoneCountry('CN').name, '中国');
  assert.equal(findPhoneCountry('GB').dialCode, '+44');
  assert.equal(findPhoneCountry('XK').dialCode, '+383');
  assert.equal(findPhoneCountry('001'), undefined);
});

test('national input combines with an editable calling code and changes only when the chosen code changes', () => {
  assert.deepEqual(normalizePhoneNumber('+86', '138 0013-8000'), { value: '+8613800138000', error: '' });
  assert.equal(normalizePhoneNumber('86', '13800138000').value, '+8613800138000');
  assert.equal(normalizePhoneNumber('0086', '13800138000').value, '+8613800138000');
  assert.equal(normalizePhoneNumber('+44', '7700 900123').value, '+447700900123');
  assert.equal(normalizePhoneNumber('+1', '7700 900123').value, '+17700900123');
  assert.equal(normalizePhoneNumber('+999', '123456').value, '+999123456', 'manual calling codes are not restricted to the offline list');
});

test('complete + and 00 international numbers override the selected country without repeating its code', () => {
  assert.equal(normalizePhoneNumber('+86', '+44 (7700) 900-123').value, '+447700900123');
  assert.equal(normalizePhoneNumber('+86', '00 44 7700 900123').value, '+447700900123');
  assert.equal(normalizePhoneNumber('', '+1 202.555.0123').value, '+12025550123');
  assert.equal(normalizePhoneNumber('invalid', '+39 02 1234 5678').value, '+390212345678');
});

test('Italy and all national input keep significant leading zeroes', () => {
  assert.equal(normalizePhoneNumber('+39', '02 1234 5678').value, '+390212345678');
  assert.equal(normalizePhoneNumber('+44', '07700 900123').value, '+4407700900123', 'no heuristic trunk-prefix removal');
  assert.deepEqual(splitInternationalPhone('+39 02 1234 5678', 'CN'), { dialCode: '+39', number: '0212345678', countryIso: 'IT' });
});

test('split accepts only an explicit international prefix and preserves national digits', () => {
  assert.equal(splitInternationalPhone('8613800138000', 'CN'), undefined);
  assert.equal(splitInternationalPhone('13800138000', 'CN'), undefined);
  assert.deepEqual(splitInternationalPhone('+86 138 0013 8000', 'US'), { dialCode: '+86', number: '13800138000', countryIso: 'CN' });
  assert.deepEqual(splitInternationalPhone('00 44 (7700) 900123', 'CN'), { dialCode: '+44', number: '7700900123', countryIso: 'GB' });
  assert.equal(splitInternationalPhone('+999123456', 'CN'), undefined, 'unknown code stays editable as a complete number');
  assert.equal(splitInternationalPhone('+86+13800138000', 'CN'), undefined);
  assert.equal(splitInternationalPhone('+861380013800012345', 'CN'), undefined);
});

test('shared calling codes retain the preferred matching region or the upstream designated main region', () => {
  assert.equal(splitInternationalPhone('+1 202 555 0123', 'CA').countryIso, 'CA');
  assert.equal(splitInternationalPhone('+1 202 555 0123', 'US').countryIso, 'US');
  assert.equal(splitInternationalPhone('+1 202 555 0123', 'CN').countryIso, 'US');
  assert.equal(splitInternationalPhone('+44 7700 900123', 'JE').countryIso, 'JE');
  assert.equal(splitInternationalPhone('+7 700 1234567', 'KZ').countryIso, 'KZ');
  assert.equal(splitInternationalPhone('+7 700 1234567', '').countryIso, 'RU');
});

test('dial code matching resolves a region, keeping the current one for shared codes', () => {
  assert.equal(matchPhoneCountryByDialCode('+86', '').iso, 'CN');
  assert.equal(matchPhoneCountryByDialCode('+1', '').iso, 'US');
  assert.equal(matchPhoneCountryByDialCode('+7', '').iso, 'RU');
  assert.equal(matchPhoneCountryByDialCode('+44', '').iso, 'GB');
  assert.equal(matchPhoneCountryByDialCode('+358', '').iso, 'FI');
  assert.equal(matchPhoneCountryByDialCode('+61', '').iso, 'AU');
  assert.equal(matchPhoneCountryByDialCode('00 1', '').iso, 'US', '00 prefix is international');
  assert.equal(matchPhoneCountryByDialCode('1', '').iso, 'US', 'a bare code gains the plus prefix');
  assert.equal(matchPhoneCountryByDialCode(' + 86 ', '').iso, 'CN', 'surrounding whitespace is ignored');
  assert.equal(matchPhoneCountryByDialCode('+1', 'CA').iso, 'CA', 'the current region wins for shared codes');
  assert.equal(matchPhoneCountryByDialCode('+1', ' ca ').iso, 'CA', 'preferred ISO is normalized');
  assert.equal(matchPhoneCountryByDialCode('+7', 'KZ').iso, 'KZ');
  assert.equal(matchPhoneCountryByDialCode('+44', 'JE').iso, 'JE');
  assert.equal(matchPhoneCountryByDialCode('+1', 'CN').iso, 'US', 'a non-matching preference falls back to the main region');
  assert.equal(matchPhoneCountryByDialCode('+999', ''), undefined, 'unknown codes have no region');
  assert.equal(matchPhoneCountryByDialCode('', ''), undefined);
  assert.equal(matchPhoneCountryByDialCode('   ', ''), undefined);
  assert.equal(matchPhoneCountryByDialCode('+86', '').name, '中国');
});

test('every shared calling code has a designated main region for fallback resolution', () => {
  const grouped = new Map();
  for (const country of PHONE_COUNTRIES) {
    const list = grouped.get(country.dialCode) || [];
    list.push(country);
    grouped.set(country.dialCode, list);
  }
  for (const [dialCode, countries] of grouped) {
    const matched = matchPhoneCountryByDialCode(dialCode, '');
    assert.ok(matched, dialCode + ' should resolve without a preference');
    assert.equal(matched.dialCode, dialCode);
    if (countries.length === 1) {
      assert.equal(matched.iso, countries[0].iso);
    } else {
      assert.ok(countries.some(country => country.iso === matched.iso), dialCode + ' must pick a candidate');
      assert.ok(PHONE_MAIN_COUNTRY_ISOS.includes(matched.iso), dialCode + ' should pick the main region');
    }
    for (const country of countries) {
      assert.equal(matchPhoneCountryByDialCode(dialCode, country.iso).iso, country.iso, 'preference always wins');
    }
  }
});

test('empty input, letters, embedded plus signs, invalid codes and excessive length give non-leaking errors', () => {
  for (const [code, number] of [['+86', ''], ['+86', '() -'], ['', '13800138000'], ['+0', '1234567'],
    ['+1234', '1234567'], ['+86', '138abc00138000'], ['+86', '138+00138000'], ['+86', '++8613800138000'],
    ['+86', '+00123456'], ['+86', '12345678901234'], ['+1', '123'], ['+1', '+1234567890123456']]) {
    const normalized = normalizePhoneNumber(code, number);
    assert.equal(normalized.value, ''); assert.ok(normalized.error);
    assert.equal(normalized.error.includes('138abc'), false);
  }
  assert.equal(normalizePhoneNumber('+1', '12345678901234').value, '+112345678901234', '15 total digits remain accepted');
});

test('country search matches Chinese, English, ISO and shared calling codes offline', () => {
  assert.ok(searchPhoneCountries('中国').some(country => country.iso === 'CN'));
  assert.ok(searchPhoneCountries('united kingdom').some(country => country.iso === 'GB'));
  assert.ok(searchPhoneCountries('cn').some(country => country.iso === 'CN'));
  assert.ok(searchPhoneCountries('0086').some(country => country.iso === 'CN'));
  const shared = searchPhoneCountries('+1');
  assert.ok(shared.some(country => country.iso === 'CA'));
  assert.ok(shared.some(country => country.iso === 'US'));
  assert.deepEqual(searchPhoneCountries('no-such-country'), []);
  const all = searchPhoneCountries(''); all.pop();
  assert.equal(PHONE_COUNTRIES.length, 245, 'empty search returns a separate array');
});
