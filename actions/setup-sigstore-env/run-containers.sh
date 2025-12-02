#!/usr/bin/env bash
#
# Copyright 2025 The Sigstore Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# <cmd> || return is so the script can exit early without quitting your shell.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  return() { exit "${1:-$?}"; }
fi

START_FULCIO=true
START_REKOR=true
START_TSA=true
START_REKOR_TILES=true

while [[ "$#" -gt 0 ]]; do
  case $1 in
    --no-fulcio) START_FULCIO=false; ;;
    --no-rekor) START_REKOR=false; ;;
    --no-tsa) START_TSA=false; ;;
    --no-rekor-tiles) START_REKOR_TILES=false; ;;
    *) echo "Unknown parameter passed: $1"; exit 1 ;;
  esac
  shift
done

TEMP_DIR="${TEMP_DIR:-$(mktemp -d)}"
CWD="$(pwd)"

SERVICES_TO_START=()
SERVICES_TO_START+=("fakeoidc")
if [ "$START_FULCIO" = true ]; then
  SERVICES_TO_START+=("fulcio-server" "ct-server" "dex-idp")
fi
if [ "$START_REKOR" = true ]; then
  SERVICES_TO_START+=("rekor-server" "trillian-log-server" "trillian-log-signer" "mysql" "redis-server")
fi
if [ "$START_REKOR_TILES" = true ]; then
  SERVICES_TO_START+=("rekor-tiles" "spanner" "gcs" "witness" "rekor_init")
fi
if [ "$START_TSA" = true ]; then
  SERVICES_TO_START+=("timestamp-server")
fi

echo "starting services"
UNIQUE_SERVICES=($(echo "${SERVICES_TO_START[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))
if [ ${#UNIQUE_SERVICES[@]} -gt 0 ]; then
  echo "Starting services: ${UNIQUE_SERVICES[@]}"
  docker compose up --wait "${UNIQUE_SERVICES[@]}"
else
  echo "No services to start."
fi

export ISSUER_URL="http://fakeoidc:8080"
export OIDC_URL="http://localhost:8080"
export CT_LOG_KEY="$CWD/config/fulcio/ctfe/pubkey.pem"

export OIDC_TOKEN="$TEMP_DIR"/token
curl -o "$OIDC_TOKEN" "$OIDC_URL/token" || return
# Cosign's OIDC provider will use this environment variable to get the OIDC token.
SIGSTORE_ID_TOKEN="$(cat "$OIDC_TOKEN")"
export SIGSTORE_ID_TOKEN

stop_services() {
  docker compose down --volumes
}

echo "building trusted root"
pushd "$TEMP_DIR" || return
BUILD_CMD=("$CWD/build-trusted-root.sh" --oidc-url http://localhost:8080)
if [ "$START_FULCIO" = true ]; then
  BUILD_CMD+=(--fulcio http://localhost:5555 "$CWD/config/fulcio/ctfe/pubkey.pem")
fi
if [ "$START_TSA" = true ]; then
  BUILD_CMD+=(--timestamp-url http://localhost:3004)
fi
if [ "$START_REKOR" = true ]; then
  BUILD_CMD+=(--rekor-v1-url http://localhost:3000)
fi
if [ "$START_REKOR_TILES" = true ]; then
  BUILD_CMD+=(--rekor-v2 http://localhost:3003 "$CWD/config/rekor-tiles/pki/ed25519-pub-key.pem" "rekor-local")
fi
"${BUILD_CMD[@]}" || return
export TRUSTED_ROOT="$TEMP_DIR/trusted_root.json"
export SIGNING_CONFIG="$TEMP_DIR/signing_config.json"
export TRUST_CONFIG="$TEMP_DIR/trust_config.json"
popd || return
