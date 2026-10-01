# ODH E2E Image Build

The downstream ODH Konflux e2e image is a separate test artifact. Its
multi-stage UBI9 build compiles the CLI and a nextest archive from two
independent Cargo lockfiles, with Rust, RPMs, and cluster tools prefetched by
Hermeto for a network-isolated build. The runtime image carries the compiled
archive, Cargo and nextest executables, cluster tools, the SSH client needed
by sandbox lifecycle tests, and Git for repository workloads.

At runtime, the image entrypoint uses the Quay deployment script to create a
gateway on the target OpenShift cluster, runs one selected test tier, writes
JUnit and HTML reports to a mounted results directory, and tears down the
deployment. Cleanup is armed before deployment and tracks namespace creation
separately from local gateway registration, so rollout failures remove the
owned namespace and validation failures preserve local registration. Signals
are forwarded through the tier runner to nextest before teardown. Extracted
client mTLS material is stored in a mode `0700` directory with mode `0600`
files. The Rust tests consume the deployed gateway.

Konflux onboarding must use the `linux-m2xlarge/*` builders and retain both
Cargo prefetch inputs (`.` and `e2e/rust`). The image name is
`odh-openshell-e2e`; Konflux automation generates the Tekton YAML files.
Before merging, validate the local hermetic build on both `linux/amd64` and
`linux/arm64` using `PLATFORM` with `deploy/konflux/build-local.sh e2e-odh`.
