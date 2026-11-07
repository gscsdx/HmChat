#!/usr/bin/env python3
"""S4-08: static import gate for the Clash VPN extension process.

The VPN extension runs in its own process and must not reach UI, Telegram or
device-permission surfaces (design section 7.2, REQ-100/101):

* ``entry/src/main/ets/vpn/`` and ``entry/src/main/ets/services/clash/`` may not
  import contacts, geolocation, audio, camera, telephony, Telegram services or
  the app's ``telegram/``, ``data/``, ``components/`` and ``pages/`` trees.
* ``entry/src/main/ets/components/`` and ``entry/src/main/ets/pages/`` must not
  import the native extension bridge ``libclash_bridge.so``.

Comments and string literals are blanked before matching, so documentation and
ordinary strings cannot trigger the gate. Only ``<relative path>:<line>:
<rule>`` is printed; file contents never leave the process.

Exit status: 0 when clean, 1 on any violation or when the gate cannot run.
Python 3.8+ is required; no third-party dependencies.
"""

import argparse
import bisect
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

EXTENSION_DIRS = (
    'entry/src/main/ets/vpn',
    'entry/src/main/ets/services/clash',
)
UI_DIRS = (
    'entry/src/main/ets/components',
    'entry/src/main/ets/pages',
)
SOURCE_SUFFIXES = ('.ets', '.ts')

# A statement can be long (multi-line imports); bound the backward search so a
# malformed file cannot make the scan quadratic.
MAX_STATEMENT_CHARS = 8192


class GateError(Exception):
    """Gate failure whose message is safe to print (paths only, never content)."""


class Rule:
    """One forbidden import pattern.

    The same pattern is matched against the import statement's code (identifiers
    such as ``TelegramService``) and against the module specifier (``'@kit...'``).
    """

    __slots__ = ('name', 'regex')

    def __init__(self, name, pattern):
        self.name = name
        self.regex = re.compile(pattern)


FORBIDDEN_EXTENSION_RULES = (
    Rule('@ohos.contact', r'@ohos\.contact'),
    Rule('@ohos.geolocation', r'@ohos\.geolocation'),
    Rule('geoLocationManager', r'\bgeoLocationManager\b'),
    Rule('@ohos.multimedia.audio', r'@ohos\.multimedia\.audio'),
    Rule('@ohos.multimedia.camera', r'@ohos\.multimedia\.camera'),
    Rule('@ohos.telephony.*', r'@ohos\.telephony(?:\.|$)'),
    Rule('@kit.TelephonyKit', r'@kit\.TelephonyKit'),
    Rule('TelegramService', r'\bTelegramService\b'),
    Rule('MediaNetworkMonitor', r'\bMediaNetworkMonitor\b'),
    # Path patterns require a real segment boundary so e.g. ``Metadata/`` does
    # not look like the forbidden ``data/`` tree.
    Rule('telegram/', r'(?:^|/)telegram/'),
    Rule('data/', r'(?:^|/)data/'),
    Rule('components/', r'(?:^|/)components/'),
    Rule('pages/', r'(?:^|/)pages/'),
)

# UI code must go through the service layer, never load the extension bridge.
FORBIDDEN_UI_RULES = (
    Rule('libclash_bridge.so', r'libclash_bridge\.so'),
)

# --- Lexing: blank comments, strings and regex literals ---------------------
# Matching runs on the blanked text, so the patterns can only see executable
# code and real module specifiers. Blanking keeps newlines, which preserves
# line numbers for diagnostics.

REGEX_PRECEDING_CHARS = frozenset('=([{,:;!&|?+-*%<>~^')
REGEX_PRECEDING_WORDS = frozenset((
    'return', 'typeof', 'case', 'in', 'of', 'delete', 'void', 'instanceof',
    'new', 'do', 'else',
))


class StringSpan:
    """A single/double quoted string literal found in the source."""

    __slots__ = ('start', 'end', 'value')

    def __init__(self, start, end, value):
        self.start = start
        self.end = end
        self.value = value


def _blank(chars, start, end):
    """Replace a range with spaces, keeping newlines for line numbering."""
    for index in range(start, end):
        if chars[index] not in ('\n', '\r'):
            chars[index] = ' '


def _scan_quoted(source, start):
    """Return the index just past the closing quote, or -1 if unterminated."""
    quote = source[start]
    index = start + 1
    length = len(source)
    while index < length:
        char = source[index]
        if char == '\\':
            index += 2
            continue
        if char == quote:
            return index + 1
        # JavaScript/ArkTS string literals cannot span a raw newline. Treating
        # the quote as plain code keeps a stray quote from eating the file.
        if char in ('\n', '\r'):
            return -1
        index += 1
    return -1


def _scan_template(source, start):
    """Return the index just past the closing backtick, or -1 if unterminated."""
    index = start + 1
    length = len(source)
    while index < length:
        char = source[index]
        if char == '\\':
            index += 2
            continue
        if char == '`':
            return index + 1
        index += 1
    return -1


def _scan_regex(source, start):
    """Return the index just past the closing slash, or -1 if not a literal."""
    index = start + 1
    length = len(source)
    in_class = False
    while index < length:
        char = source[index]
        if char == '\\':
            index += 2
            continue
        if char in ('\n', '\r'):
            return -1
        if char == '[':
            in_class = True
        elif char == ']':
            in_class = False
        elif char == '/' and not in_class:
            return index + 1
        index += 1
    return -1


def _regex_allowed(chars, slash_index):
    """Heuristically decide whether ``/`` opens a regex literal, not division."""
    index = slash_index - 1
    while index >= 0 and chars[index] in ' \t':
        index -= 1
    if index < 0:
        return True
    char = chars[index]
    if char in ('\n', '\r'):
        return True
    if char in REGEX_PRECEDING_CHARS:
        return True
    if char.isalnum() or char in '_$':
        word_start = index
        while word_start >= 0 and (chars[word_start].isalnum() or chars[word_start] in '_$'):
            word_start -= 1
        return ''.join(chars[word_start + 1:index + 1]) in REGEX_PRECEDING_WORDS
    return False


def mask_comments_and_strings(source):
    """Blank comments, string literals and regex literals; collect strings.

    Returns ``(masked, spans)`` where ``masked`` has the same length as
    ``source`` and ``spans`` describes the quoted strings (used to read module
    specifiers). Template literals are blanked but not collected; they cannot
    form a static import specifier.
    """
    chars = list(source)
    spans = []
    length = len(source)
    index = 0
    while index < length:
        char = source[index]
        following = source[index + 1] if index + 1 < length else ''
        if char == '/' and following == '/':
            end = source.find('\n', index + 2)
            if end < 0:
                end = length
            _blank(chars, index, end)
            index = end
            continue
        if char == '/' and following == '*':
            end = source.find('*/', index + 2)
            end = length if end < 0 else end + 2
            _blank(chars, index, end)
            index = end
            continue
        if char in ('"', "'"):
            end = _scan_quoted(source, index)
            if end < 0:
                index += 1
                continue
            spans.append(StringSpan(index, end, source[index + 1:end - 1]))
            _blank(chars, index, end)
            index = end
            continue
        if char == '`':
            end = _scan_template(source, index)
            if end < 0:
                index += 1
                continue
            _blank(chars, index, end)
            index = end
            continue
        if char == '/' and _regex_allowed(chars, index):
            end = _scan_regex(source, index)
            if end > 0:
                _blank(chars, index, end)
                index = end
                continue
        index += 1
    return ''.join(chars), spans


# --- Import statement discovery --------------------------------------------

IMPORT_KEYWORD = re.compile(r'\b(?:import|export)\b')
TRAILING_FROM = re.compile(r'\bfrom\s*$')
TRAILING_IMPORT = re.compile(r'\bimport\s*$')
DYNAMIC_IMPORT = re.compile(r'(?:\bimport|require)\s*\(\s*$')


def iter_import_units(masked, spans):
    """Yield ``(statement_code, code_offset, specifier_span)`` for imports.

    A string literal is a module specifier only when the nearest preceding
    ``import``/``export`` keyword is still in the same statement (no ``;`` in
    between) and the code before it ends with ``from``, a bare ``import`` or an
    ``import(``/``require(`` call.
    """
    for span in spans:
        prefix_start = max(0, span.start - MAX_STATEMENT_CHARS)
        prefix = masked[prefix_start:span.start]
        keyword = None
        for match in IMPORT_KEYWORD.finditer(prefix):
            keyword = match
        if keyword is None:
            continue
        if ';' in prefix[keyword.end():]:
            continue
        code_start = prefix_start + keyword.start()
        code = masked[code_start:span.start]
        if not (TRAILING_FROM.search(code) or TRAILING_IMPORT.search(code)
                or DYNAMIC_IMPORT.search(code)):
            continue
        yield code, code_start, span


def find_rule_hits(masked, spans, line_of, rules):
    """Return sorted ``(line, rule name)`` hits for one file."""
    hits = set()
    for code, code_start, span in iter_import_units(masked, spans):
        for rule in rules:
            for match in rule.regex.finditer(span.value):
                hits.add((line_of(span.start), rule.name))
            for match in rule.regex.finditer(code):
                hits.add((line_of(code_start + match.start()), rule.name))
    return sorted(hits)


def find_specifier_hits(masked, spans, line_of, rules):
    """Return hits matching only the module specifier (used for the UI gate)."""
    hits = set()
    for _code, _code_start, span in iter_import_units(masked, spans):
        for rule in rules:
            if rule.regex.search(span.value):
                hits.add((line_of(span.start), rule.name))
    return sorted(hits)


def scan_file(path, root, rules, specifier_only=False):
    """Return ``(line, rule)`` hits for a single source file."""
    relative = path.relative_to(root).as_posix()
    try:
        source = path.read_text(encoding='utf-8-sig')
    except (OSError, UnicodeError):
        raise GateError('cannot read source file: ' + relative) from None
    masked, spans = mask_comments_and_strings(source)
    line_starts = [0]
    line_starts.extend(index + 1 for index, char in enumerate(source) if char == '\n')

    def line_of(offset):
        return bisect.bisect_right(line_starts, offset)

    if specifier_only:
        return find_specifier_hits(masked, spans, line_of, rules)
    return find_rule_hits(masked, spans, line_of, rules)


def iter_source_files(root, directories):
    """Yield deduplicated ``.ets``/``.ts`` files under the given directories."""
    seen = set()
    for directory in directories:
        base = root / directory
        if not base.is_dir():
            continue
        for path in sorted(base.rglob('*')):
            if not path.is_file() or path.suffix not in SOURCE_SUFFIXES:
                continue
            if path in seen:
                continue
            seen.add(path)
            yield path


def collect_violations(root, directories, rules, specifier_only=False):
    """Return ``(violations, scanned)``; violations are ``(path text, line, rule)``."""
    violations = []
    scanned = 0
    for path in iter_source_files(root, directories):
        scanned += 1
        relative = path.relative_to(root).as_posix()
        for line, rule_name in scan_file(path, root, rules, specifier_only):
            violations.append((relative, line, rule_name))
    violations.sort()
    return violations, scanned


def run(root):
    """Run the gate for ``root``; return the process exit status."""
    if not root.is_dir():
        raise GateError('repository root is not a directory')

    extension_violations, extension_files = collect_violations(
        root, EXTENSION_DIRS, FORBIDDEN_EXTENSION_RULES)
    ui_violations, ui_files = collect_violations(
        root, UI_DIRS, FORBIDDEN_UI_RULES, specifier_only=True)

    if extension_files == 0:
        raise GateError('no extension sources found; refusing to pass silently')

    violations = extension_violations + ui_violations
    violations.sort()
    if violations:
        for relative, line, rule_name in violations:
            print('{}:{}: forbidden import: {}'.format(relative, line, rule_name))
        print('check-clash-imports: {} violation(s) in {} extension file(s), '
              '{} UI file(s)'.format(len(violations), extension_files, ui_files),
              file=sys.stderr)
        return 1

    print('check-clash-imports: OK, {} extension file(s) and {} UI file(s) '
          'scanned, 0 violations'.format(extension_files, ui_files))
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(
        description='Static import-isolation gate for the Clash VPN extension.')
    parser.add_argument('--root', default=None,
                        help='repository root (default: derived from this script)')
    arguments = parser.parse_args(argv)
    root = Path(arguments.root).resolve() if arguments.root else REPO_ROOT
    try:
        return run(root)
    except GateError as error:
        print('check-clash-imports: error: {}'.format(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())