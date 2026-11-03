#!/usr/bin/env python3
"""Encrypt the plain toolkit zip into payload.bin for the password-protected EXE.

Format (all binary, read by .github/scripts/unpack.ps1 on the client):
    'IDZ1' (4) | salt (16) | iv (16) | hmac-sha256 (32) | aes-256-cbc ciphertext

Keys: PBKDF2-HMAC-SHA256(password, salt, 200000) -> 64 bytes;
      first 32 = AES key, last 32 = HMAC key. HMAC covers iv + ciphertext,
      so a wrong password is detected before anything is decrypted.

Password comes from the TOOLKIT_PASSWORD environment variable (a GitHub
Actions secret) - never from the command line or the repo.

Usage: encrypt-payload.py <plain.zip> <payload.bin>
"""
import hashlib
import hmac
import os
import subprocess
import sys

ITERATIONS = 200_000


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    src, dst = sys.argv[1], sys.argv[2]
    pw = os.environ.get("TOOLKIT_PASSWORD", "")
    if not pw:
        print("FAIL - TOOLKIT_PASSWORD is empty. Add it under repo Settings > Secrets > Actions.")
        return 1
    if '"' in pw:
        print('FAIL - TOOLKIT_PASSWORD must not contain a double-quote character.')
        return 1

    salt, iv = os.urandom(16), os.urandom(16)
    keys = hashlib.pbkdf2_hmac("sha256", pw.encode("utf-8"), salt, ITERATIONS, dklen=64)
    enc_key, mac_key = keys[:32], keys[32:]

    with open(src, "rb") as f:
        plain = f.read()
    # openssl does PKCS7 padding by default - matches .NET PaddingMode.PKCS7
    ct = subprocess.run(
        ["openssl", "enc", "-aes-256-cbc", "-nosalt", "-K", enc_key.hex(), "-iv", iv.hex()],
        input=plain, capture_output=True, check=True,
    ).stdout
    tag = hmac.new(mac_key, iv + ct, hashlib.sha256).digest()

    with open(dst, "wb") as f:
        f.write(b"IDZ1" + salt + iv + tag + ct)
    print(f"payload: {len(plain)} plain bytes -> {os.path.getsize(dst)} encrypted bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
