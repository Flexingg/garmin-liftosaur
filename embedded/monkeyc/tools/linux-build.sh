#!/usr/bin/env bash
# Linux build helper for the Liftosaur watch app (Venu 2).
#
# Requires the Connect IQ SDK 9.2.0 Linux toolchain and a DER-format developer
# key (see repo README / docs). Sets up CONNECTIQ_HOME and compiles the .prg.
#
# Usage:  ./linux-build.sh [device]      (default device: venu2)
set -euo pipefail

DEVICE="${1:-venu2}"

# Run from the embedded/monkeyc dir (parent of this script), wherever we're invoked.
cd "$(dirname "$0")/.."

# SDK installed via lindell's connect-iq-sdk-manager-cli.
SDK_HOME="${HOME}/.Garmin/ConnectIQ/Sdks/connectiq-sdk-lin-9.2.0-2026-06-09-92a1605b2"
if [ ! -d "$SDK_HOME" ]; then
  echo "ERROR: SDK not found at $SDK_HOME" >&2
  echo "Install it with: connect-iq-sdk-manager sdk set 9.2.0 && connect-iq-sdk-manager device download --manifest=manifest.xml -F" >&2
  exit 1
fi

export CONNECTIQ_HOME="$SDK_HOME"
export PATH="$SDK_HOME/bin:$PATH"

KEY="developer_key.der"
if [ ! -f "$KEY" ]; then
  echo "ERROR: missing signing key '$KEY'. Create it from the PKCS12 store:" >&2
  echo "  openssl pkcs12 -in developer_key.p12 -nocerts -nodes -out /tmp/devkey.pem" >&2
  echo "  openssl pkcs8 -topk8 -nocrypt -in /tmp/devkey.pem -outform DER -out developer_key.der" >&2
  exit 1
fi

mkdir -p bin
echo "Building for $DEVICE..."
monkeyc -d "$DEVICE" -f monkey.jungle -o "bin/Liftosaur.prg" -y "$KEY" -w
echo "Built bin/Liftosaur.prg"
