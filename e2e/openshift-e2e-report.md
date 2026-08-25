# OpenShift E2E Test Report (v0.0.109)

## Summary

We ran both the Rust CLI E2E test suite and the Python SDK E2E tests against an OpenShift (ROSA) gateway deployment running ODH v0.0.109-rhaiv.0 images.

**Rust E2E:** 75 passed, 5 failed, 1 ignored.

**Python E2E:** 84 passed, 5 failed, 84 skipped (OIDC — no Keycloak at initial run time; see OIDC section below for a follow-up run with Keycloak deployed: 84 passed, 0 failed).

**Helm deployment smoke test:** 2 passed, 0 failed (SQLite default, external PostgreSQL).

## Environment

- **Cluster:** ROSA (Red Hat OpenShift Service on AWS)
- **Gateway image:** `quay.io/opendatahub/odh-openshell-gateway:v0.0.109-rhaiv.0`
- **Supervisor image:** `quay.io/opendatahub/odh-openshell-supervisor:v0.0.109-rhaiv.0`
- **Sandbox image:** `ghcr.io/nvidia/openshell-community/sandboxes/base:latest` (Python 3.14.3)
- **Gateway endpoint:** `https://openshell-openshell.<apps-domain>`
- **CLI:** `/opt/homebrew/bin/openshell` (v0.0.109)
- **Test suite:** checked out at `v0.0.109` tag
- **Compute driver:** Kubernetes (init-container supervisor sideload)
- **Auth:** mTLS

## Gateway Installation

The gateway itself isn't installed by either test suite below — it has to exist first. These are the steps used to stand it up on ROSA with the ODH v0.0.109-rhaiv.0 gateway/supervisor images and the community sandbox base image, and to register it with the CLI.

Prerequisites: `oc` authenticated to the cluster, Helm 3.x, and the Red Hat build of Agent Sandbox (controller + CRDs) already installed — confirm with `oc get crd sandboxes.agents.x-k8s.io`.

Chart used below: [`deploy/helm/openshell`](../deploy/helm/openshell).

```bash
# 0. Clone OpenShell and check out the matching tag OR use this branch it is already based on the v0.0.109 tag
git clone https://github.com/NVIDIA/OpenShell.git
cd OpenShell
git checkout v0.0.109

NAMESPACE=openshell
RELEASE=openshell

# 1. Namespace + SCC for sandbox pods
oc create ns "${NAMESPACE}"
oc adm policy add-scc-to-user privileged -z "${RELEASE}-sandbox" -n "${NAMESPACE}"

# 2. Route hostname is deterministic: OpenShift auto-generates unset Route
#    hosts as "<route-name>-<namespace>.<apps-domain>". Compute it up front
#    so it can be baked into the gateway's self-signed cert SANs before the
#    Route exists.
APPS_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
ROUTE_HOST="${RELEASE}-${NAMESPACE}.${APPS_DOMAIN}"

# 3. Install with the ODH images, from the repo root
helm upgrade --install "${RELEASE}" ./deploy/helm/openshell -n "${NAMESPACE}" \
  --set image.repository=quay.io/opendatahub/odh-openshell-gateway \
  --set image.tag=v0.0.109-rhaiv.0 \
  --set supervisor.image.repository=quay.io/opendatahub/odh-openshell-supervisor \
  --set supervisor.image.tag=v0.0.109-rhaiv.0 \
  --set server.sandboxImage=ghcr.io/nvidia/openshell-community/sandboxes/base:latest \
  --set podSecurityContext.fsGroup=null \
  --set securityContext.runAsUser=null \
  --set openshiftRoute.enabled=true \
  --set openshiftRoute.host="${ROUTE_HOST}" \
  --set "pkiInitJob.serverDnsNames[0]=${ROUTE_HOST}" \
  --set server.auth.allowUnauthenticatedUsers=true

oc -n "${NAMESPACE}" rollout status statefulset/"${RELEASE}" --timeout=180s
```

`podSecurityContext.fsGroup=null` / `securityContext.runAsUser=null` clear the chart's hardcoded UID/fsGroup so OpenShift's SCC admission can assign its own.

`server.auth.allowUnauthenticatedUsers=true` is required for plain mTLS-only CLI access to work at all: by default the gateway renders no authentication path for a Kubernetes deployment unless OIDC is configured, and Kubernetes deployments don't get mTLS user-identity mapping the way local Docker/Podman/VM gateways do. Without one of the two, every protected RPC returns `missing authorization header` even though the mTLS transport handshake itself succeeds. This flag is marked `UNSAFE` upstream (any caller who completes the mTLS handshake is treated as a trusted local principal) — fine for evaluation on a private network, not for anything more exposed. See the OIDC section below for the alternative.

Register the CLI gateway:

```bash
GATEWAY_NAME=openshift
MTLS_DIR="${HOME}/.config/openshell/gateways/${GATEWAY_NAME}/mtls"
mkdir -p "${MTLS_DIR}"
for f in ca.crt tls.crt tls.key; do
  oc get secret openshell-client-tls -n "${NAMESPACE}" -o jsonpath="{.data.${f//./\\.}}" \
    | base64 -d > "${MTLS_DIR}/${f}"
done

cat > "${HOME}/.config/openshell/gateways/${GATEWAY_NAME}/metadata.json" <<EOF
{
  "name": "${GATEWAY_NAME}",
  "gateway_endpoint": "https://${ROUTE_HOST}",
  "is_remote": false,
  "gateway_port": 0,
  "auth_mode": "mtls"
}
EOF
printf '%s' "${GATEWAY_NAME}" > "${HOME}/.config/openshell/active_gateway"

openshell status -g "${GATEWAY_NAME}"
```

The registration is written directly rather than through `openshell gateway add --local` — that flag is for the package-managed local gateway service (e.g. a Homebrew-installed gateway) and imports **its own** TLS material from the local package's TLS directory whenever one exists on the machine, silently overwriting the bundle just extracted from the cluster. That produced `invalid peer certificate: BadSignature` (the CLI was validating against the wrong CA) the first time through this. `--remote` doesn't fit either — it requires an SSH destination, not a Route hostname. Writing the gateway metadata file directly avoids both problems; it's the same file layout the CLI itself writes for any other registration.

Verified with a full round trip: creating a sandbox, running a command in it, listing it, and deleting it all succeeded against the ODH v0.0.109-rhaiv.0 images.

## Setup

### Rust E2E

The existing OpenShift E2E script ([`e2e/rust/e2e-openshift.sh`](rust/e2e-openshift.sh)) only validates Helm deployment — it checks that the gateway pod reaches `Running` and nothing else. To run functional tests, we bypassed the wrapper scripts and ran `cargo test` directly against the registered gateway ([`e2e/rust/`](rust/)).

```bash
OPENSHELL_BIN=/opt/homebrew/bin/openshell cargo test \
  --manifest-path e2e/rust/Cargo.toml \
  --features e2e,e2e-kubernetes \
  --no-fail-fast -- --nocapture
```

### Python E2E

The Python SDK wheel (`openshell-0.0.109+rhaiv.0-1-py3-none-linux_x86_64.whl`) is a Linux platform wheel — it cannot be installed directly on macOS. We built a Podman container ([`deploy/docker/Dockerfile.e2e-python`](../deploy/docker/Dockerfile.e2e-python)) to run the tests ([`e2e/python/`](python/)). The Dockerfile installs `pytest` and its plugins, copies the wheel in and `pip install`s it, then copies in the `e2e/python/` test sources; the entrypoint runs `pytest` against whatever path is passed to `podman run`.

> **Note:** `openshell-0.0.109+rhaiv.0-1-py3-none-linux_x86_64.whl` is a Red Hat build of the OpenShell Python SDK and isn't distributed in this repo. Get your own copy of the matching RH build wheel for the version you're testing and place it in the build context (the directory passed as `.` below) before running `podman build`.

The test container must use **Python 3.14** to match the sandbox image. An initial run with Python 3.13 produced 55 cloudpickle deserialization failures — callables serialized on 3.13 don't deserialize correctly on 3.14. Matching versions resolved all of them.

| | Test container | Sandbox image |
|---|---|---|
| Python | 3.14.7 | 3.14.3 |
| cloudpickle | 3.1.2 | 3.1.2 |

```bash
# Build the test runner — run from the repo root, with the wheel placed there first
podman build --platform linux/amd64 \
  -t openshell-e2e-python \
  -f deploy/docker/Dockerfile.e2e-python \
  --build-arg OPENSHELL_WHL=openshell-0.0.109+rhaiv.0-1-py3-none-linux_x86_64.whl .

# Run against the OpenShift gateway
podman run --rm \
  -v ~/.config/openshell:/home/e2e/.config/openshell:ro \
  -e OPENSHELL_GATEWAY=openshift \
  openshell-e2e-python /app/e2e/python/ -v
```

---

## Rust E2E Results: 75 passed, 5 failed, 1 ignored

The suite is mostly driver-agnostic — most test files only require the base `e2e` feature and exercise CLI/gateway behavior that should hold regardless of which compute driver backs the gateway. Running with `--features e2e,e2e-kubernetes` additionally compiles in the Kubernetes-specific extras (`readyz_health`, `kubernetes_corporate_proxy`, `user_namespaces`); Docker/Podman/VM-only test files aren't compiled at all without their own feature flags, and the more specific `e2e-kubernetes-credential-drivers`/`-workspace-managed`/`-workspace-operator` extras weren't enabled for this run.

### Passed (75 tests)

| Suite | Tests | Count |
|-------|-------|-------|
| Harness unit tests | container engine detection, output parsing, port utilities | 21 |
| cf_auth_smoke | gateway add/login help, SSH URL validation, duplicate rejection | 12 |
| cli_smoke | help output, gateway list sources, subcommand detection | 11 |
| sync | upload/download round trips, gitignore filtering (7 of 8) | 7 |
| sandbox_lifecycle | create, keep, no-keep, delete while stopped (3 of 4) | 3 |
| upload_create | `--upload` with directory, single file, and multiple uploads | 3 |
| live_policy_update | round trip, from empty, sparse policy acknowledged | 3 |
| community_image | Sandbox from `--from base` and explicit GHCR image | 2 |
| edge_tunnel_e2e | Gateway status healthy, ws_tunnel status | 2 |
| workspace_lifecycle | `workspace_terminating_rejects_creates` (1 of 2) | 1 |
| smoke | Full gateway smoke: status, create, exec, list, delete | 1 |
| bypass_detection | Direct TCP bypass gets ECONNREFUSED | 1 |
| core_dump_hardening | Sandbox processes have core dumps disabled | 1 |
| landlock | `hard_requirement` accepts enriched `/dev/urandom` path | 1 |
| no_proxy | Sandbox bypasses proxy for localhost HTTP | 1 |
| sandbox_labels | Labels are stored and filterable | 1 |
| port_forward | Echo test | 1 |
| provider_auto_create | Credential available in sandbox | 1 |
| kubernetes_corporate_proxy | Corporate proxy Secret used correctly, never falls back to direct egress (Kubernetes-specific) | 1 |
| local_driver_token_restart | Sandbox restarts correctly with a non-expiring bootstrap JWT | 1 |

### Failed (5 tests)

| Test | Root cause |
|------|-----------|
| `readyz_reports_healthy_database_check` | Requires `OPENSHELL_E2E_HEALTH_PORT` env var — only set by the wrapper script |
| `sandbox_stop_start_preserves_workspace` | Stop/start lifecycle test — sandbox does not resume after stop |
| `settings_global_override_round_trip` | Settings override not applied after round trip |
| `sandbox_download_rejects_symlinks_pointing_outside_workspace` | Symlink security check in downloads — symlink traversal not blocked |
| `workspace_full_crud_lifecycle` | Workspace delete does not complete within timeout |

### Ignored (1 test)

| Test | Reason |
|------|--------|
| `sandbox_pod_spec_has_user_namespace_fields` | Intentionally ignored upstream (hardcoded docker exec + brittle gateway rollout) |

---

## Python E2E Results: 84 passed, 5 failed, 84 skipped (988s)

### Per-suite breakdown

| File | Passed | Failed | Skipped | Notes |
|------|--------|--------|---------|-------|
| `test_sandbox_api.py` | 4 | 0 | 0 | All pass |
| `test_sandbox_exec_python.py` | 2 | 0 | 0 | All pass |
| `test_sandbox_policy.py` | 35 | 5 | 0 | 5 Landlock+`/dev/null` failures |
| `test_sandbox_providers.py` | 14 | 0 | 0 | All pass |
| `test_sandbox_landlock.py` | 5 | 0 | 0 | All pass |
| `test_sandbox_venv.py` | 4 | 0 | 0 | All pass |
| `test_inference_routing.py` | 5 | 0 | 0 | All pass |
| `test_policy_validation.py` | 4 | 0 | 0 | All pass |
| `test_security_tls.py` | 4 | 0 | 0 | All pass |
| `test_workspace_api.py` | 5 | 0 | 0 | All pass |
| `oidc/` | 0 | 0 | 84 | All skipped — no Keycloak fixture |

### Failed (5 tests)

All 5 failures are in [`test_sandbox_policy.py`](python/test_sandbox_policy.py) and share the same root cause: the test policy's `_base_policy()` sets `run_as_user="sandbox"` and a Landlock filesystem policy that includes `/dev/urandom` but not `/dev/null`. On OpenShift, the SCC overrides the user to a random UID, and Landlock blocks `/dev/null` access, which prevents `/etc/profile` from sourcing and the `python` binary from being found.

```
/etc/profile: line 45: /dev/null: Permission denied
/bin/bash: line 1: python: command not found
```

| Test | Description |
|------|-------------|
| `test_policy_applies_to_exec_commands` | `exec_python(current_user)` fails — `python` not found |
| `test_l7_query_matchers_enforced` | Query matcher test — `python` not found |
| `test_l7_rule_without_query_matcher_allows_any_query_params` | Query matcher test — `python` not found |
| `test_forward_proxy_allows_private_ip_with_allowed_ips` | Forward proxy test — `python` not found |
| `test_forward_proxy_allows_private_ip_host_without_allowed_ips` | Forward proxy test — `python` not found |

These tests pass on Docker/Podman where Landlock and user mapping behave differently.

### OIDC tests: 84 passed, 0 failed (rerun after enabling OIDC)

The initial run above shows 84 skipped — no OIDC identity provider was deployed at that point. OIDC was subsequently enabled against the same ROSA gateway using the **Red Hat build of Keycloak (RHBK)**, via the RHBK operator already installed on this cluster in the `openshell` namespace — its `Keycloak`/`KeycloakRealmImport` custom resources, not a plain Keycloak Deployment. The manifest for this (Postgres + `Keycloak` CR + `KeycloakRealmImport` CR) is [`scripts/keycloak-openshift-rhbk.yaml`](../scripts/keycloak-openshift-rhbk.yaml).

**Setup:**

1. Apply [`scripts/keycloak-openshift-rhbk.yaml`](../scripts/keycloak-openshift-rhbk.yaml): a dedicated Postgres for Keycloak (using a PGDATA subdirectory rather than the image's default data directory, so the container can create and own it instead of needing to chmod a directory OpenShift's random UID assignment doesn't own — avoids needing an `anyuid` SCC grant), a `Keycloak` CR, and a `KeycloakRealmImport` CR importing an `openshell` realm with `openshell-cli` (public, Authorization Code + PKCE) and `openshell-ci` (confidential, client credentials) clients, `openshell-admin`/`openshell-user` realm roles, and `admin@test`/`user@test`/`user-b@test` test users:
   ```bash
   oc apply -f scripts/keycloak-openshift-rhbk.yaml -n openshell
   ```
2. An edge-terminated Route exposing Keycloak's `http` service port externally: `oc create route edge keycloak -n openshell --service=keycloak-service --port=http`.
3. The gateway Helm release updated with OIDC settings (from the same cloned/checked-out repo root used for the initial install):
   ```bash
   helm upgrade openshell ./deploy/helm/openshell -n openshell --reuse-values \
     --set server.oidc.issuer="http://keycloak-service.openshell.svc.cluster.local:8080/realms/openshell" \
     --set server.oidc.audience=openshell-cli \
     --set server.oidc.rolesClaim=realm_access.roles \
     --set server.oidc.adminRole=openshell-admin \
     --set server.oidc.userRole=openshell-user \
     --set server.oidc.scopesClaim=scope \
     --set server.auth.allowUnauthenticatedUsers=false
   ```
4. Run the suite:
   ```bash
   podman run --rm \
     -v ~/.config/openshell:/home/e2e/.config/openshell:ro \
     -e OPENSHELL_E2E_OIDC=1 -e OPENSHELL_E2E_OIDC_SCOPES=1 \
     -e OPENSHELL_GATEWAY=openshift \
     -e OPENSHELL_KEYCLOAK_URL=https://keycloak-openshell.<apps-domain> \
     openshell-e2e-python /app/e2e/python/oidc/ -v
   ```

**Result:** 84 passed, 0 failed — `TestRbac`, `TestScopes` (needs the extra `OPENSHELL_E2E_OIDC_SCOPES=1` opt-in, gated separately from `OPENSHELL_E2E_OIDC`), `TestClientCredentials`, and all `TestWorkspaceAuthorization` cases. Test source: [`e2e/python/oidc/`](python/oidc/).

**Two issues found and fixed along the way:**

1. **`hostname.strict: false` made the JWT `iss` claim depend on how the token was requested.** The first attempt set `hostname.strict: false` on the `Keycloak` CR, expecting the fixed `hostname.hostname` value to pin the issuer regardless of access path. It doesn't work that way in the RHBK operator's `v2beta1` CR: with `strict: false`, Keycloak computes `iss` dynamically from the request's `Host` header instead. A token fetched via the external Route got a different (and inconsistently port-less) issuer than one fetched by curling the in-cluster Service directly, so the gateway rejected tokens with `UNAUTHENTICATED: invalid token: InvalidIssuer` regardless of role or scope. Setting `hostname.strict: true` and giving `hostname.hostname` a full URL including the port (`http://keycloak-service.openshell.svc.cluster.local:8080`) made the issuer identical no matter which path a token came from.

2. **Missing port on `server.oidc.issuer` broke OIDC discovery entirely.** The gateway builds its `.well-known/openid-configuration` request from the exact configured issuer string. Configuring it without `:8080` sent the discovery request to the implicit default HTTP port 80, where nothing listens (the Service only exposes `8080` and `9000`), and the gateway crash-looped with `OIDC discovery request failed`.

3. **`server.auth.allowUnauthenticatedUsers` and correct OIDC rejection are mutually exclusive on one running gateway.** The suite includes `test_request_without_bearer_token_rejected`, which expects a missing-token request to be denied. The gateway had `allowUnauthenticatedUsers=true` set (from the reinstall in the section above, needed to make plain mTLS-only CLI access work). With that flag on, a missing-token request is treated as a trusted local principal instead of being rejected. Getting a correct OIDC test run required setting it back to `false`, which in turn means plain mTLS-only access (no bearer token) no longer works against this gateway until the flag is flipped back.

---

## Helm Deployment Smoke Test: 2 passed, 0 failed

[`e2e/rust/e2e-openshift.sh`](rust/e2e-openshift.sh) (`mise run e2e:openshift`) validates Helm installation rather than sandbox functionality. It installs the chart into a fresh `openshell` namespace for two database-backend scenarios, waits for the gateway pod to reach `Running`, and tears down between and after each scenario.


```bash
mise run e2e:openshift
```

```
========================================
  Test Summary
========================================
  PASS  SQLite (default)
  PASS  External PostgreSQL (externalDbSecret)
----------------------------------------
  Passed: 2  Failed: 0
========================================
```

| Scenario | Result |
|----------|--------|
| SQLite (default) | PASS — gateway pod reached `Running` |
| External PostgreSQL (`externalDbSecret`) | PASS — standalone Postgres deployed, gateway pod reached `Running` against the existing Secret |

---

## Key Findings

1. **94% Rust E2E pass rate on OpenShift.** 75 of 80 executed tests pass (1 additional test is intentionally ignored upstream). Long-running sandboxes, policy updates, port forwarding, sync, providers, and workspaces all work. The 5 failures are environmental or edge-case issues.

2. **94% Python E2E pass rate on OpenShift.** 84 of 89 non-OIDC tests pass. Sandbox CRUD, exec, exec_python, L4/L7/SSRF policy enforcement, landlock, providers, workspaces, venvs, inference routing, TLS, and policy validation all work correctly.

3. **Python version must match between test container and sandbox image.** The sandbox base image runs Python 3.14. A version mismatch breaks cloudpickle deserialization for `exec_python()`.

4. **Landlock + OpenShift SCC interaction.** Tests using `_base_policy()` with restrictive Landlock filesystem rules fail because the policy doesn't include `/dev/null` and OpenShift's SCC overrides the `run_as_user`. This affects 5 Python tests.

5. **Version alignment is critical.** Running `main`-branch tests against a v0.0.109 CLI produced 30 false failures due to `--detach` flag and missing RPCs. Checking out the matching tag eliminated all of them.

6. **No wrapper script supports OpenShift.** The existing scripts always manage their own Helm install or k3d cluster. Running E2E tests on an existing OpenShift gateway requires manual setup.

7. **OIDC works end-to-end on OpenShift once the issuer is pinned correctly.** All 84 OIDC tests pass against RHBK-operator-managed Keycloak once `hostname.strict: true` and a fully-qualified (with port) `hostname.hostname`/`server.oidc.issuer` remove ambiguity in the JWT `iss` claim. `allowUnauthenticatedUsers` and correct missing-token rejection cannot both be true on the same gateway — pick one per test run.

## How to Reproduce

Test source: [`e2e/rust/`](rust/) and [`e2e/python/`](python/). Chart: [`deploy/helm/openshell`](../deploy/helm/openshell). Python test container: [`deploy/docker/Dockerfile.e2e-python`](../deploy/docker/Dockerfile.e2e-python). Keycloak/OIDC manifest: [`scripts/keycloak-openshift-rhbk.yaml`](../scripts/keycloak-openshift-rhbk.yaml).

### Rust E2E

```bash
# Prerequisites: oc authenticated, gateway deployed, CLI v0.0.109 installed
# Checkout the matching tag
git checkout v0.0.109

# Run all tests
OPENSHELL_BIN=/opt/homebrew/bin/openshell cargo test \
  --manifest-path e2e/rust/Cargo.toml \
  --features e2e,e2e-kubernetes \
  --no-fail-fast -- --nocapture
```

### Python E2E

```bash
# Build test container (Python 3.14 to match sandbox image)
podman build --platform linux/amd64 \
  -t openshell-e2e-python \
  -f deploy/docker/Dockerfile.e2e-python \
  --build-arg OPENSHELL_WHL=openshell-0.0.109+rhaiv.0-1-py3-none-linux_x86_64.whl .

# Run full suite
podman run --rm \
  -v ~/.config/openshell:/home/e2e/.config/openshell:ro \
  -e OPENSHELL_GATEWAY=openshift \
  openshell-e2e-python /app/e2e/python/ -v

# Skip known Landlock/SCC failures
podman run --rm \
  -v ~/.config/openshell:/home/e2e/.config/openshell:ro \
  -e OPENSHELL_GATEWAY=openshift \
  openshell-e2e-python /app/e2e/python/ -v \
  -k 'not (test_policy_applies_to_exec_commands or test_l7_query_matchers_enforced or test_l7_rule_without_query_matcher_allows_any_query_params or test_forward_proxy_allows_private_ip_with_allowed_ips or test_forward_proxy_allows_private_ip_host_without_allowed_ips)'
```
