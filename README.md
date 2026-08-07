# bdp-marketplace-k8s

Marketplace Kubernetes-App packaging for BDP (Azure container offer / AWS EKS
container listing / GKE — cloud-neutral chart, per-cloud offer folders).

Customers receive **container images + a Helm chart** — never source code.
Images are built from prebuilt JARs (`bdp-marketplace-vm/dist/` from
`collect-artifacts.sh`, shared between both packaging projects).

## Layout

```
images/            Dockerfiles consuming dist/ JARs + build-all.sh
charts/bdp/        umbrella chart: 22 services + UI, bundled postgresql/redis/keycloak,
                   generated per-service Deployment+Service from ONE template,
                   post-install seed Job (realm, clients, RBAC), optional metering CronJob
seed/              entrypoint for the seed image (containerized setup-server.js)
offer/azure/       Azure container-offer (CNAB / cluster extension) packaging
offer/aws/         AWS Marketplace EKS listing metadata
```

## Build

```
export BDP_PLATFORM_DIR=... BDP_UI_DIR=...
../bdp-marketplace-vm/build/collect-artifacts.sh          # stage dist/
images/build-all.sh registry.example.com/bdp 1.0.0        # build+push all images
helm package charts/bdp                                   # chart artifact
```

## Install (what the marketplace runs for the customer)

```
helm install bdp charts/bdp \
  --set global.externalDomain=bdp.customer.example.com \
  --set global.bdpImageRegistry=<marketplace registry> \
  --set billing.mode=byol|flat|metered
```

The post-install seed Job creates the Keycloak realm, all OIDC clients, RBAC
resources, and randomized admin credentials (written to secret `bdp-credentials`).

## Registries & portability

Every release ships to the marketplace ACR **and** GHCR
(`ghcr.io/bluechiptech`), plus an offline bundle for air-gapped sites — same
digest-pinned images everywhere (`scripts/release.sh`, see `docs/RELEASE.md`).
To install on on-prem / non-Azure clusters use
`-f charts/bdp/values-ghcr.yaml` (or generate one for any mirror with
`scripts/gen-registry-values.sh`) and see `docs/INSTALL-GENERIC.md` for pull
secrets, storage-class and ingress notes.

## Billing

`billing.mode` value selects per-plan behaviour: `byol` (license key secret →
bdp-license-manager), `flat` (nothing), `metered` (CronJob pushes bdp-metering
usage to the cloud's marketplace metering API).

## Known gaps (tracked, not hidden)

- Inter-service URL env overrides in `values.yaml` cover the pairs known from
  `application.yml` defaults; each service needs a verification pass.
- The NiFi chart must be the FORKED cetic chart (gzip fix + `CN=localhost`
  proxy identity + admin identity) vendored into `charts/` before GA.
- Data-tool provisioning inside the customer cluster reuses bdp-provisioner
  with in-cluster RBAC (ServiceAccount) instead of a kubeconfig file.
