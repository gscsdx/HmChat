#!/usr/bin/env python3
"""Check the complete Git index without displaying secrets or private file contents."""
import argparse
import hashlib
import json
import pathlib
import re
import struct
import subprocess
import sys
import zlib


PNG_SIGNATURE = b'\x89PNG\r\n\x1a\n'
MAX_PNG_DECODED_BYTES = 128 * 1024 * 1024
IMAGE_SUFFIXES = {'.png', '.jpg', '.jpeg', '.webp', '.gif', '.heic', '.heif',
                  '.avif', '.tif', '.tiff', '.bmp', '.ico', '.icns', '.psd'}
ARCHIVE_SUFFIXES = {'.zip', '.7z', '.rar', '.tar', '.gz', '.tgz', '.bz2', '.xz',
                    '.zst', '.lz4', '.br', '.z', '.cab', '.iso', '.jar', '.war',
                    '.ear', '.docx', '.xlsx', '.pptx', '.pdf'}
PRIVATE_SUFFIXES = {'.p12', '.p7b', '.cer', '.keystore', '.pfx', '.jks', '.pem',
                    '.key', '.hap', '.hsp', '.app', '.so', '.a', '.o', '.dylib',
                    '.dll', '.exe', '.db', '.db-wal', '.db-shm', '.session',
                    '.log', '.bundle'}


def validate_png(data):
    """Reject unsupported metadata and malformed PNGs, including hidden stream tails.

    This validates structure, not the privacy of visible or transparent pixels.
    Human review remains necessary and is bound to the indexed file's SHA-256.
    """
    def invalid():
        raise ValueError('PNG contains unsupported metadata or invalid image data')

    if not data.startswith(PNG_SIGNATURE):
        invalid()
    allowed = {b'IHDR', b'PLTE', b'IDAT', b'IEND', b'tRNS', b'sRGB', b'gAMA', b'cHRM'}
    offset = len(PNG_SIGNATURE)
    seen = set()
    compressed_parts = []
    idat_finished = False
    palette_entries = 0
    width = height = depth = color = interlace = 0
    while offset < len(data):
        if offset + 12 > len(data):
            invalid()
        size = struct.unpack_from('>I', data, offset)[0]
        kind = data[offset + 4:offset + 8]
        end = offset + size + 12
        if kind not in allowed or end > len(data):
            invalid()
        if zlib.crc32(data[offset + 4:end - 4]) != struct.unpack_from('>I', data, end - 4)[0]:
            invalid()
        payload = data[offset + 8:end - 4]
        if not seen and kind != b'IHDR':
            invalid()
        if kind != b'IDAT' and kind in seen:
            invalid()
        if b'IDAT' in seen and kind != b'IDAT':
            idat_finished = True
        if kind == b'IHDR':
            if size != 13:
                invalid()
            width, height, depth, color, compression, filtering, interlace = struct.unpack('>IIBBBBB', payload)
            depths = {0: {1, 2, 4, 8, 16}, 2: {8, 16}, 3: {1, 2, 4, 8}, 4: {8, 16}, 6: {8, 16}}
            if not (0 < width < 2**31 and 0 < height < 2**31):
                invalid()
            if depth not in depths.get(color, set()) or compression != 0 or filtering != 0 or interlace not in (0, 1):
                invalid()
        elif kind == b'PLTE':
            if b'IDAT' in seen or b'tRNS' in seen or color in (0, 4) or size == 0 or size > 768 or size % 3:
                invalid()
            palette_entries = size // 3
            if color == 3 and palette_entries > 2**depth:
                invalid()
        elif kind == b'tRNS':
            if b'IDAT' in seen:
                invalid()
            if color == 0:
                if size != 2 or struct.unpack('>H', payload)[0] >= 2**depth:
                    invalid()
            elif color == 2:
                if size != 6 or any(value >= 2**depth for value in struct.unpack('>HHH', payload)):
                    invalid()
            elif color == 3:
                if not palette_entries or not 0 < size <= palette_entries:
                    invalid()
            else:
                invalid()
        elif kind in (b'sRGB', b'gAMA', b'cHRM'):
            if b'PLTE' in seen or b'IDAT' in seen:
                invalid()
            if kind == b'sRGB' and (size != 1 or payload[0] > 3):
                invalid()
            if kind == b'gAMA' and (size != 4 or struct.unpack('>I', payload)[0] == 0):
                invalid()
            if kind == b'cHRM' and size != 32:
                invalid()
        elif kind == b'IDAT':
            if idat_finished or (color == 3 and not palette_entries):
                invalid()
            compressed_parts.append(payload)
        elif kind == b'IEND':
            if size != 0 or not compressed_parts or end != len(data):
                invalid()
        seen.add(kind)
        offset = end
    if b'IEND' not in seen:
        invalid()

    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[color]
    passes = [(0, 0, 1, 1)] if interlace == 0 else [
        (0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4),
        (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]
    rows = []
    for x, y, dx, dy in passes:
        pass_width = max(0, (width - x + dx - 1) // dx)
        pass_height = max(0, (height - y + dy - 1) // dy)
        if pass_width and pass_height:
            rows.append((pass_height, (pass_width * channels * depth + 7) // 8 + 1))
    expected = sum(count * row_bytes for count, row_bytes in rows)
    if expected > MAX_PNG_DECODED_BYTES:
        raise ValueError('PNG exceeds the public image validation size limit')
    try:
        decoder = zlib.decompressobj()
        decoded = decoder.decompress(b''.join(compressed_parts), expected + 1)
    except zlib.error:
        invalid()
    if not decoder.eof or decoder.unused_data or decoder.unconsumed_tail or len(decoded) != expected:
        invalid()
    offset = 0
    for count, row_bytes in rows:
        for _ in range(count):
            if decoded[offset] > 4:
                invalid()
            offset += row_bytes


def decode_public_text(data):
    """Accept well-formed UTF text; a BOM is required for UTF-16/32."""
    if data.startswith((b'\xff\xfe\x00\x00', b'\x00\x00\xfe\xff')):
        encoding = 'utf-32'
    elif data.startswith((b'\xff\xfe', b'\xfe\xff')):
        encoding = 'utf-16'
    else:
        encoding = 'utf-8-sig'
    try:
        content = data.decode(encoding)
    except UnicodeError:
        raise ValueError('unsupported binary or text encoding') from None
    if re.search(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]', content):
        raise ValueError('unsupported binary or control characters')
    return content


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--staged', action='store_true', help='Compatibility flag; always checks the complete index')
    parser.parse_args()
    root = pathlib.Path(__file__).resolve().parent.parent
    # A changed-file diff cannot establish that the whole publishable snapshot is safe.
    files = subprocess.check_output(['git', 'ls-files', '-z'], cwd=root).decode().split('\0')
    records = subprocess.check_output(['git', 'ls-files', '--stage', '-z'], cwd=root).decode().split('\0')
    modes = {record.split('\t', 1)[1]: record.split(' ', 1)[0] for record in records if record}

    def indexed(name):
        return subprocess.check_output(['git', 'show', ':' + name], cwd=root, stderr=subprocess.DEVNULL)

    try:
        manifest = json.loads(indexed('config/public-assets.json'))
        reviewed_images = manifest['sha256']
        if not isinstance(reviewed_images, dict):
            raise ValueError('invalid image manifest')
    except (ValueError, KeyError, TypeError, subprocess.CalledProcessError):
        reviewed_images = {}
    local_secret = ''
    try:
        local_config = json.loads((root / 'config/telegram.local.json').read_text())
        candidate = local_config.get('apiHash', '')
        if isinstance(candidate, str) and len(candidate) == 32:
            local_secret = candidate
    except (OSError, ValueError, AttributeError):
        pass
    blocked = []
    for name in filter(None, files):
        path = pathlib.PurePosixPath(name)
        suffix = path.suffix.lower()
        private = (modes.get(name) in ('120000', '160000')
                   or name in ('build-profile.json5', 'local.properties', 'config/telegram.local.json')
                   or name.endswith('TelegramBuildConfig.ets')
                   or path.name == 'PrivateDraftFixture.ets'
                   or path.name.startswith('PrivateDraftFixture.ets.tmp-')
                   or path.name in ('.env', '.DS_Store')
                   or (path.name.startswith('.env.') and path.name != '.env.example')
                   or any(part in ('.local', '.idea', '.hvigor', 'artifacts', 'oh_modules', 'node_modules', 'build') for part in path.parts)
                   or suffix in PRIVATE_SUFFIXES | ARCHIVE_SUFFIXES)
        if private:
            blocked.append((name, 'private, generated or unsupported archive file'))
            continue
        try:
            data = indexed(name)
        except subprocess.CalledProcessError:
            blocked.append((name, 'index entry cannot be read'))
            continue
        if local_secret and local_secret.encode() in data:
            blocked.append((name, 'local application secret'))
        if data.startswith(PNG_SIGNATURE) or suffix in IMAGE_SUFFIXES:
            # Public raster assets currently support PNG only. Content, extension,
            # indexed review hash and strict parsing must all agree.
            if suffix != '.png' or not data.startswith(PNG_SIGNATURE):
                blocked.append((name, 'unsupported image format or mismatched extension'))
                continue
            if reviewed_images.get(name) != hashlib.sha256(data).hexdigest():
                blocked.append((name, 'image is not in the reviewed public asset manifest'))
            try:
                validate_png(data)
            except ValueError as error:
                blocked.append((name, str(error)))
            continue
        try:
            content = decode_public_text(data)
        except ValueError as error:
            blocked.append((name, str(error)))
            continue
        if local_secret and local_secret in content:
            blocked.append((name, 'local application secret'))
        # Check decoded BOM text as well as ordinary UTF-8; never report values.
        if re.search(r'-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?-----', content):
            blocked.append((name, 'private key'))
        if re.search(r'(?i)(?:api_?hash|TELEGRAM_API_HASH)[\s\"\x27: =]+[\"\x27]?[0-9a-f]{32}', content):
            blocked.append((name, 'Telegram application secret'))
        if re.search(r'(?i)\b(?:storePassword|keyPassword)[\"\x27]?\s*[:=]\s*[\"\x27][^\"\x27]+', content):
            blocked.append((name, 'signing password'))
        if re.search(r'gh[pousr]_[A-Za-z0-9_]{30,}|github_pat_[A-Za-z0-9_]{40,}|AKIA[0-9A-Z]{16}', content):
            blocked.append((name, 'access token'))
        if re.search(r'/(?:Users)/[^/\s\"\x27`]+/', content):
            blocked.append((name, 'personal home directory'))
    if blocked:
        for name, reason in blocked:
            print(f'拒绝公开：{name}（{reason}）', file=sys.stderr)
        return 1
    print(f'公开文件检查通过：{len(list(filter(None, files)))} 个文件；未输出任何私有配置。')
    return 0


if __name__ == '__main__':
    sys.exit(main())
