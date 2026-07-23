# BDP VM Offer — What Has Been Done

_Azure Marketplace **Virtual Machine** offer. BDP runs self-contained on a single VM (PM2 + embedded k3s). Last updated: 2026-07-23._

---

## Stage 0 — Concept
The VM offer packages the **entire** Bluechip Data Platform onto one Azure VM image:
- All ~22 Spring Boot microservices run under **PM2**.
- An **embedded k3s** provides the Kubernetes API that BDP uses to install data tools (NiFi, Airflow, Spark, Superset, Trino, MinIO, …) locally on the same VM.
- **Keycloak** provides SSO; **Caddy** terminates TLS.
- Repo: `bdp-marketplace-vm/`.

This offer suits smaller workloads / trials. Heavy production workloads are the Kubernetes offer's job.

---

## Stage 1 — Image build pipeline (DONE)
- **Packer** templates under `bdp-marketplace-vm/` build the Azure VM image.
- `provision/10-runtime.sh` installs the runtime: **Caddy**, **k3s** launched with `--disable traefik --disable servicelb` (so k3s doesn't grab ports 80/443 that Caddy needs), Node/PM2, JDK 21.
- `firstboot/bdp-first-boot.sh` runs on first boot and:
  - Detects the VM's public IP via **Azure IMDS**.
  - Configures **Caddy TLS**, gated on a customer-supplied domain (custom data).
  - Fixes kubeconfig permissions for the k3s API.
  - Injects **NextAuth** env (NEXTAUTH_URL, KEYCLOAK_ISSUER, secret) for the UI.
- `config/pm2-marketplace.config.js` — PM2 process definitions for all services.
- `offer/azure-vm/*` — Partner Center technical-config artifacts.

## Stage 2 — Image versions (DONE)
- **1.0.1** built first — TLS was not fully working.
- **1.0.2** rebuilt with the TLS fix (k3s `--disable traefik servicelb`, Caddy on 80/443). **This is the current good image.**
- Published to an **Azure Shared Image Gallery (SIG)**.

## Stage 3 — Validation (DONE)
- A **smoke VM** was launched from the 1.0.2 image and validated end-to-end:
  - HTTPS reachable, TLS certificate valid.
  - Login via Keycloak works.
  - Data tools install onto the embedded k3s.
- ⚠️ The smoke VM **bills hourly** — deallocate/delete it when not testing.

## Stage 4 — SSO integration fixes (DONE)
Keycloak OIDC "Insufficient Permissions" errors were resolved for the tools:
- **NiFi** — `auth.oidc.admin=admin` (identity mismatch).
- **Airflow** — `webserverConfig` must be nested under `webserver.*` (top-level is ignored by the chart).
- **MinIO** — corrected the S3 API NodePort (30094, not the console port).
These fixes live in `bdp-service-manager` and apply on every subsequent deploy.

## Stage 5 — Security / vulnerabilities (DONE)
- **npm**: 0 vulnerabilities (overrides for sharp, dompurify, monaco-editor, form-data, postcss).
- **Java**: Spring Boot 3.3.13, Spring Cloud 2023.0.6, BouncyCastle 1.81, fabric8 6.13.5 — all 39/39 modules build.
- JWT-tamper test bug fixed; TLS validated.

---

## Current status
| Item | State |
|------|-------|
| VM image 1.0.2 | ✅ Built + published to SIG |
| Smoke test | ✅ Passed (TLS, login, tool install) |
| SSO fixes | ✅ Done |
| Vulnerabilities | ✅ Resolved |
| Partner Center listing | ⏳ Remaining — see `05-MARKETPLACE-REMAINING-vm-offer.md` |

## What is NOT done (VM offer)
- The **Partner Center VM offer listing** (plan, pricing, preview, certification, publish).
- Marketing/legal content, support contact, privacy policy URLs.

➡️ Next: test it yourself with `03-TESTING-vm-offer.md`, then finish the listing with `05-MARKETPLACE-REMAINING-vm-offer.md`.
