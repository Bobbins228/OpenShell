// SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

//! Helpers for invoking the `oc` CLI from ODH e2e tests.
//!
//! ODH tests shell out to `oc` for cluster-state checks the client doesn't cover
//! (image provenance today; node-level `SELinux` audits next). Centralizing the
//! command construction here keeps every test targeting the same cluster and
//! reporting failures the same way.

use serde_json::Value;

/// Builds an `oc` command targeting the active e2e cluster.
///
/// When `OPENSHELL_E2E_KUBE_CONTEXT_ACTIVE` is set (exported by
/// `e2e/with-kube-gateway.sh`), the context is passed explicitly with
/// `--context`, matching the convention the upstream e2e tests already use for
/// `kubectl`. When it is unset, `oc` falls back to the current kubeconfig
/// context. Callers append the subcommand and its arguments with `.args(...)`.
pub fn oc_command() -> tokio::process::Command {
    let mut cmd = tokio::process::Command::new("oc");
    if let Ok(context) = std::env::var("OPENSHELL_E2E_KUBE_CONTEXT_ACTIVE")
        && !context.is_empty()
    {
        cmd.args(["--context", &context]);
    }
    cmd
}

/// Runs `oc <args>` and parses stdout as JSON.
///
/// Panics with a descriptive message if `oc` cannot be launched, exits
/// non-zero, or does not return valid JSON — use it for `-o json` queries
/// whose failure should fail the test.
pub async fn oc_json(args: &[&str]) -> Value {
    let output = oc_command().args(args).output().await.expect(
        "failed to run `oc` — required for ODH cluster-state checks; ensure it is in PATH \
         and KUBECONFIG targets the cluster",
    );
    assert!(
        output.status.success(),
        "oc {args:?} failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout)
        .unwrap_or_else(|e| panic!("oc {args:?} did not return valid JSON: {e}"))
}
