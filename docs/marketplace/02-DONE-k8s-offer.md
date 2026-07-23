# BDP Kubernetes Offer — What Has Been Done

_Azure Marketplace **Kubernetes / Container** offer. BDP runs as microservices on a managed cluster (AKS) via a Helm umbrella chart, with an air-gapped registry. Last updated: 2026-07-23._

---

## Stage 0 — Concept
The Kubernetes offer runs BDP on **managed Kubernetes (AKS/EKS)** instead of a single VM, because production workloads exceed what one VM can handle.
- **Control plane + data tools** run as pods on the cluster.
- Deployed via a **Helm umbrella chart**: repo `bdp-marketplace-k8s/` (`charts/bdp`).
- **Air-gapped**: all charts + images are mirrored into a customer **Azure Container Registry (ACR)**; nothing is pulled from public registries at install time.
- Binary-only: **no source code ships** — only built container images + the chart.

---

## Stage 1 — Umbrella chart (DONE)
`bdp-marketplace-k8s/charts/bdp`:
- One `Deployment` + `Service` per platform microservice (generated from `values.yaml → services`).
- Subcharts: **postgresql, redis, keycloak** (Bitnami, pinned to `bitnamilegacy/*` images since Bitnami retired the public `bitnami/*` repos).
- `templates/`: `services.yaml`, `ui.yaml`, `ingress.yaml`, `seed-job.yaml`, `secrets.yaml`, `billing-cronjob.yaml`, `_helpers.tpl`.
- Container images built from `bdp-marketplace-k8s/images/Dockerfile.*` via `build-all.sh` (**runs on the remote build host**, not locally).

## Stage 2 — Air-gap registry (DONE)
- **15 tool charts** pushed to ACR as OCI artifacts under `charts/*` (`push-charts-oci.sh`).
- Tool **images mirrored** to `tools/bitnamilegacy/*` and `tools/*` via server-side `az acr import` (`mirror-tool-images.sh`).
- AKS **attached to the ACR** (managed identity `AcrPull`) — no imagePullSecret needed.
- BDP redirects installs to the ACR when `BDP_AIRGAP_REGISTRY` is set.

## Stage 3 — Live AKS validation (DONE)
Deployed the chart to a live AKS cluster (`bdp-airgap` in RG `bdp-airgap-test`) at `https://145-133-118-96.sslip.io` and drove it end-to-end. This surfaced a **chain of real bugs**, all now fixed in code **and baked into the chart**:

| # | Bug | Fix | Commit |
|---|-----|-----|--------|
| 1 | Gateway routed to `127.0.0.1:70xx` (VM layout) → dashboard APIs 500 | Parameterized route URIs `${BDP_SVC_<port>}`; chart sets cluster DNS | gateway `e027fbf` / chart `29eb219` |
| 2 | Installs aborted `ResourceAccessException` (provisioner → `127.0.0.1:7018`) | Chart sets `BDP_CLUSTER_REGISTRY_URL`; fixed `@Value` port defaults | `fec2e2e` |
| 3 | Tool pods `ImagePullBackOff` (`docker.io/bitnami/*` gone) | Air-gap image redirect + `BITNAMI_SERVICES` detection fallback | `fec2e2e` |
| 4 | Dashboard `/health` + `/ui` **500** (service-manager default SA, no RBAC) | Dedicated ServiceAccount + scoped ClusterRole | chart `29eb219` |
| 5 | Install-progress **WebSocket** failed (hardcoded `:7003`, gateway didn't route/authorize `/ws`) | Same-origin WS + gateway `/ws` routes + public path | ui `93cbfc0` / gateway `c357c2b` |
| 6 | Logout `Invalid parameter: id_token_hint` (wrong Keycloak) | Derive end-session URL from token `iss` claim | ui `20096f3` |
| 7 | Tool UI URL `http://host:8080` unreachable on cloud K8s | `bdp.ui-access.mode=ingress` → `https://<tool>.<domain>/` | svc-mgr `7c83a08` / chart `670baec` |

**Login chain** (fixed earlier in the same effort): NextAuth env, redirect URIs, self-signed cert handling, `/api/auth` ingress path, Keycloak NAT-hairpin `hostAlias`, `proxy-buffer-size` for OIDC callback — all baked into the chart.

## Stage 4 — What is verified live vs. baked-only
- **Verified live on the running cluster:** login, dashboard (500s fixed via RBAC), gateway routing, air-gap Spark install (`RUNNING` from ACR).
- **Baked into chart but needs a fresh image build to see live:** WebSocket, logout, tool-UI ingress URL (these are code changes in the UI + service-manager images; the running cluster still has the old images).

## Stage 5 — Security review (DONE)
- Automated commit/push review flagged: TLS-verify-disabled, `/ws` broken-authorization, token-in-logs.
- **TLS**: made secure-by-default — `NODE_TLS_REJECT_UNAUTHORIZED=0` is now an explicit `global.insecureSkipTlsVerify` opt-in (`9dc4012`).
- **`/ws` auth**: verified by-design — every WS handler validates the JWT via `JwtHandshakeInterceptor` (token is a query param because browsers can't set WS headers).
- **Token-in-logs**: gateway does not log request URIs; mitigated by 5-min token lifetime.

---

## Current status
| Item | State |
|------|-------|
| Umbrella Helm chart | ✅ Complete, `helm template` validates (default + air-gap) |
| ACR air-gap (charts + images) | ✅ Done |
| Live AKS deploy | ✅ Working (login, dashboard, install) |
| All 7 deploy bug fixes | ✅ Committed + baked into chart |
| CNAB bundle (`cpa`) for Azure Container offer | ⏳ Blocked on 3 Bitnami subcharts — see `06-MARKETPLACE-REMAINING-k8s-offer.md` |
| Partner Center listing | ⏳ Remaining |

## What is NOT done (K8s offer)
- **Image rebuild + redeploy** of UI + service-manager on the live cluster (to see fixes #5–#7 live) — **do this on the remote build host**.
- **CNAB bundle** conformance (3 Bitnami subcharts) + `cpa buildbundle`.
- **Partner Center** Azure Container / Kubernetes-app listing.
- Real **wildcard TLS** (cert-manager) to replace nginx's self-signed default.

➡️ Next: test it yourself with `04-TESTING-k8s-offer.md`, then finish with `06-MARKETPLACE-REMAINING-k8s-offer.md`.
