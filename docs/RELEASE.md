# Releasing BDP images + chart (ACR + GHCR + air-gap bundle)

One script publishes a release everywhere. It wraps the documented Azure
Marketplace procedure (unchanged) and adds the portable channels.

## Prerequisites on the build host

- staged `dist/` tree: `../bdp-marketplace-vm/build/collect-artifacts.sh`
- `docker`, `helm` (>=3.14), `az` (logged in), `crane`
  (`go install github.com/google/go-containerregistry/cmd/crane@latest` or the
  release tarball)
- GHCR credentials: `export GHCR_USER=<github-user> GHCR_TOKEN=<PAT with write:packages>`

## Release

```bash
scripts/release.sh --pin 1.0.7
git diff charts/bdp/values.yaml     # review the digest pins, then commit
```

What it does, in order:

1. `images/build-all.sh $ACR/bdp <version>` — the exact documented build+push.
2. Records every pushed digest to `releases/<version>/digests.txt`.
3. `--pin`: rewrites the digests in `charts/bdp/values.yaml` and bumps
   `global.bdpImageTag` (replaces the old manual "pin in the chart" step).
4. `crane cp` of all platform images, the re-hosted bitnami trio and the
   `tools/*` images (from `images/tools-manifest.txt`) to GHCR.
   **Digest-preserving by construction** — the script asserts the digest of
   every copy; one set of pins is valid in every registry.
5. Mirrors the tool charts (`charts/charts-manifest.txt`) and pushes the
   packaged umbrella chart to `oci://<registry>/charts` on both sides.
6. Regenerates `charts/bdp/values-ghcr.yaml` and runs
   `scripts/verify-render.sh` — zero `azurecr.io` references, image set is a
   pure registry-prefix swap.
7. `scripts/make-airgap-bundle.sh` — emits `releases/bdp-airgap-<version>.tar.gz`.

Flags: `--skip-build` (images already in ACR), `--skip-ghcr`, `--skip-bundle`,
`--refresh-manifests` (report ACR `tools/*` + `charts/*` contents to update the
two manifest files).

## GHCR package visibility

The first push creates **private** packages. Either make `bdp-*`, `tools/*`
and `charts/*` public in the GitHub org package settings, or point installs at
the pull-secret mechanism (docs/INSTALL-GENERIC.md).

## Manifest files

- `images/tools-manifest.txt` — the third-party images mirrored under
  `tools/*` (the in-repo record of what `az acr import` once did by hand).
  `scripts/mirror-tools.sh --from-upstream <target>` can rebuild a mirror from
  the public upstreams; the default mode copies from ACR preserving digests.
- `charts/charts-manifest.txt` — tool charts published under `charts/*`.

Keep both in step with the ACR via `--refresh-manifests` and commit changes.

## Issuing licenses (BYOL)

Signed license files are issued with the tools in
`bdp-platform/scripts/license/` (they run wherever the vendor private key
lives — currently the build host, `~/.bdp-license-signing/`; never commit or
copy that key):

```bash
scripts/license/sign-license.sh --org "Acme Corp" --tier ENTERPRISE \
  --email ops@acme.com --out acme-license.key
```

Licenses expire **annually by default** (`--days 365`); use
`--expires YYYY-MM-DD` for an explicit end date (end of that day UTC) or
`--days` for other terms. Every issued license is appended to
`issued-licenses.txt` next to the private key — the vendor ledger of who
holds what until when. Renewal = sign a fresh file, customer replaces the
`bdp-license` secret and restarts the bdp-license-manager pod. The
platform UI's License page shows the effective license with a
server-computed ACTIVE / EXPIRED / DEACTIVATED status.

Send the customer the file; they install it as the `bdp-license` secret (see
docs/INSTALL-GENERIC.md). The matching PUBLIC key is committed at
`bdp-platform/bdp-license-manager/src/main/resources/license-signing/` and
baked into the image — rotating the keypair invalidates every issued license,
so treat `gen-signing-keypair.sh` as a once-ever operation.

## Verifying a release end-to-end

- Chart render: `scripts/verify-render.sh ghcr.io/bluechiptech charts/bdp/values-ghcr.yaml`
- kind smoke test (build host): create a kind cluster + ingress-nginx, then
  install with `-f charts/bdp/values-ghcr.yaml` and the overrides from
  docs/INSTALL-GENERIC.md; reuse the checks in `scripts/deploy-aks-test.sh verify`
  with the image-registry assertion pointed at ghcr.io.
- Bundle round-trip: `docker run -d -p 5000:5000 registry:2`, then
  `./import-bundle.sh localhost:5000` from the unpacked bundle and install
  from `localhost:5000` with the generated `values-airgap.yaml`.

The Azure path is untouched: the default `helm template` render of
`charts/bdp` is byte-identical with all new mechanisms unset, so `cpa verify`
and the marketplace listing behave exactly as before.
