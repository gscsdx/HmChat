#!/usr/bin/env python3
"""Verify Harlgram's packaged arm64 libraries and notices without inspecting credentials.

Requires Python 3 and host-compatible llvm-readelf / llvm-nm from the Native SDK.
This is a package-structure gate, not a signing, account, or device-runtime test.
"""
import argparse
import hashlib
import os
from pathlib import Path, PurePosixPath
import re
import struct
import subprocess
import sys
import tempfile
import zipfile
import zlib


LIBRARIES = ('libentry.so', 'libtdjson.so', 'libc++_shared.so',
             'libclash_bridge.so', 'libclash_core.so')
# Clash licenses are searched below the dedicated clash directory first; the
# historical shared licenses directory remains a fallback for older packages.
CLASH_LICENSE_NAMES = ('FlClashX-GPL-3.0.txt', 'mihomo.txt', 'sing-tun.txt',
                       'Go.txt', 'Clash-Notices.txt')
LICENSES = ('TDLib.txt', 'OpenSSL.txt', 'SQLCipher.txt', 'LLVM.txt',
            'Libphonenumber.txt', 'Unicode-CLDR.txt', 'Harlgram-GPL-3.0.txt',
            'Harlgram-Notices.txt') + CLASH_LICENSE_NAMES
TD_EXPORTS = frozenset(('td_create_client_id', 'td_send', 'td_receive', 'td_execute'))
# The bridge resolves these C ABI symbols from the Go core at runtime. A
# packaged core without them would load but fail every user-visible action.
CLASH_CORE_EXPORTS = frozenset((
    'registerCallbacks', 'setEventListener', 'invokeAction', 'initClashSync',
    'startTUN', 'freeCString'))
CLASH_LIBRARIES = ('libclash_bridge.so', 'libclash_core.so')
MAX_LIBRARY_BYTES = 512 * 1024 * 1024
MAX_LICENSE_BYTES = 2 * 1024 * 1024


class VerificationError(Exception):
    """Only static, non-sensitive descriptions may be placed in this exception."""


class SafeArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        # argparse's default diagnostic may echo arbitrary paths/argument values.
        raise VerificationError('Invalid arguments; use --help for usage.')


def tool_path(directory, name):
    candidate = directory / name
    if not candidate.is_file():
        candidate = directory / (name + '.exe')
    if not candidate.is_file() or not os.access(candidate, os.X_OK):
        raise VerificationError('Required SDK LLVM tool is missing or not executable: ' + name)
    # SDK tools may be multicall symlinks (llvm-readelf -> llvm-readobj).
    # Preserve argv[0], which selects readelf's GNU-compatible output format.
    return candidate.absolute()


def has_shebang(path):
    try:
        with path.open('rb') as source:
            return source.read(2) == b'#!'
    except OSError:
        return False


def invoke_tool(command):
    try:
        return subprocess.run(
            command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=30, check=False, env={**os.environ, 'LC_ALL': 'C', 'LANG': 'C'})
    except subprocess.TimeoutExpired:
        raise VerificationError('SDK LLVM inspection could not complete.') from None
    except OSError:
        return None


def run_tool(tool, arguments):
    result = invoke_tool([str(tool), *arguments])
    if result is None and os.name == 'nt' and has_shebang(tool):
        # Windows has no executable-script support. Test fixtures use shebang
        # scripts; production SDK tools are real executables and never take
        # this path. Direct execution remains the only accepted form elsewhere.
        result = invoke_tool([sys.executable, str(tool), *arguments])
    if result is None:
        raise VerificationError('SDK LLVM inspection could not complete.') from None
    if result.returncode != 0 or result.stderr.strip():
        # LLVM may report damaged ELF structures as warnings with exit status 0.
        # Raw diagnostics can contain paths and bytes from the input; never echo them.
        raise VerificationError('SDK LLVM inspection rejected a native library.')
    return result.stdout.decode('utf-8', errors='replace')


def unique_suffix(members, suffix):
    matches = [item for item in members if item.filename == suffix or item.filename.endswith('/' + suffix)]
    if len(matches) != 1 or matches[0].is_dir():
        raise VerificationError('Missing or ambiguous required package member: ' + suffix)
    return matches[0]


def locate_license(members, name):
    # Prefer rawfile/clash/licenses/ (design §4.1) and fall back to the shared
    # rawfile/licenses/ directory used by the TDLib/Harlgram notices.
    for directory in ('rawfile/clash/licenses/', 'rawfile/licenses/'):
        suffix = directory + name
        matches = [item for item in members
                   if item.filename == suffix or item.filename.endswith('/' + suffix)]
        if len(matches) > 1:
            raise VerificationError('Ambiguous required package member: ' + name)
        if len(matches) == 1:
            if matches[0].is_dir():
                raise VerificationError('Missing required package license: ' + name)
            return matches[0]
    raise VerificationError('Missing required package license: ' + name)


def read_member(archive, member, limit, destination=None):
    if member.flag_bits & 1 or not 0 < member.file_size <= limit:
        raise VerificationError('A required package member is empty, encrypted, or oversized.')
    total = 0
    has_content = False
    try:
        with archive.open(member) as source:
            while True:
                chunk = source.read(1024 * 1024)
                if not chunk:
                    break
                total += len(chunk)
                if total > limit:
                    raise VerificationError('A required package member exceeds its size limit.')
                if destination is not None:
                    destination.write(chunk)
                else:
                    has_content = has_content or bool(chunk.strip())
    except (OSError, RuntimeError, NotImplementedError, zipfile.BadZipFile, EOFError, zlib.error):
        raise VerificationError('A required package member is corrupt or unreadable.') from None
    if total != member.file_size or (destination is None and not has_content):
        raise VerificationError('A required package member is empty or incomplete.')


def hash_file(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        while True:
            chunk = source.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def verify_elf(path, readelf):
    # A minimal header check avoids accepting a misleading textual tool response;
    # LLVM performs the detailed ELF inspection rather than a home-grown ELF parser.
    with path.open('rb') as source:
        header = source.read(64)
    if (len(header) != 64 or header[:7] != b'\x7fELF\x02\x01\x01'
            or struct.unpack_from('<HH', header, 16) != (3, 183)):
        raise VerificationError('A required library is not an ELF64 little-endian AArch64 shared object.')
    description = run_tool(readelf, ['--file-header', '--dynamic', str(path)])
    if (not re.search(r'^\s*Class:\s+ELF64\s*$', description, re.MULTILINE)
            or not re.search(r'^\s*Machine:\s+AArch64\s*$', description, re.MULTILINE)
            or not re.search(r'^\s*Type:\s+DYN\b', description, re.MULTILINE)):
        raise VerificationError('SDK LLVM did not confirm the required ELF architecture and type.')
    return description


def dynamic_values(description, tag):
    # Matches GNU-style `(TAG) ... [value]` lines from llvm-readelf --dynamic.
    return re.findall(r'\(' + tag + r'\)[^\r\n]*\[([^\]\r\n]+)\]', description)


def has_build_host_runpath(value):
    lowered = value.lower()
    for marker in ('d:\\', 'd:/', '/home/', '/users/', 'source-refs'):
        if marker in lowered:
            return True
    if ('\\\\' in value or value.startswith('\\')
            or re.search(r'(?<![a-z0-9])[a-z]:[\\/]', lowered)):
        return True
    # $ORIGIN and relative segments are portable; any absolute segment is not.
    return any(segment.strip().startswith('/') for segment in value.split(':'))


def defined_functions(nm, path):
    symbols = run_tool(nm, ['--dynamic', '--defined-only', '--extern-only', '--format=posix',
                            str(path)])
    functions = set()
    for line in symbols.splitlines():
        fields = line.split()
        if len(fields) >= 2 and fields[1] in ('T', 'W'):
            functions.add(fields[0])
    return functions


def verify_clash_libraries(descriptions, nm, temporary_path):
    bridge_description = descriptions['libclash_bridge.so']
    core_description = descriptions['libclash_core.so']
    if dynamic_values(bridge_description, 'SONAME') != ['libclash_bridge.so']:
        raise VerificationError('Clash bridge must have the unversioned SONAME libclash_bridge.so.')
    if dynamic_values(core_description, 'SONAME') != ['libclash_core.so']:
        raise VerificationError('Clash core must have the unversioned SONAME libclash_core.so.')
    if 'libclash_core.so' not in dynamic_values(bridge_description, 'NEEDED'):
        raise VerificationError('Clash bridge must declare DT_NEEDED libclash_core.so.')
    for library in CLASH_LIBRARIES:
        description = descriptions[library]
        for tag in ('RUNPATH', 'RPATH'):
            if any(has_build_host_runpath(value)
                   for value in dynamic_values(description, tag)):
                raise VerificationError('A Clash library contains a build-host RUNPATH or RPATH.')
    if not CLASH_CORE_EXPORTS.issubset(
            defined_functions(nm, temporary_path / 'libclash_core.so')):
        raise VerificationError('Clash core is missing one or more required C ABI exports.')


def verify(hap, llvm_bin):
    readelf = tool_path(llvm_bin, 'llvm-readelf')
    nm = tool_path(llvm_bin, 'llvm-nm')
    if not hap.is_file() or hap.stat().st_size == 0:
        raise VerificationError('The specified HAP is missing or empty.')
    with hap.open('rb') as package, zipfile.ZipFile(package) as archive:
        members = archive.infolist()
        names = [item.filename for item in members]
        if not members or len(names) != len(set(names)):
            raise VerificationError('The HAP is empty or contains duplicate archive entries.')
        for name in names:
            parts = name.rstrip('/').split('/')
            if ('\\' in name or PurePosixPath(name).is_absolute()
                    or any(part in ('', '.', '..') for part in parts)):
                raise VerificationError('The HAP contains an unsafe or ambiguous archive path.')

        library_members = {}
        for library in LIBRARIES:
            member = unique_suffix(members, 'arm64-v8a/' + library)
            if member.filename != 'libs/arm64-v8a/' + library:
                raise VerificationError('A required library is outside the HAP native library directory.')
            library_members[library] = member
        for license_name in LICENSES:
            member = locate_license(members, license_name)
            read_member(archive, member, MAX_LICENSE_BYTES)

        with tempfile.TemporaryDirectory(prefix='harlgram-hap-verify-') as temporary:
            temporary_path = Path(temporary)
            descriptions = {}
            library_digests = {}
            for library, member in library_members.items():
                output = temporary_path / library
                # Never use ZipFile.extract: only the five named native libraries
                # are written, under fixed filenames in a private temporary folder.
                with output.open('wb') as destination:
                    read_member(archive, member, MAX_LIBRARY_BYTES, destination)
                descriptions[library] = verify_elf(output, readelf)
                library_digests[library] = hash_file(output)

            if dynamic_values(descriptions['libtdjson.so'], 'SONAME') != ['libtdjson.so']:
                raise VerificationError('TDLib must have the unversioned SONAME libtdjson.so.')
            if not TD_EXPORTS.issubset(
                    defined_functions(nm, temporary_path / 'libtdjson.so')):
                raise VerificationError('TDLib is missing one or more required defined JSON C ABI function exports.')
            verify_clash_libraries(descriptions, nm, temporary_path)

        package.seek(0)
        digest = hashlib.sha256()
        while True:
            chunk = package.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest(), library_digests


def main():
    parser = SafeArgumentParser(description=__doc__)
    parser.add_argument('--hap', type=Path, required=True, help='One explicitly selected HAP file')
    tools = parser.add_mutually_exclusive_group(required=True)
    tools.add_argument('--native-sdk', type=Path, help='Native SDK root containing llvm/bin')
    tools.add_argument('--llvm-bin', type=Path, help='Directory containing host llvm-readelf and llvm-nm')
    try:
        args = parser.parse_args()
        llvm_bin = args.llvm_bin if args.llvm_bin is not None else args.native_sdk / 'llvm' / 'bin'
        digest, library_digests = verify(args.hap, llvm_bin)
    except VerificationError as error:
        print('HAP verification failed: ' + str(error), file=sys.stderr)
        return 1
    except (OSError, ValueError, EOFError, struct.error, zipfile.BadZipFile, zipfile.LargeZipFile):
        print('HAP verification failed: package or tool input is unreadable or corrupt.', file=sys.stderr)
        return 1
    print('HAP structure: PASS')
    print('Native libraries: ' + str(len(LIBRARIES)) + ' ELF64 AArch64 shared objects (arm64-v8a)')
    print('TDLib: unversioned SONAME and 4 defined JSON C ABI exports')
    print('Clash bridge: SONAME libclash_bridge.so, NEEDED libclash_core.so, portable RUNPATH')
    print('Clash core: SONAME libclash_core.so and ' + str(len(CLASH_CORE_EXPORTS))
          + ' defined C ABI exports')
    print('Clash library SHA256: libclash_bridge.so=' + library_digests['libclash_bridge.so']
          + ', libclash_core.so=' + library_digests['libclash_core.so'])
    print('Packaged license files: ' + str(len(LICENSES)))
    print('SHA256: ' + digest)
    print('Scope: package structure only; signing, account access, and device runtime are not verified.')
    return 0


if __name__ == '__main__':
    sys.exit(main())