#!/usr/bin/env bash

# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# shellcheck source=/dev/null
if [[ -r /etc/profile.d/openclaw.sh ]]; then
  . /etc/profile.d/openclaw.sh
fi

if [[ -n "${OPENCLAW_PROFILE:-}" ]]; then
  echo "openclaw-start: OPENCLAW_PROFILE is not supported" >&2
  exit 2
fi

config="${OPENCLAW_CONFIG_PATH:-${OPENCLAW_STATE_DIR:-${OPENCLAW_HOME:-$HOME}/.openclaw}/openclaw.json}"

if [[ ! -e "${config}" ]]; then
  missing=()
  if [[ -z "${MODEL_BASE_URL:-}" ]]; then
    missing+=("MODEL_BASE_URL")
  fi
  if [[ -z "${MODEL_ID:-}" ]]; then
    missing+=("MODEL_ID")
  fi
  if [[ -z "${CUSTOM_API_KEY:-}" ]]; then
    missing+=("CUSTOM_API_KEY")
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    names=""
    for name in "${missing[@]}"; do
      if [[ -z "${names}" ]]; then
        names="${name}"
      else
        names="${names}, ${name}"
      fi
    done
    echo "openclaw-start: no OpenClaw config at ${config}; set ${names} for first-run setup" >&2
    for name in "${missing[@]}"; do
      if [[ "${name}" == "CUSTOM_API_KEY" ]]; then
        echo "openclaw-start: attach an OpenShell provider of type openclaw-model (see model-provider-profile.yaml); it injects CUSTOM_API_KEY and allows /usr/bin/node to reach the model host:port. For an endpoint without auth, create it with --credential CUSTOM_API_KEY=unused" >&2
        break
      fi
    done
    exit 2
  fi

  if ! out=$(openclaw onboard \
    --non-interactive \
    --accept-risk \
    --mode local \
    --auth-choice custom-api-key \
    --custom-base-url "$MODEL_BASE_URL" \
    --custom-model-id "$MODEL_ID" \
    --custom-compatibility openai \
    --custom-provider-id openshell-model \
    --custom-text-input \
    --secret-input-mode ref \
    --gateway-bind loopback \
    --gateway-auth token \
    --gateway-port 18789 \
    --skip-channels \
    --skip-daemon \
    --skip-health \
    --skip-search \
    --skip-skills \
    --skip-ui \
    --skip-hooks \
    --json 2>&1); then
    printf '%s\n' "${out}" >&2
    echo "openclaw-start: onboarding failed" >&2
    exit 1
  fi

  echo "openclaw-start: wrote ${config} (provider openshell-model, model ${MODEL_ID})" >&2
fi

if (($# == 0)); then
  set -- tui --local
fi

exec openclaw "$@"
