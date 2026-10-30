#!/bin/zsh
# Create a trusted self-signed code-signing identity in the login keychain (once).
# A stable identity keeps the Accessibility (TCC) grant valid across helper rebuilds.
# macOS asks for your login password once (trust settings change).
set -euo pipefail

IDENTITY="${REFLEX_CODESIGN_IDENTITY:-DSH Reflex Local Code Signing}"
export REFLEX_LOCAL_SIGNING_IDENTITY="$IDENTITY"
python3 <<'PY'
import os
import pathlib
import secrets
import subprocess
import tempfile

identity = os.environ["REFLEX_LOCAL_SIGNING_IDENTITY"]
keychain = os.path.expanduser("~/Library/Keychains/login.keychain-db")
existing = subprocess.run(
    ["security", "find-identity", "-v", "-p", "codesigning"],
    text=True, capture_output=True, check=True,
).stdout
if f'"{identity}"' in existing:
    print(f"Code-signing identity already exists: {identity}")
    raise SystemExit(0)

config = f'''[ req ]
distinguished_name = dn
x509_extensions = extensions
prompt = no

[ dn ]
CN = {identity}
O = DSH Reflex Development
C = CN

[ extensions ]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
'''

with tempfile.TemporaryDirectory(prefix="reflex-signing-") as directory:
    root = pathlib.Path(directory)
    (root / "openssl.cnf").write_text(config)
    subprocess.run([
        "openssl", "req", "-new", "-newkey", "rsa:3072", "-nodes", "-x509",
        "-sha256", "-days", "3650", "-config", str(root / "openssl.cnf"),
        "-keyout", str(root / "reflex.key"), "-out", str(root / "reflex.crt"),
    ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    password = secrets.token_hex(24)
    export = [
        "openssl", "pkcs12", "-export", "-legacy",
        "-inkey", str(root / "reflex.key"), "-in", str(root / "reflex.crt"),
        "-name", identity, "-passout", f"pass:{password}",
        "-out", str(root / "reflex.p12"),
    ]
    result = subprocess.run(export, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if result.returncode != 0:
        # LibreSSL shipped by older macOS releases predates the -legacy flag.
        export.remove("-legacy")
        subprocess.run(export, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run([
        "security", "import", str(root / "reflex.p12"), "-k", keychain,
        "-P", password, "-T", "/usr/bin/codesign", "-T", "/usr/bin/security",
    ], check=True, stdout=subprocess.DEVNULL)
    subprocess.run([
        "security", "add-trusted-cert", "-r", "trustRoot", "-k", keychain,
        str(root / "reflex.crt"),
    ], check=True, stdout=subprocess.DEVNULL)

print(f"Created trusted local code-signing identity: {identity}")
PY
