#!/usr/bin/env bash
# Deploy BDP to a throwaway AKS cluster, verify it, and tear it down.
#
# Run on the build host (needs az logged in, helm, kubectl). Every step below
# was executed end-to-end on 2026-07-31 against chart 1.0.6; the values and the
# gotchas are what actually worked, not what ought to.
#
#   ./deploy-aks-test.sh up      create cluster + ingress + BDP, then verify
#   ./deploy-aks-test.sh verify  re-run the checks against a running cluster
#   ./deploy-aks-test.sh down    delete the resource group (STOPS BILLING)
#
# THE CLUSTER BILLS CONTINUOUSLY. `down` is not optional.
set -euo pipefail

RG="${BDP_RG:-bdp-aks-test}"
CLUSTER="${BDP_CLUSTER:-bdp-test}"
LOCATION="${BDP_LOCATION:-eastus}"
ACR="${BDP_ACR:-bdpmarketplace}"
CHART_DIR="${BDP_CHART_DIR:-$HOME/bdp-marketplace-k8s/charts/bdp}"
KUBECONFIG_FILE="${BDP_KUBECONFIG:-$HOME/aks.kubeconfig}"
NS=bdp

log() { printf '\n== %s ==\n' "$1"; }

up() {
  log "Creating resource group $RG in $LOCATION"
  az group create -n "$RG" -l "$LOCATION" -o none

  # --attach-acr grants the kubelet identity AcrPull. Without it every image
  # fails to pull and the whole install stalls in ImagePullBackOff.
  # --no-wait is rejected when combined with --attach-acr, so this blocks for
  # roughly 5-10 minutes.
  log "Creating AKS cluster $CLUSTER (5-10 min)"
  az aks create -g "$RG" -n "$CLUSTER" \
    --node-count 3 --node-vm-size Standard_D4s_v5 \
    --attach-acr "$ACR" --generate-ssh-keys -o none

  az aks get-credentials -g "$RG" -n "$CLUSTER" --file "$KUBECONFIG_FILE" --overwrite-existing
  export KUBECONFIG="$KUBECONFIG_FILE"

  # Fails loudly here rather than as a pull error twenty minutes later.
  log "Checking the cluster can pull from $ACR"
  az aks check-acr -g "$RG" -n "$CLUSTER" --acr "$ACR.azurecr.io"

  # The health-probe annotation is required: without it Azure's load balancer
  # probes / , gets a 404, and never marks the backend healthy -- the ingress
  # comes up but nothing reaches it.
  log "Installing ingress-nginx"
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
  helm repo update >/dev/null
  helm install ingress-nginx ingress-nginx/ingress-nginx \
    -n ingress-nginx --create-namespace \
    --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-request-path"=/healthz \
    --timeout 10m --wait

  log "Waiting for the load balancer address"
  local ip=""
  for _ in $(seq 1 20); do
    ip=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
         -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    [ -n "$ip" ] && break
    sleep 15
  done
  [ -n "$ip" ] || { echo "ERROR: no load balancer IP"; exit 1; }

  # sslip.io resolves <dashed-ip>.sslip.io to that IP, and gives wildcard DNS
  # for free -- which the per-tool UIs need (spark.<domain> etc.).
  local domain="${ip//./-}.sslip.io"
  echo "$domain" > "$HOME/bdp-domain.txt"
  echo "  ingress IP $ip -> $domain"

  log "Installing BDP"
  cd "$CHART_DIR"
  # `helm dependency build` is deliberately NOT run: the subcharts are vendored
  # under charts/, and Chart.lock is out of sync with Chart.yaml, so the command
  # fails while the install itself is fine.
  #
  # No image tag is passed -- images resolve by digest from
  # global.azure.images, which is what makes the install air-gapped.
  helm install bdp . -n "$NS" --create-namespace \
    --set global.externalDomain="$domain" \
    --set global.airgapRegistry="$ACR.azurecr.io" \
    --set global.ingressClassName=nginx \
    --set global.insecureSkipTlsVerify=true \
    --timeout 20m --wait

  verify
}

verify() {
  export KUBECONFIG="$KUBECONFIG_FILE"
  local domain
  domain=$(cat "$HOME/bdp-domain.txt")

  log "Pod states"
  kubectl get pods -n "$NS" --no-headers | awk '{print $3}' | sort | uniq -c
  kubectl get pods -n "$NS" --no-headers \
    | awk '$3!="Running" && $3!="Completed" {print "  UNHEALTHY: "$1" "$3}'

  # Keycloak in production mode runs a Quarkus build on first start, so it sits
  # 0/1 for a minute or two before going ready. That is normal, not a hang.
  log "Waiting for Keycloak (production mode builds on first start)"
  kubectl wait --for=condition=ready pod/bdp-keycloak-0 -n "$NS" --timeout=300s

  log "Keycloak is genuinely in production mode"
  kubectl exec -n "$NS" bdp-keycloak-0 -- env \
    | grep -E 'KEYCLOAK_PRODUCTION|KEYCLOAK_PROXY|KC_HOSTNAME_URL' | sed 's/^/  /'

  log "Endpoints"
  # 307 = UI redirecting to login, 401 = API alive and demanding a token,
  # 200 = Keycloak serving discovery. Anything else is a real failure.
  curl -sk -o /dev/null -w "  /                      -> %{http_code}\n" -m 20 "https://$domain/"
  curl -sk -o /dev/null -w "  /api/v1/services       -> %{http_code}\n" -m 20 "https://$domain/api/v1/services"
  curl -sk -o /dev/null -w "  keycloak discovery     -> %{http_code}\n" -m 20 \
    "https://keycloak.$domain/realms/bdp/.well-known/openid-configuration"

  log "Air-gap: every image must come from the ACR"
  kubectl get pods -n "$NS" \
    -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' \
    | sed -E 's#(^[^/]+)/.*#\1#' | sort | uniq -c | sed 's/^/  /'

  log "Tool charts resolve from the ACR"
  local tmp; tmp=$(mktemp -d)
  ( cd "$tmp"
    for c in bentoml:1.1.13 feast:0.65.0 iceberg:0.4.4 observability:1.0.5 clickhouse:9.4.4; do
      if helm pull "oci://$ACR.azurecr.io/charts/${c%%:*}" --version "${c#*:}" >/dev/null 2>&1; then
        echo "  OK   charts/${c%%:*}"
      else
        echo "  FAIL charts/${c%%:*}"
      fi
    done )
  rm -rf "$tmp"

  log "Admin credentials"
  echo "  kubectl get secret bdp-credentials -n $NS -o jsonpath='{.data}'"
  echo "  browse https://$domain (accept the self-signed cert)"
}

down() {
  log "Deleting resource group $RG"
  az group delete -n "$RG" --yes --no-wait
  echo "  submitted; the ACR is in a separate group and is untouched"
  for _ in $(seq 1 30); do
    az group show -n "$RG" >/dev/null 2>&1 || { echo "  GONE - billing stopped"; return; }
    sleep 30
  done
  echo "  WARNING: still deleting after 15 min -- check the portal"
}

case "${1:-}" in
  up)     up ;;
  verify) verify ;;
  down)   down ;;
  *)      echo "usage: $0 {up|verify|down}"; exit 1 ;;
esac
