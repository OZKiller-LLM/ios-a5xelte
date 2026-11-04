#!/bin/bash
# Pinned, portable constant-time AES for the SWEET legacy CBC/ECB API.
set -euo pipefail
case "${MACHINE_CONFIG:-}" in SWEET|A5XELTE|HEROLTE|A04S) ;; *) exit 0 ;; esac
[[ -f libkern/crypto/corecrypto_aes.c ]] || exit 1
bearssl_sha=7bea48e5e850ab4cafbe68d3765cdaba13a86d6f
bearssl_tmp=$(mktemp -d)
trap 'rm -rf "$bearssl_tmp"' EXIT
git init -q "$bearssl_tmp"
# The files this build uses from that commit, copied from a CI run that fetched it
# (xnu/vendor/bearssl-7bea48e5, MIT, LICENSE.txt and SHA256SUMS inside). Used only when
# bearssl.org cannot be reached: it answered 502 on every try for run 41835586448.
bearssl_vendor=${BEARSSL_VENDOR:-${GITHUB_WORKSPACE:-}/xnu/vendor/bearssl-${bearssl_sha:0:8}}
bearssl_source=$bearssl_tmp
# bearssl.org sometimes answers 502. The commit is pinned and checked below, so a retry is safe.
for try in 1 2 3 4; do
    if git -C "$bearssl_tmp" fetch -q --depth 1 \
        https://www.bearssl.org/git/BearSSL "$bearssl_sha"; then
        break
    fi
    if [[ $try -eq 4 ]]; then
        [[ -f "$bearssl_vendor/SHA256SUMS" ]] || exit 1
        echo "BearSSL fetch failed 4 times; using the saved copy in $bearssl_vendor" >&2
        (cd "$bearssl_vendor" && shasum -a 256 -c --quiet SHA256SUMS)
        # Every file in the copy must be listed, so nothing unchecked can come along.
        listed=$(awk '{sub(/^[*]/, "", $2); print $2}' "$bearssl_vendor/SHA256SUMS" | LC_ALL=C sort)
        present=$(cd "$bearssl_vendor" && find . -type f ! -name SHA256SUMS | sed 's#^\./##' | LC_ALL=C sort)
        [[ "$listed" == "$present" ]] || { echo "saved BearSSL copy has unlisted files" >&2; exit 1; }
        bearssl_source=$bearssl_vendor
        break
    fi
    echo "BearSSL fetch failed (try $try of 4), retrying in $((try * 20)) s" >&2
    sleep $((try * 20))
done
if [[ "$bearssl_source" == "$bearssl_tmp" ]]; then
    git -C "$bearssl_tmp" checkout -q FETCH_HEAD
    [[ "$(git -C "$bearssl_tmp" rev-parse HEAD)" == "$bearssl_sha" ]]
fi
python3 - "$bearssl_source" <<'PY'
from pathlib import Path
import shutil
import sys

source = Path(sys.argv[1])
target = Path('libkern/crypto/sweet_bearssl')
if target.exists():
    raise SystemExit(f'refusing to overwrite existing AES source: {target}')
shutil.copytree(source / 'inc', target / 'inc')
(target / 'src/symcipher').mkdir(parents=True)
for file in ('inner.h', 'config.h'):
    shutil.copy2(source / 'src' / file, target / 'src' / file)
# XNU exports machine/limits.h instead of the userspace limits.h.
header = target / 'src/inner.h'
text = header.read_text()
assert text.count('#include <limits.h>') == 1
header.write_text(text.replace('#include <limits.h>',
    '#if defined(KERNEL)\n#include <machine/limits.h>\n'
    '#else\n#include <limits.h>\n#endif'))
for name in ('aes_ct', 'aes_ct_enc', 'aes_ct_dec', 'aes_ct_cbcenc', 'aes_ct_cbcdec'):
    shutil.copy2(source / 'src/symcipher' / (name + '.c'),
                 target / 'src/symcipher' / (name + '.c'))
# MD5, SHA-1 and SHA-384/512 for the legacy hash APIs, with their codecs.
for name in ('hash/md5.c', 'codec/dec32le.c', 'codec/enc32le.c',
             'hash/sha1.c', 'codec/dec32be.c', 'codec/enc32be.c',
             'hash/sha2big.c', 'codec/dec64be.c', 'codec/enc64be.c'):
    (target / 'src' / name).parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source / 'src' / name, target / 'src' / name)
shutil.copy2(source / 'LICENSE.txt', target / 'LICENSE.txt')
PY
echo "Staged BearSSL portable AES, MD5, SHA-1 and SHA-384/512 ($bearssl_sha, from $bearssl_source) for SWEET"
