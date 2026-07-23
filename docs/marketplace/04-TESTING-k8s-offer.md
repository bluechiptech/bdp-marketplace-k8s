# Manual Testing Guide — BDP Kubernetes Offer

_How to deploy and validate the Helm chart on AKS yourself, step by step. Last updated: 2026-07-23._

> **All image builds and cluster operations run on the remote build host / Azure — not your local machine.**

---

## Prerequisites
- Azure subscription + `az login` (on the remote host).
- **ACR** `bdpmarketplace` (RG `bdp-marketplace-images`) — already holds the mirrored charts (`charts/*`) and tool images (`tools/*`).
- `kubectl` + `helm` on the remote host.
- The BDP images in ACR under `bdpmarketplace.azurecr.io/bdp/*` (registry prefix).

---

## Stage 1 — (If code changed) rebuild images ON THE REMOTE HOST
The chart pulls prebuilt images; UI + service-manager fixes only take effect after a rebuild. Do this on the remote build host that has Docker + the source (or the staged `dist/`):

```bash
# 1. Build jars + UI, stage into bdp-marketplace-k8s/dist/
#    dist/lib/<service>.jar   (mvn -pl <svc> -am package -DskipTests)
#    dist/ui/                 (next build standalone output: .next/standalone + .next/static + public)
#    For the UI, set NEXT_PUBLIC_KEYCLOAK_BASE_URL / _KEYCLOAK_URL to the target
#    domain at build time (they are inlined by `next build`).

# 2. Log in to ACR
az acr login -n bdpmarketplace

# 3. Build + push (bump the tag so nodes re-pull, e.g. 1.0.1)
cd bdp-marketplace-k8s
images/build-all.sh bdpmarketplace.azurecr.io/bdp 1.0.1
#   or just the two that changed:
docker build -f images/Dockerfile.service --build-arg SERVICE=bdp-service-manager \
  -t bdpmarketplace.azurecr.io/bdp/bdp-service-manager:1.0.1 . && docker push ...:1.0.1
docker build -f images/Dockerfile.ui \
  -t bdpmarketplace.azurecr.io/bdp/bdp-ui:1.0.1 . && docker push ...:1.0.1
```
Then set `global.bdpImageTag: "1.0.1"` in your install values (Stage 4).

---

## Stage 2 — Create the AKS cluster + attach ACR
```bash
az group create -n bdp-airgap-test -l eastus
az aks create -g bdp-airgap-test -n bdp-airgap \
  --node-count 3 --node-vm-size Standard_D4s_v5 \
  --attach-acr bdpmarketplace --generate-ssh-keys
az aks get-credentials -g bdp-airgap-test -n bdp-airgap --file /tmp/aks.kubeconfig
export KUBECONFIG=/tmp/aks.kubeconfig
az aks check-acr -g bdp-airgap-test -n bdp-airgap --acr bdpmarketplace.azurecr.io  # expect SUCCEEDED
```
> **3 × D4s_v5** minimum — BDP control plane + Keycloak + Postgres + a few tools. Fewer nodes → pods stay `Pending` (this happened live when Spark's 3 workers starved the gateway pod).

---

## Stage 3 — Install ingress-nginx
```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm install ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx --create-namespace \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-request-path"=/healthz
```
> The health-probe annotation is required, or the Azure LB probes `/` (404) and never marks the backend healthy.

Get the LB IP and derive the sslip.io domain:
```bash
kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
# e.g. 145.133.118.96  ->  externalDomain = 145-133-118-96.sslip.io
```

---

## Stage 4 — Install the BDP chart
```bash
cd bdp-marketplace-k8s/charts/bdp
helm dependency build

helm install bdp . -n bdp --create-namespace \
  --set global.externalDomain=145-133-118-96.sslip.io \
  --set global.bdpImageRegistry=bdpmarketplace.azurecr.io/bdp \
  --set global.bdpImageTag=1.0.1 \
  --set global.airgapRegistry=bdpmarketplace.azurecr.io \
  --set global.ingressClassName=nginx \
  --set global.insecureSkipTlsVerify=true      # testing only; real deploys use a cert (Stage 7)
  # --set global.keycloakHostAliasIp=<ingress ClusterIP>  # only if the LB does not hairpin
```
Wait for rollout:
```bash
kubectl -n bdp rollout status deploy/bdp-gateway --timeout=300s
kubectl get pods -n bdp    # all Running/Ready
```

> **Key values explained**
> | Value | Why |
> |-------|-----|
> | `externalDomain` | Drives UI, `/api`, and `keycloak.<domain>` hosts |
> | `airgapRegistry` | Redirects tool charts+images to the ACR (no public pulls) |
> | `ingressClassName=nginx` | Also wires `BDP_INGRESS_CLASS` for per-tool UI ingresses |
> | `insecureSkipTlsVerify` | UI pod accepts the self-signed ingress cert (testing only) |
> | `keycloakHostAliasIp` | Only if pods can't reach the public LB (no hairpin) |

---

## Stage 5 — Validate the platform
```bash
export DOMAIN=145-133-118-96.sslip.io
# admin credentials: printed by the seed job / bdp-credentials secret
kubectl get secret bdp-credentials -n bdp -o jsonpath='{.data}'   # decode admin user/pass
```
In the browser (accept the cert warning):
1. `https://<DOMAIN>` → login via Keycloak → dashboard loads.
2. **Dashboard APIs** — no 500s (services, workspaces, clusters/registry, me/permissions all 200).
3. **Deployment targets** — the "Local" IN_CLUSTER target (= this AKS cluster) is ACTIVE.
4. **Install a tool** — Services → **Spark** → INSTALLING → RUNNING.
   - Verify the pod pulls from ACR: `kubectl get pod -n bdp-services spark-master-0 -o jsonpath='{.spec.containers[0].image}'` → `bdpmarketplace.azurecr.io/tools/bitnamilegacy/spark:...`
5. **Install progress WebSocket** — the progress modal streams (needs the rebuilt UI image, Stage 1).
6. **Tool UI** — the Spark URL opens as `https://spark.<DOMAIN>/` (needs the rebuilt service-manager image + wildcard DNS; sslip.io provides it).
7. **Logout** — returns cleanly to `/login` (needs the rebuilt UI image).

---

## Stage 6 — Quick API smoke test (no browser)
```bash
TOKEN=$(curl -sk -X POST https://keycloak.$DOMAIN/realms/bdp/protocol/openid-connect/token \
  -d client_id=bdp-ui -d grant_type=password -d username=admin -d "password=<pass>" \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["access_token"])')
for ep in services workspaces clusters/registry me/permissions; do
  curl -sk -o /dev/null -w "$ep -> %{http_code}\n" https://$DOMAIN/api/v1/$ep -H "Authorization: Bearer $TOKEN"
done   # all should be 200
```

---

## Stage 7 — (Production) real TLS with cert-manager
Replace the self-signed default + drop `insecureSkipTlsVerify`:
```bash
helm repo add jetstack https://charts.jetstack.io
helm install cert-manager jetstack/cert-manager -n cert-manager --create-namespace --set crds.enabled=true
# create a ClusterIssuer (Let's Encrypt) + a wildcard cert for *.<DOMAIN>, then:
helm upgrade bdp . -n bdp --reuse-values \
  --set global.tlsSecretName=bdp-wildcard-tls \
  --set global.insecureSkipTlsVerify=false
```

---

## Stage 8 — Tear down (STOP BILLING)
```bash
az group delete -n bdp-airgap-test --yes --no-wait
```
> This deletes only the AKS cluster. The ACR (`bdpmarketplace`, RG `bdp-marketplace-images`) is separate and stays intact.

---

## Sign-off checklist (K8s offer ready to ship)
- [ ] Chart installs clean; all pods Ready
- [ ] Login + dashboard (no 500s)
- [ ] Air-gap install pulls from ACR (verified image path)
- [ ] Tool reaches RUNNING
- [ ] Install-progress WebSocket streams (rebuilt UI)
- [ ] Tool UI opens at `https://<tool>.<domain>/` (rebuilt svc-mgr)
- [ ] Logout clean (rebuilt UI)
- [ ] Real TLS via cert-manager
- [ ] Cluster deleted after testing

➡️ When testing passes, finish the listing with `06-MARKETPLACE-REMAINING-k8s-offer.md`.
