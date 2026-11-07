#!/usr/bin/env python3
"""Explicit HDC shell fallback. Never terminate other clients or print HAP/log contents."""
import base64
import concurrent.futures
import hashlib
import os
import pathlib
import re
import subprocess
import sys
import uuid


def main():
    if len(sys.argv) != 4:
        print('用法：install-via-shell.py <hdc> <显式目标> <signed.hap>', file=sys.stderr)
        return 1
    hdc, target, filename = sys.argv[1:]
    source = pathlib.Path(filename)
    if not target or not os.access(hdc, os.X_OK) or not source.is_file() or source.suffix != '.hap':
        print('分块安装参数无效。', file=sys.stderr)
        return 1
    remote = '/data/local/tmp/harlgram-transfer-' + uuid.uuid4().hex
    created = False

    def shell(command, timeout=30):
        result = subprocess.run([hdc, '-t', target, 'shell', command],
                                capture_output=True, timeout=timeout, check=True)
        return result.stdout

    try:
        payload = source.read_bytes()
        if not payload or len(payload) > 512 * 1024 * 1024:
            raise ValueError('invalid size')
        shell('mkdir -p ' + remote)
        created = True
        chunks = [payload[i:i + 36000] for i in range(0, len(payload), 36000)]

        def send(item):
            index, chunk = item
            encoded = base64.b64encode(chunk).decode('ascii')
            # Base64 has no shell quote/metacharacters; remote consists only of a fixed prefix and UUID.
            shell("echo '" + encoded + "' | base64 -d > " + remote + '/part%05d' % index)

        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            for _ in pool.map(send, enumerate(chunks)):
                pass
        shell('cat ' + remote + '/part* > ' + remote + '/app.hap')
        actual = shell('sha256sum ' + remote + '/app.hap').decode('ascii').split()[0]
        if not re.fullmatch(r'[0-9a-f]{64}', actual) or actual != hashlib.sha256(payload).hexdigest():
            raise ValueError('checksum mismatch')
        result = shell('bm install -r -p ' + remote + '/app.hap', timeout=180)
        if not re.search(rb'\bsuccessfully\b', result, re.IGNORECASE):
            raise ValueError('install not confirmed')
        print('HAP SHA-256 verified; installed successfully via shell.')
        return 0
    except (OSError, ValueError, IndexError, subprocess.SubprocessError):
        # Subprocess exception strings include command arguments (base64 chunks): never print them.
        print('分块传输、校验或安装失败；未输出包内容或原始设备响应。', file=sys.stderr)
        return 1
    finally:
        if created:
            try:
                shell('rm -rf ' + remote)
            except (OSError, subprocess.SubprocessError):
                print('设备临时安装目录清理未确认。', file=sys.stderr)


if __name__ == '__main__':
    sys.exit(main())
