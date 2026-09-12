#!/usr/bin/env bash
# Linux build helper for the Liftosaur Garmin watch app.
#
# Verified working end-to-end on Ubuntu 26.04 with Connect IQ SDK 9.2.0 and a
# physical Venu 2S. See ../../docs/03-garmin-toolchain-and-sideload.md for the
# full story, including WHY the key size below is enforced.
#
# Usage:  ./linux-build.sh [device]        (default device: venu2s)
#         ./linux-build.sh venu2s -r        (extra flags are passed to monkeyc)
set -euo pipefail

DEVICE="${1:-venu2s}"
if [ "$#" -gt 0 ]; then shift; fi

cd "$(dirname "$0")/.."

# ---------------------------------------------------------------------------
# 1. Locate the Connect IQ SDK.
#    NOTE: do not rely on $HOME alone. When this runs under an agent/tool
#    harness, $HOME can point at a profile directory rather than the real user
#    home, which makes the SDK lookup fail with a confusing "SDK not found".
# ---------------------------------------------------------------------------
CANDIDATE_ROOTS=(
  "$HOME/.Garmin/ConnectIQ/Sdks"
  "/home/$USER/.Garmin/ConnectIQ/Sdks"
  "/home/hermes/.Garmin/ConnectIQ/Sdks"
)
SDK_HOME=""
for root in "${CANDIDATE_ROOTS[@]}"; do
  if [ -d "$root" ]; then
    # newest connectiq-sdk-lin-* wins
    hit=$(ls -d "$root"/connectiq-sdk-lin-* 2>/dev/null | sort -V | tail -1 || true)
    if [ -n "$hit" ]; then SDK_HOME="$hit"; break; fi
  fi
done
if [ -z "$SDK_HOME" ]; then
  echo "ERROR: Connect IQ SDK not found." >&2
  echo "Looked under: ${CANDIDATE_ROOTS[*]}" >&2
  echo "Install with: connect-iq-sdk-manager sdk set 9.2.0 \\" >&2
  echo "              connect-iq-sdk-manager device download --manifest=manifest.xml -F" >&2
  exit 1
fi
export CONNECTIQ_HOME="$SDK_HOME"
export PATH="$SDK_HOME/bin:$PATH"
echo "SDK: $SDK_HOME"

# ---------------------------------------------------------------------------
# 2. Signing key — MUST be RSA >= 4096 bit, PKCS#8 DER.
#
#    Hard-won, verified on real hardware (Venu 2S, firmware 19.05, SDK 9.2.0):
#    a 2048-bit key compiles fine and produces a *cryptographically valid*
#    signature, but the watch REJECTS it at install time with the misleading
#      Error: 'Signature check failed on file: <name>'
#    The identical build signed with a freshly generated 4096-bit key installs
#    and runs. So: never accept a 2048-bit key silently.
# ---------------------------------------------------------------------------
KEY="developer_key.der"
if [ ! -f "$KEY" ]; then
  cat >&2 <<'EOM'
ERROR: missing signing key 'developer_key.der'.

Generate a 4096-bit one (any RSA-4096 backup of this key matters — keep it,
you need the same key to UPLOAD future versions to the Connect IQ store):

  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out developer_key.pem
  openssl pkcs8 -topk8 -nocrypt -in developer_key.pem -outform DER -out developer_key.der

A .p12 keystore from `keytool` also works, but you must export the PRIVATE KEY
to PKCS#8 DER first — monkeyc rejects .p12 directly ("unknown version: 3").
EOM
  exit 1
fi

KEY_BITS=$(openssl pkey -in "$KEY" -inform DER -text -noout 2>/dev/null \
           | head -1 | grep -o -E '[0-9]+ bit' | grep -o -E '[0-9]+' || true)
if [ -z "$KEY_BITS" ]; then
  echo "ERROR: '$KEY' is not a readable PKCS#8 DER private key." >&2
  echo "       (A .p12/PKCS12 keystore must be exported to DER first.)" >&2
  exit 1
fi
if [ "$KEY_BITS" -lt 4096 ]; then
  cat >&2 <<EOM
ERROR: signing key is only ${KEY_BITS}-bit. The watch will REJECT this build with
       "Signature check failed on file: <name>" even though the build succeeds and
       the signature is valid — a 2048-bit key is not accepted by the device.
       Regenerate a 4096-bit key (see the block above) and rebuild.
EOM
  exit 1
fi
echo "key: $KEY (${KEY_BITS}-bit)"

# ---------------------------------------------------------------------------
# 3. Build.
# ---------------------------------------------------------------------------
mkdir -p bin
echo "Building for $DEVICE..."
monkeyc -d "$DEVICE" -f monkey.jungle -o "bin/Liftosaur.prg" -y "$KEY" -w "$@"

# Prove the artifact targets the device we think it does.
TARGET=$(strings -a bin/Liftosaur.prg | grep -o -E '006-B[0-9]{4}-00' | sort -u | tr '\n' ' ' || true)
echo "Built bin/Liftosaur.prg ($(stat -c%s bin/Liftosaur.prg) bytes) target=${TARGET:-(stripped build)}"
if [ -n "$TARGET" ] && [ "$TARGET" != "006-B3704-00 " ] && [ "$DEVICE" = "venu2s" ]; then
  echo "WARNING: expected 006-B3704-00 (Venu 2S) but artifact reports: $TARGET" >&2
fi
echo
echo "Sideload:  copy bin/Liftosaur.prg to GARMIN/APPS over MTP, then PHYSICALLY"
echo "           UNPLUG the watch (that is when it installs). See"
echo "           docs/03-garmin-toolchain-and-sideload.md"
