# Installing BDP outside Azure (on-prem, other clouds, air-gapped)

The chart is cloud-neutral; only the Azure Marketplace wrapper and the AKS
defaults are Azure-specific. Every release publishes the same digest-pinned
images to two registries, plus an offline bundle:

| Channel | Where | Use for |
|---|---|---|
| ACR `bdpmarketplace.azurecr.io` | Azure Marketplace installs | AKS (pulls via AcrPull managed identity) |
| GHCR `ghcr.io/bluechiptech` | any cluster with internet | on-prem k8s, EKS, GKE, plain Docker hosts |
| `releases/bdp-airgap-<version>.tar.gz` | no internet at all | air-gapped sites (see the bundle's IMPORT.md) |

All three carry byte-identical images (`crane cp` preserves manifest digests),
so the sha256 pins in the chart are valid everywhere.

## Prerequisites (any non-AKS cluster)

- Kubernetes with a **default StorageClass** (PVCs for postgres/redis/keycloak,
  prometheus, alertmanager, loki).
- An **RWX-capable StorageClass** if tools should share a data volume
  (`sharedStorage`) — NFS, CephFS, Longhorn... On AKS this defaulted to
  `azurefile-csi`, which does not exist elsewhere: set
  `sharedStorage.storageClass` to a real RWX class, or
  `sharedStorage.enabled=false`. Never set it to `""` — an empty string
  disables dynamic provisioning entirely.
- **ingress-nginx** (or another controller; set `global.ingressClassName`).
  Do NOT copy the `azure-load-balancer-health-probe-request-path` annotation
  from the AKS script — it is AKS-only. On bare metal add MetalLB (or
  equivalent) so the ingress Service gets a LoadBalancer IP.
- A DNS name for `global.externalDomain` (wildcard `*.sslip.io` works for
  testing) pointing at the ingress.

## Install from GHCR

```bash
helm install bdp charts/bdp -n bdp --create-namespace \
  -f charts/bdp/values-ghcr.yaml \
  --set global.externalDomain=bdp.customer.example.com \
  --set sharedStorage.storageClass=<rwx-class> \
  --timeout 20m --wait
```

`values-ghcr.yaml` is generated from the canonical `values.yaml` by
`scripts/gen-registry-values.sh` — same digests, registry swapped, and
`global.airgapRegistry` set so tools provisioned at runtime (their Helm charts
under `charts/*`, their images under `tools/*`) also resolve from GHCR.

For any other registry (a corporate Harbor, a cloud mirror):
`scripts/gen-registry-values.sh my.registry.example/bdp my-values.yaml` after
mirroring the content there (`scripts/mirror-tools.sh my.registry.example/bdp`
plus `crane cp` of the `bdp/*` images — or just import the air-gap bundle).

## Pull secrets (private registries)

AKS pulled via managed identity, so the chart creates no pull secret by
default. Everywhere else, if the registry is private:

```yaml
global:
  registryCredentials:
    create: true            # renders a dockerconfigjson Secret in the release
    name: bdp-registry-cred # namespace AND toolsNamespace
    registry: ghcr.io
    username: <user>
    password: <token>       # GHCR: read:packages
  imagePullSecrets:         # creating ≠ attaching — list it here too
    - name: bdp-registry-cred
loki:
  imagePullSecrets:         # loki reads its chart-local key
    - name: bdp-registry-cred
alloy:
  global:
    image:
      pullSecrets:          # alloy reads global.image.pullSecrets
        - name: bdp-registry-cred
```

`global.imagePullSecrets` covers the BDP workloads and the
postgresql/redis/keycloak, cert-manager and kube-prometheus-stack subcharts
natively; loki and alloy need the two extra keys shown. Alternatively make the
GHCR packages public and skip all of this.

## Keycloak hairpin

If pods cannot reach `keycloak.<externalDomain>` through the load balancer
(managed LBs often don't hairpin; common on-prem too), set
`global.keycloakHostAliasIp` to the ingress controller's ClusterIP.

## TLS

`global.tls.mode=existing` (default) with your own certificate in
`global.tlsSecretName`, or `acme` for Let's Encrypt via the bundled
cert-manager (needs the domain publicly resolvable). For throwaway tests only:
`global.insecureSkipTlsVerify=true`.

## Air-gapped

Use the release bundle: `releases/bdp-airgap-<version>.tar.gz` contains every
image as an OCI layout, all charts, an import script and its own IMPORT.md.
Built by `scripts/make-airgap-bundle.sh`, imported with one command against
any local registry.

## Licensing (BYOL)

Off-marketplace installs run under a vendor-signed license (Ed25519). You
receive a `license.key` file from Bluechip; install it before (or after) the
helm install:

```bash
kubectl create secret generic bdp-license -n bdp --from-file=license.key=license.key
helm install bdp ... --set billing.mode=byol
```

With `billing.mode=byol` the chart mounts the secret into bdp-license-manager
and enables signed enforcement: the file is verified against the public key
baked into the image at startup, and only that license validates — tampering
with tier or expiry invalidates the signature, and licenses cannot be created
through the API. Tool provisioning is tier-gated (STARTER/PROFESSIONAL/
ENTERPRISE) with cluster/node limits and expiry warnings 30 days out. To
renew or upgrade, replace the secret with the new file and restart the
bdp-license-manager pod. Fully offline — nothing phones home, air-gap safe.

## Plain Docker host (no Kubernetes)

The images are ordinary OCI images — `docker run ghcr.io/bluechiptech/bdp/<service>:<version>`
works for individual services (Spring Boot on the service's port, UI on 3000),
with `docker login ghcr.io` first if the packages are private. There is no
compose file: the supported no-K8s deployment is the VM offer
(`bdp-marketplace-vm`), which runs the same JARs under PM2.
