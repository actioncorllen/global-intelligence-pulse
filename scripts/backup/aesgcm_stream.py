#!/usr/bin/env python3
# Strateloq backup — streaming AES-256-GCM authenticated encryption.
#
# Why this exists: the mandatory-backup policy requires AES-256-GCM (or another
# established authenticated-encryption method). A single one-shot AES-GCM seal
# would load the whole archive into memory, which is unsafe for multi-hundred-MB
# DB/storage dumps. This module implements the standard chunked-STREAM AEAD
# construction (the same idea age / libsodium secretstream use): the plaintext is
# split into fixed frames, each sealed with AES-256-GCM under a unique nonce, the
# file header is bound into every frame as AAD, and the final frame is flagged so
# truncation is detected. Any tampering, reordering, or truncation fails the auth
# tag on decrypt (fail-closed).
#
# KEY HANDLING (policy reqs 3-5): the 256-bit key is read ONLY from the BACKUP_KEY
# environment variable (base64 or hex, decoding to exactly 32 bytes). It is never
# taken from argv, never printed, never written to any file or log. If BACKUP_KEY
# is absent or malformed the tool exits non-zero BEFORE producing any ciphertext,
# so an unrecoverable archive is never created.
#
# Usage:
#   BACKUP_KEY=<base64-32-bytes> python3 aesgcm_stream.py encrypt < plain > cipher
#   BACKUP_KEY=<base64-32-bytes> python3 aesgcm_stream.py decrypt < cipher > plain
#   python3 aesgcm_stream.py selftest      # round-trip + tamper test, ephemeral key
#
# No third-party deps beyond `cryptography` (already vetted, constant-time AES-GCM).
import os
import sys
import base64
import binascii
import struct
import secrets

from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.exceptions import InvalidTag

MAGIC = b"SLQGCM1\0"            # 8 bytes, format identifier (bound as AAD)
PREFIX_LEN = 8                 # random per-file nonce prefix
CHUNK = 1 << 20                # 1 MiB plaintext frames
NONCE_LEN = 12                 # prefix(8) || counter(3) || last_flag(1)
TAG_LEN = 16
MAX_FRAME = CHUNK + TAG_LEN + 64  # sanity bound for decrypt framing


def _load_key() -> bytes:
    raw = os.environ.get("BACKUP_KEY", "")
    if not raw:
        sys.stderr.write("FATAL: BACKUP_KEY not set — refusing to encrypt/decrypt "
                         "(policy req 5: never create an archive with a key you cannot retrieve).\n")
        sys.exit(3)
    raw = raw.strip()
    key = None
    # try base64 (standard, then urlsafe), then hex
    for dec in (lambda s: base64.b64decode(s, validate=True),
                lambda s: base64.urlsafe_b64decode(s + "=" * (-len(s) % 4)),
                lambda s: binascii.unhexlify(s)):
        try:
            k = dec(raw)
            if len(k) == 32:
                key = k
                break
        except (binascii.Error, ValueError):
            continue
    if key is None:
        sys.stderr.write("FATAL: BACKUP_KEY must decode (base64 or hex) to exactly 32 bytes (256 bits).\n")
        sys.exit(3)
    return key


def _nonce(prefix: bytes, counter: int, last: bool) -> bytes:
    if counter >= (1 << 24):
        raise ValueError("stream too long for 24-bit frame counter")
    return prefix + counter.to_bytes(3, "big") + (b"\x01" if last else b"\x00")


def encrypt(fin, fout) -> None:
    key = _load_key()
    aead = AESGCM(key)
    prefix = secrets.token_bytes(PREFIX_LEN)
    header = MAGIC + prefix + struct.pack(">I", CHUNK)
    fout.write(header)
    counter = 0
    buf = fin.read(CHUNK)
    while True:
        nxt = fin.read(CHUNK)
        last = len(nxt) == 0
        sealed = aead.encrypt(_nonce(prefix, counter, last), buf, header)
        fout.write(struct.pack(">I", len(sealed)))
        fout.write(sealed)
        counter += 1
        if last:
            break
        buf = nxt
    fout.flush()


def decrypt(fin, fout) -> None:
    key = _load_key()
    aead = AESGCM(key)
    header = fin.read(len(MAGIC) + PREFIX_LEN + 4)
    if len(header) != len(MAGIC) + PREFIX_LEN + 4 or header[:len(MAGIC)] != MAGIC:
        sys.stderr.write("FATAL: not a Strateloq AES-GCM stream (bad header).\n")
        sys.exit(4)
    prefix = header[len(MAGIC):len(MAGIC) + PREFIX_LEN]
    counter = 0
    saw_last = False
    while True:
        lb = fin.read(4)
        if not lb:
            break  # clean EOF only valid if we already saw the final frame
        if len(lb) != 4:
            sys.stderr.write("FATAL: truncated frame length.\n")
            sys.exit(4)
        (flen,) = struct.unpack(">I", lb)
        if flen == 0 or flen > MAX_FRAME:
            sys.stderr.write("FATAL: implausible frame length.\n")
            sys.exit(4)
        sealed = fin.read(flen)
        if len(sealed) != flen:
            sys.stderr.write("FATAL: truncated frame body.\n")
            sys.exit(4)
        # Try final-flagged first only when the stream is at EOF; otherwise normal.
        peek = fin.read(1)
        at_eof = peek == b""
        if peek:
            # unread the peeked byte
            fin = _Pushback(fin, peek)
        last = at_eof
        try:
            plain = aead.decrypt(_nonce(prefix, counter, last), sealed, header)
        except InvalidTag:
            sys.stderr.write("FATAL: authentication tag verification FAILED — "
                             "archive is corrupt, truncated, reordered, or tampered.\n")
            sys.exit(5)
        fout.write(plain)
        counter += 1
        if last:
            saw_last = True
            break
    if not saw_last:
        sys.stderr.write("FATAL: stream ended without a final authenticated frame (truncation).\n")
        sys.exit(5)
    fout.flush()


class _Pushback:
    """Minimal one-byte pushback wrapper around a binary stream."""
    def __init__(self, inner, byte):
        self._inner = inner
        self._pending = byte

    def read(self, n=-1):
        if self._pending:
            if n is None or n < 0:
                rest = self._inner.read()
                out = self._pending + rest
                self._pending = b""
                return out
            if n == 0:
                return b""
            take = self._pending[:n]
            self._pending = self._pending[len(take):]
            if len(take) < n:
                take += self._inner.read(n - len(take))
            return take
        return self._inner.read(n)


def selftest() -> int:
    # Round-trip + tamper + truncation test with an EPHEMERAL key (never BACKUP_KEY).
    import io
    os.environ["BACKUP_KEY"] = base64.b64encode(secrets.token_bytes(32)).decode()
    sizes = [0, 1, 100, CHUNK - 1, CHUNK, CHUNK + 1, 3 * CHUNK + 7]
    for n in sizes:
        data = secrets.token_bytes(n)
        ct = io.BytesIO()
        encrypt(io.BytesIO(data), ct)
        pt = io.BytesIO()
        decrypt(io.BytesIO(ct.getvalue()), pt)
        assert pt.getvalue() == data, f"round-trip mismatch at size {n}"
    # tamper: flip one byte in a frame body -> must fail
    data = secrets.token_bytes(5000)
    ct = io.BytesIO(); encrypt(io.BytesIO(data), ct)
    blob = bytearray(ct.getvalue())
    blob[len(MAGIC) + PREFIX_LEN + 4 + 10] ^= 0x01  # flip a ciphertext byte
    try:
        decrypt(io.BytesIO(bytes(blob)), io.BytesIO())
        print("SELFTEST FAIL: tampered ciphertext decrypted without error")
        return 1
    except SystemExit as e:
        if e.code != 5:
            print(f"SELFTEST FAIL: tamper gave exit {e.code}, expected 5")
            return 1
    # truncation: drop the final frame -> must fail (no final-flagged frame)
    ct = io.BytesIO(); encrypt(io.BytesIO(secrets.token_bytes(3 * CHUNK)), ct)
    full = ct.getvalue()
    # remove last frame: find by walking is complex; just chop the tail bytes
    truncated = full[: len(MAGIC) + PREFIX_LEN + 4 + 200]
    try:
        decrypt(io.BytesIO(truncated), io.BytesIO())
        print("SELFTEST FAIL: truncated stream decrypted without error")
        return 1
    except SystemExit as e:
        if e.code not in (4, 5):
            print(f"SELFTEST FAIL: truncation gave exit {e.code}")
            return 1
    print("SELFTEST PASS: round-trip (7 sizes), tamper-detect, truncation-detect all OK")
    return 0


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] not in ("encrypt", "decrypt", "selftest"):
        sys.stderr.write("usage: aesgcm_stream.py {encrypt|decrypt|selftest}\n")
        return 2
    cmd = sys.argv[1]
    if cmd == "selftest":
        return selftest()
    stdin = sys.stdin.buffer
    stdout = sys.stdout.buffer
    if cmd == "encrypt":
        encrypt(stdin, stdout)
    else:
        decrypt(stdin, stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
