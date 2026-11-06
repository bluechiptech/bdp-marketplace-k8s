#!/usr/bin/env bash
# Install BDP on an existing Kubernetes cluster, top to bottom, in one run.
#
# This is docs/SETUP-EXISTING-KUBERNETES.txt executed rather than read. It
# covers steps 0-6 of that document: the single-node taint, storage, ingress,
# DNS verification, the pull secret, the cert-manager CRD adoption, the helm
# install, the pod-DNS fix, and printing the seeded passwords. Every stage
# inspects the cluster before it acts, so a second run is a no-op (or a helm
# upgrade) rather than a second install.
#
# Two things it deliberately does NOT do, because they are not setup:
#   - step 7, activating the license (browser: Dashboard -> License)
#   - step 8b, TLS for provisioned tool UIs -- that loop runs after each tool
#     install, not once. See the doc.
#
# Usage:
#     ./scripts/setup-existing-k8s.sh
#
# Fill in the CONFIGURATION block below first. Every setting can also be
# overridden from the environment, e.g.
#     BDP_DOMAIN=bdp.acme.com REGISTRY_PASSWORD=... ./scripts/setup-existing-k8s.sh
#
# Verified against the reference install described in the doc: single kubeadm
# v1.35 node, 8 CPU / 16 GB, hostPort ingress, local-path storage, Let's
# Encrypt TLS.
set -euo pipefail

# ─────────────────────────── CONFIGURATION ───────────────────────────
# The platform is served at https://$DOMAIN and Keycloak at
# https://keycloak.$DOMAIN -- BOTH names must already resolve to the
# ingress IP before this script is run (it checks, and refuses otherwise).
#
# IP MODE: set this to a bare IPv4 address instead, for a network with no DNS
# at all. Everything then lives on that one address -- the platform at
# http://<ip>, Keycloak at http://<ip>/auth, and provisioned tool UIs on
# NodePorts (http://<ip>:3xxxx) rather than per-tool subdomains, which would
# need wildcard DNS. TLS_MODE must be "none" or "existing": a public CA cannot
# issue for an IP. No DNS check runs, because there is nothing to resolve.
DOMAIN="${BDP_DOMAIN:-mtnbdp.bluechiptech.biz}"

# Used when TLS_MODE=acme: the Let's Encrypt registration address, which is
# where expiry warnings go. That is its ONLY use -- global.adminEmail reaches
# nothing but templates/certificate.yaml; the platform sends no mail of its own.
ADMIN_EMAIL="${BDP_ADMIN_EMAIL:-agbadeyanka@bluechiptech.biz}"

# Required. Vendor registry pull credentials. For bdpmarketplace.azurecr.io:
# portal.azure.com -> container registry "bdpmarketplace" -> Access keys ->
# enable Admin user.
REGISTRY="${BDP_REGISTRY:-bdpmarketplace.azurecr.io}"
REGISTRY_USERNAME="${BDP_REGISTRY_USERNAME:-bdpmarketplace}"
REGISTRY_PASSWORD="${BDP_REGISTRY_PASSWORD:-}"

# acme      - cert-manager requests a certificate from Let's Encrypt.
#             Needs ADMIN_EMAIL and public DNS for both names, and port 80
#             reachable from the internet for the HTTP-01 challenge.
# existing  - you already created the TLS secret named by TLS_SECRET:
#               kubectl create secret tls bdp-tls -n bdp \
#                 --cert=fullchain.pem --key=privkey.pem
#             The certificate must cover BOTH names, full chain, server cert
#             first.
# none      - plain HTTP. Throwaway test clusters only: Keycloak issues every
#             token in the platform over that same connection.
TLS_MODE="${BDP_TLS_MODE:-acme}"
TLS_SECRET="${BDP_TLS_SECRET:-bdp-tls}"

# Name of a ReadWriteMany-capable StorageClass (NFS, CephFS, Longhorn, EFS,
# Filestore) for tool-shared storage. LEAVE EMPTY if the cluster has no RWX
# class -- local-path and most single-node setups are RWO-only -- and shared
# storage is disabled instead. Setting a class that is not really RWX leaves
# the shared PVC Pending forever.
SHARED_STORAGE_CLASS="${BDP_SHARED_STORAGE_CLASS:-}"

# auto | true | false. On a ~16 GB node the loki subchart alone requests ~9 GB
# for its chunks/results caches, which deadlocks the install (half the pods
# Pending, node at 99% of its memory-request quota). "true" shrinks those two
# caches to 768 MB total and halves every platform service's memory request
# from 512Mi to 256Mi. "auto" measures the smallest node and decides, so a big
# cluster keeps the full log-query cache and a small one still fits.
SMALL_NODE="${BDP_SMALL_NODE:-auto}"
SMALL_NODE_THRESHOLD_GB="${BDP_SMALL_NODE_THRESHOLD_GB:-24}"

# The chart expects ingress class "nginx". Cloud-provider controllers and
# RKE2's built-in use other names -- put the name from
# `kubectl get ingressclass` here.
INGRESS_CLASS="${BDP_INGRESS_CLASS:-nginx}"

# The public address users reach the platform on, and what DNS must point at.
# Normally discovered: a LoadBalancer's EXTERNAL-IP, or the node's ExternalIP
# in hostPort mode. SET IT HERE when the node is behind NAT -- a cloud node
# whose public address is not on the Node object at all reports only an
# InternalIP (10.x/172.16.x/192.168.x), which is NOT what DNS resolves to and
# cannot be compared against it.
INGRESS_IP="${BDP_INGRESS_IP:-}"

# auto | <ip> | "" (disable). In hostPort mode the ingress has no LoadBalancer
# in front of it, and pods usually CANNOT reach the node's own public address
# from inside the cluster -- NAT does not loop back. The UI then resolves
# keycloak.<domain> to a public IP it cannot open, and login dies with
# error=OAuthSignin. Pointing that one hostname at the ingress controller's
# ClusterIP inside the cluster fixes it. "auto" applies this only when there
# is no LoadBalancer, which is exactly when it is needed.
KEYCLOAK_HOST_ALIAS_IP="${BDP_KEYCLOAK_HOST_ALIAS_IP:-auto}"

# byol blocks provisioning of data tools until a signed license.key is
# uploaded in the UI (step 7). flat/metered are the marketplace plans.
BILLING_MODE="${BDP_BILLING_MODE:-byol}"

# Where the chart comes from. Normally the script runs from inside a clone of
# the marketplace repo and finds charts/bdp next to itself. Copied to a bare
# machine on its own, it clones the repo to REPO_DIR instead, so a brand-new
# cluster needs nothing staged in advance.
REPO_URL="${BDP_REPO_URL:-https://github.com/bluechiptech/bdp-marketplace-k8s.git}"
REPO_DIR="${BDP_REPO_DIR:-$HOME/bdp-marketplace-k8s}"
REPO_REF="${BDP_REPO_REF:-}"   # branch or tag; empty = the default branch

NAMESPACE="${BDP_NAMESPACE:-bdp}"
RELEASE="${BDP_RELEASE:-bdp}"
PULL_SECRET="${BDP_PULL_SECRET:-bdp-registry-cred}"

# ── Post-install notification (step 6b) ──────────────────────────────
# Where to email the sign-in details once the install succeeds. EMPTY = the
# feature is off and the script behaves exactly as it did without it.
#
# Verified working with Brevo's SMTP relay, which needs no mail server on the
# node -- curl speaks SMTP directly. Sending straight from the node instead is
# NOT viable: it has no PTR record, and an SPF of "-all" that authorises only
# the domain's real mail provider means receivers reject it.
NOTIFY_EMAIL="${BDP_NOTIFY_EMAIL:-agbadeyanka@bluechiptech.biz}"
MAIL_HOST="${BDP_MAIL_HOST:-smtp-relay.brevo.com}"
MAIL_PORT="${BDP_MAIL_PORT:-587}"
MAIL_USER="${BDP_MAIL_USER:-9cefdf001@smtp-brevo.com}"
MAIL_PASSWORD="${BDP_MAIL_PASSWORD:-}"
MAIL_FROM="${BDP_MAIL_FROM:-Support@bluechiptech.biz}"

# Whether the message carries the actual passwords. The seed generates a fresh
# random pair on EVERY helm upgrade, so with this on, each upgrade mails a new
# live credential that then sits in a mailbox indefinitely. Off, the message
# says the platform is ready and names the secret to read. Turning it on is
# reasonable once the seed marks the password temporary (Keycloak's
# UPDATE_PASSWORD required action), which makes the mailed one single-use.
NOTIFY_INCLUDE_PASSWORDS="${BDP_NOTIFY_INCLUDE_PASSWORDS:-true}"

# Pinned versions of the two things this script may install itself.
CERT_MANAGER_CRDS="${BDP_CERT_MANAGER_CRDS:-v1.15.3}"
LOCAL_PATH_VERSION="${BDP_LOCAL_PATH_VERSION:-v0.0.31}"

# How long to wait for every pod to reach Running/Completed. A first install
# pulls several GB, so this is generous on purpose.
POD_TIMEOUT_SECS="${BDP_POD_TIMEOUT_SECS:-1800}"

# How long a pod fault (ImagePullBackOff, CrashLoopBackOff) must persist before
# the install is called failed. Services restart once or twice on a cold start
# while PostgreSQL comes up; aborting on the first sighting fails good installs.
FAULT_GRACE_SECS="${BDP_FAULT_GRACE_SECS:-180}"

# Set to 1 for a genuinely read-only pass: every check still runs against the
# real cluster, and every command that would CHANGE it is printed instead of
# executed (see run() / apply_stdin() below). Nothing is created, not even the
# namespace.
DRY_RUN="${HELM_DRY_RUN:-0}"
# ───────────────────────── END CONFIGURATION ─────────────────────────

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="${BDP_CHART_DIR:-$HERE/../charts/bdp}"
VALUES_FILE="${BDP_VALUES_FILE:-$HOME/pull-secrets.yaml}"
KEYCLOAK_HOST=""            # set once DOMAIN is validated; empty in IP mode
# IP MODE. True when DOMAIN is a bare IPv4 address instead of a hostname, which
# is how you install on a network with no DNS at all. The chart detects the same
# thing from global.externalDomain and moves Keycloak from its own subdomain to
# the /auth path, because "keycloak.10.0.4.83" is not a resolvable name. This
# script's job is to skip every check that assumes names exist, and to pass the
# one value the chart cannot derive on its own (keycloak.httpRelativePath).
IP_MODE=false
# Whether INGRESS_IP is the address DNS is supposed to resolve to. An
# InternalIP guess is not: on a NAT'd node it is a private address behind the
# public one, so a "mismatch" against public DNS means nothing. Step 3 only
# treats a mismatch as fatal when this is true.
INGRESS_IP_AUTHORITATIVE=false
# True when no LoadBalancer fronts the ingress, i.e. traffic arrives on the
# node's own ports. Decided in step 2, consumed by the Keycloak host alias.
INGRESS_HOSTPORT_MODE=false
# Filled in by step 6, read by step 6b. Declared here so `set -u` cannot trip
# on them when step 6 returns early (a missing bdp-credentials secret).
PLATFORM_URL=""
ADMIN_PASSWORD=""
ENGINEER_PASSWORD=""

# Temporary files to remove on the way out, however we leave. Anything holding
# a credential is shredded at its own call site rather than left to this.
CLEANUP_FILES=()
cleanup() {
  if (( ${#CLEANUP_FILES[@]} > 0 )); then rm -f "${CLEANUP_FILES[@]}"; fi
}
trap cleanup EXIT

log()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf '\033[33m   WARNING: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31m\nERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# EVERY command that changes the cluster goes through one of these two. Under
# DRY_RUN they print and return success, which is what makes a dry pass safe
# to point at a live cluster -- the inspection still happens for real.
run() {
  if [[ "$DRY_RUN" == 1 ]]; then
    printf '   \033[2m+ %s\033[0m\n' "$*"
    return 0
  fi
  "$@"
}

# The manifest-on-stdin variant, for the `... -o yaml | kubectl apply -f -`
# idiom the doc uses to make creates idempotent.
apply_stdin() {
  # Drain stdin FIRST, always. Returning early without reading leaves the
  # upstream `kubectl create ... -o yaml` writing into a closed pipe: it dies
  # on EPIPE, pipefail propagates that, and set -e kills the whole script --
  # silently, one line into a dry run.
  local manifest
  manifest="$(cat)"

  if [[ "$DRY_RUN" == 1 ]]; then
    printf '   \033[2m+ kubectl apply -f -  (%s)\033[0m\n' "$1"
    return 0
  fi
  printf '%s\n' "$manifest" | kubectl apply -f -
}

# ── Preflight ────────────────────────────────────────────────────────
# Everything that can be known before touching the cluster is checked here,
# so a missing password fails in two seconds rather than twenty minutes into
# an ImagePullBackOff.
preflight() {
  log "Preflight"

  for bin in kubectl helm; do
    command -v "$bin" >/dev/null || die "$bin not found on PATH"
  done

  # The chart uses features that landed in helm 3.14.
  local hv
  hv="$(helm version --template '{{.Version}}' | sed 's/^v//')"
  local major minor
  major="${hv%%.*}"; minor="${hv#*.}"; minor="${minor%%.*}"
  if (( major < 3 || (major == 3 && minor < 14) )); then
    die "helm >= 3.14 required, found $hv"
  fi
  info "helm $hv, kubectl $(kubectl version --client 2>/dev/null | awk '/^Client Version/ { print $NF }')"

  kubectl cluster-info >/dev/null 2>&1 \
    || die "kubectl cannot reach a cluster -- check your kubeconfig/context"
  info "cluster: $(kubectl config current-context)"

  [[ -n "$DOMAIN" ]]            || die "DOMAIN is empty -- set it in the CONFIGURATION block"
  [[ -n "$REGISTRY_USERNAME" ]] || die "REGISTRY_USERNAME is empty"
  [[ -n "$REGISTRY_PASSWORD" ]] || die "REGISTRY_PASSWORD is empty"

  if [[ "$DOMAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    IP_MODE=true
    KEYCLOAK_HOST=""          # there is no separate Keycloak hostname
    info "IP MODE: the platform is addressed as $DOMAIN, with Keycloak at $DOMAIN/auth"
    info "no DNS is required or consulted -- nothing here resolves a name"
  else
    KEYCLOAK_HOST="keycloak.$DOMAIN"
  fi

  case "$TLS_MODE" in
    acme)
      if [[ "$IP_MODE" == true ]]; then
        die "TLS_MODE=acme cannot work with a bare IP ($DOMAIN).
       Let's Encrypt does not issue certificates for IP addresses, and the
       HTTP-01 challenge would have to reach this address from the public
       internet. Use TLS_MODE=none for plain HTTP, or TLS_MODE=existing with a
       certificate you created yourself (it must carry the IP as a SAN)."
      fi
      [[ -n "$ADMIN_EMAIL" ]] || die "TLS_MODE=acme requires ADMIN_EMAIL"
      ;;
    existing)
      [[ -n "$TLS_SECRET" ]] || die "TLS_MODE=existing requires TLS_SECRET"
      kubectl get secret "$TLS_SECRET" -n "$NAMESPACE" >/dev/null 2>&1 \
        || die "TLS_MODE=existing but secret $TLS_SECRET does not exist in namespace $NAMESPACE.
       Create it first:
         kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
         kubectl create secret tls $TLS_SECRET -n $NAMESPACE \\
           --cert=/path/to/fullchain.pem --key=/path/to/privkey.pem"
      ;;
    none)
      warn "TLS_MODE=none -- the platform AND Keycloak will be served over plain HTTP."
      ;;
    *) die "TLS_MODE must be acme, existing or none (got: $TLS_MODE)" ;;
  esac

  ensure_chart
}

# The chart is the ONE thing this script cannot fetch on demand from a public
# URL, so it is the only real prerequisite. Running from inside a clone, it is
# already next door; running from a script copied onto a bare machine, clone it.
ensure_chart() {
  if [[ ! -d "$CHART_DIR" ]]; then
    command -v git >/dev/null \
      || die "chart not found at $CHART_DIR and git is not installed to fetch it.
       Either install git, or clone the repo yourself and re-run from inside it:
         git clone $REPO_URL"

    if [[ -d "$REPO_DIR/.git" ]]; then
      info "chart not beside the script; refreshing existing clone $REPO_DIR"
      git -C "$REPO_DIR" pull --ff-only >/dev/null 2>&1 \
        || warn "could not fast-forward $REPO_DIR -- using it as it stands"
    else
      info "chart not beside the script; cloning $REPO_URL -> $REPO_DIR"
      local -a ref=()
      [[ -n "$REPO_REF" ]] && ref=(--branch "$REPO_REF")
      git clone --depth 1 "${ref[@]}" "$REPO_URL" "$REPO_DIR" \
        || die "clone failed. A private repo needs credentials; clone it by hand and
       point BDP_CHART_DIR at its charts/bdp."
    fi
    CHART_DIR="$REPO_DIR/charts/bdp"
    [[ -d "$CHART_DIR" ]] || die "cloned $REPO_URL but $CHART_DIR is still missing"
  fi

  # The repo ships PATCHED vendored subcharts in charts/bdp/charts/. NEVER run
  # `helm dependency build` to recreate them: it fetches unpatched upstream
  # copies and breaks the registry wiring. A stale clone from before 2026-08-07
  # has no charts/ dir at all, and helm would otherwise fail deep inside the
  # install with "found in Chart.yaml, but missing in charts/".
  if [[ -f "$CHART_DIR/Chart.yaml" ]] && grep -q '^dependencies:' "$CHART_DIR/Chart.yaml"; then
    [[ -d "$CHART_DIR/charts" ]] \
      || die "$CHART_DIR/charts/ is missing -- this clone predates the vendored subcharts.
       Run 'git pull'. Do NOT run 'helm dependency build': it would fetch
       unpatched upstream subcharts and break the registry wiring."
  fi
  info "chart: $CHART_DIR"
}

# ── Step 0: single-node taint ────────────────────────────────────────
# kubeadm taints the control plane NoSchedule. On a single-node cluster that
# means nothing ever starts.
step0_untaint() {
  log "Step 0 - control-plane taint"

  local nodes
  nodes="$(kubectl get nodes --no-headers | wc -l | tr -d ' ')"
  info "$nodes node(s)"

  if ! kubectl get nodes -o jsonpath='{.items[*].spec.taints[*].key}' \
       | grep -q 'node-role.kubernetes.io/control-plane'; then
    info "no control-plane taint, nothing to do"
    return
  fi

  if (( nodes > 1 )); then
    info "multi-node cluster: leaving the control-plane taint in place"
    return
  fi

  info "single node is tainted NoSchedule -- removing it"
  run kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true
}

# ── Step 1: storage ──────────────────────────────────────────────────
# postgres, redis, keycloak, prometheus and loki all create PVCs from the
# default class. Without one they sit Pending forever.
step1_storage() {
  log "Step 1 - storage"

  # kubectl marks the default class "<name> (default)" in the NAME column --
  # the same thing the doc tells you to look for by eye.
  local default_sc
  default_sc="$(kubectl get storageclass --no-headers 2>/dev/null \
    | awk '$0 ~ /\(default\)/ { print $1; exit }' || true)"

  if [[ -n "$default_sc" ]]; then
    info "default StorageClass: $default_sc"
  else
    info "no default StorageClass -- installing the local-path provisioner"
    run kubectl apply -f "https://raw.githubusercontent.com/rancher/local-path-provisioner/$LOCAL_PATH_VERSION/deploy/local-path-storage.yaml"
    run kubectl patch storageclass local-path \
      -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
    run kubectl -n local-path-storage rollout status deploy/local-path-provisioner --timeout=120s
    default_sc=local-path
    info "default StorageClass: local-path (ReadWriteOnce only)"
  fi

  # An RWX class that is not actually RWX leaves the shared PVC Pending, which
  # is a confusing failure much later. Say what was chosen, loudly.
  if [[ -n "$SHARED_STORAGE_CLASS" ]]; then
    kubectl get storageclass "$SHARED_STORAGE_CLASS" >/dev/null 2>&1 \
      || die "SHARED_STORAGE_CLASS=$SHARED_STORAGE_CLASS does not exist on this cluster"
    info "shared tool storage: $SHARED_STORAGE_CLASS (must be ReadWriteMany-capable)"
  else
    info "shared tool storage: DISABLED (no RWX class configured)"
  fi
}

# ── Step 2: ingress ──────────────────────────────────────────────────
# Reuses whatever is already installed. Only a cluster with no ingress
# controller at all gets one installed here.
step2_ingress() {
  log "Step 2 - ingress controller"

  if kubectl get ingressclass "$INGRESS_CLASS" >/dev/null 2>&1; then
    info "ingressclass $INGRESS_CLASS already exists -- reusing it"
  elif [[ -n "$(kubectl get ingressclass --no-headers 2>/dev/null)" ]]; then
    die "an ingress controller exists but not with class '$INGRESS_CLASS'.
       Classes found: $(kubectl get ingressclass --no-headers | awk '{print $1}' | tr '\n' ' ')
       Set INGRESS_CLASS to the one you want to use."
  else
    install_ingress_nginx
  fi

  discover_ingress_ip
}

install_ingress_nginx() {
  local nodes
  nodes="$(kubectl get nodes --no-headers | wc -l | tr -d ' ')"

  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null
  helm repo update ingress-nginx >/dev/null

  if (( nodes == 1 )); then
    # No load balancer to hand out an EXTERNAL-IP on a single node, so bind
    # the controller to the node's own 80/443 instead. A plain ClusterIP
    # install with no hostPort is unreachable from outside -- the failure mode
    # the doc warns about.
    info "single node -- installing ingress-nginx in hostPort mode (80/443 on the node)"
    run helm install ingress-nginx ingress-nginx/ingress-nginx \
      -n ingress-nginx --create-namespace \
      --set controller.hostPort.enabled=true \
      --set controller.service.type=ClusterIP
  else
    # Bare metal needs MetalLB (or another allocator) already present for this
    # to get an address; on a cloud provider the service type does it.
    info "installing ingress-nginx with a LoadBalancer service"
    run helm install ingress-nginx ingress-nginx/ingress-nginx \
      -n ingress-nginx --create-namespace
  fi

  run kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=300s
}

# Works out the address users will hit, for the DNS check in step 3.
discover_ingress_ip() {
  # IP mode already knows the answer -- DOMAIN *is* the entry point. Discovering
  # a different address (the node's public egress, say) and then talking about
  # DNS records is noise at best and misleading at worst.
  if [[ "$IP_MODE" == true ]]; then
    INGRESS_IP="$DOMAIN"
    INGRESS_IP_AUTHORITATIVE=true
    info "ingress entry point: $INGRESS_IP (the configured address)"
    # Still record whether a LoadBalancer fronts things; unrelated to naming.
    kubectl get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
      | grep -q . || INGRESS_HOSTPORT_MODE=true
    return
  fi

  # AWS hands out a hostname rather than an ip, so take whichever is set.
  # Computed before the override below, because whether a LoadBalancer exists
  # is a separate question from what address the operator told us to use.
  local svc_ip
  svc_ip="$(kubectl get svc -A \
    -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}{"\n"}{end}' \
    2>/dev/null | grep -v '^$' | head -1 || true)"
  [[ -n "$svc_ip" ]] || INGRESS_HOSTPORT_MODE=true

  # An operator-supplied address always wins: on a NAT'd node it is the only
  # source that can be right, because the public address appears nowhere in
  # the cluster's own API.
  if [[ -n "$INGRESS_IP" ]]; then
    INGRESS_IP_AUTHORITATIVE=true
    info "ingress entry point: $INGRESS_IP (configured)"
    return
  fi

  if [[ -n "$svc_ip" ]]; then
    INGRESS_IP="$svc_ip"
    INGRESS_IP_AUTHORITATIVE=true
    info "ingress entry point: $INGRESS_IP (LoadBalancer EXTERNAL-IP)"
    return
  fi

  # hostPort mode: the entry point is the node itself.
  local ext_ip
  ext_ip="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null || true)"
  if [[ -n "$ext_ip" ]]; then
    INGRESS_IP="$ext_ip"
    INGRESS_IP_AUTHORITATIVE=true
    info "ingress entry point: $INGRESS_IP (node ExternalIP, hostPort)"
    return
  fi

  # No ExternalIP means the node is typically behind NAT, and its public address
  # exists nowhere in the cluster API. Ask the internet what address this node
  # comes from. On the usual cloud NAT the egress and ingress addresses are the
  # same one, which makes this a real answer rather than a guess -- but they CAN
  # differ (separate SNAT pool, or inbound DNAT from another address), so it is
  # only trusted when the platform's own DNS agrees with it.
  local echoed
  for svc in https://api.ipify.org https://ifconfig.me https://icanhazip.com; do
    echoed="$(curl -s --max-time 10 "$svc" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ "$echoed" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
    echoed=""
  done

  if [[ -n "$echoed" ]]; then
    # Corroborate against DNS before trusting it. Agreement means two
    # independent sources say the same thing, which is what an operator-supplied
    # value would have told us anyway.
    local resolved=""
    if command -v dig >/dev/null; then
      resolved="$(dig +short "$DOMAIN" 2>/dev/null | tail -1)"
    elif command -v getent >/dev/null; then
      resolved="$(getent hosts "$DOMAIN" 2>/dev/null | awk '{print $1}' | head -1)"
    fi

    INGRESS_IP="$echoed"
    if [[ -n "$resolved" && "$resolved" == "$echoed" ]]; then
      INGRESS_IP_AUTHORITATIVE=true
      info "ingress entry point: $INGRESS_IP (node's public address, confirmed by DNS)"
    else
      INGRESS_IP_AUTHORITATIVE=false
      info "ingress entry point: $INGRESS_IP (node's public egress address)"
      info "DNS for $DOMAIN says '${resolved:-nothing}' -- not treating these as"
      info "comparable; set INGRESS_IP if inbound traffic arrives on another address"
    fi
    return
  fi

  # Nothing external answered either. Fall back to the private address purely
  # for orientation -- it is never what public DNS resolves to.
  INGRESS_IP="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
  INGRESS_IP_AUTHORITATIVE=false
  if [[ -n "$INGRESS_IP" ]]; then
    info "ingress entry point: node InternalIP $INGRESS_IP (hostPort)"
    info "no ExternalIP and no internet egress to discover the public one --"
    info "set INGRESS_IP if this node is behind NAT"
  else
    warn "could not determine the ingress IP -- the DNS check below is best-effort"
  fi
}

# ── Step 3: DNS ──────────────────────────────────────────────────────
# Both names must resolve publicly. Without keycloak.<domain>, login fails;
# with acme, an unresolvable name means the challenge can never be reached and
# the install finishes with a certificate stuck READY:False.
step3_dns() {
  log "Step 3 - DNS"

  # Nothing to check: an IP is not resolved, it is dialled. The one thing that
  # WOULD matter -- can traffic actually reach this address -- is verified in
  # step 5b against the running platform, which is a real answer rather than a
  # guess about a name.
  if [[ "$IP_MODE" == true ]]; then
    info "IP mode: no names to resolve, skipping"
    return
  fi

  local resolver=""
  command -v dig     >/dev/null && resolver=dig
  [[ -n "$resolver" ]] || { command -v getent >/dev/null && resolver=getent; }
  [[ -n "$resolver" ]] || { warn "neither dig nor getent available -- skipping the DNS check"; return; }

  # Only worth comparing against a literal address we actually trust. A cloud
  # LoadBalancer hostname is a CNAME target, so the resolved address
  # legitimately differs; a guessed InternalIP is a private address behind NAT.
  # In both cases "does it resolve at all" is the whole check.
  local expect=""
  if [[ "$INGRESS_IP_AUTHORITATIVE" == true && "$INGRESS_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    expect="$INGRESS_IP"
  fi

  local host failed=0
  for host in "$DOMAIN" "$KEYCLOAK_HOST"; do
    local got
    if [[ "$resolver" == dig ]]; then
      got="$(dig +short "$host" | tail -1)"
    else
      got="$(getent hosts "$host" | awk '{print $1}' | head -1)"
    fi

    if [[ -z "$got" ]]; then
      warn "$host does not resolve"
      failed=1
    elif [[ -n "$expect" && "$got" != "$expect" ]]; then
      warn "$host resolves to $got, expected the ingress IP $expect"
      failed=1
    else
      info "$host -> $got"
    fi
  done

  if (( failed )); then
    if [[ "$TLS_MODE" == acme ]]; then
      die "DNS is not ready and TLS_MODE=acme -- the HTTP-01 challenge would never
       complete. Point these at ${INGRESS_IP:-the ingress IP} and re-run:
         *.$DOMAIN            (wildcard, covers provisioned tool subdomains too)
       or, without wildcard support, two A records:
         $DOMAIN
         $KEYCLOAK_HOST
       For a quick test without DNS, set DOMAIN=${INGRESS_IP:-<ip>}.sslip.io"
    fi
    warn "continuing with unresolved DNS because TLS_MODE=$TLS_MODE -- login will fail until it resolves"
  fi
}

# ── Step 4a: registry credentials ────────────────────────────────────
# The pull secret MUST exist before the install. The kube-prometheus-stack
# admission job is a PRE-INSTALL HOOK: it runs before the chart's own
# manifests are applied, so a chart-created secret does not exist yet when
# that hook pod tries to pull, and the install wedges in ImagePullBackOff
# until the timeout. Hence kubectl here, and registryCredentials.create=false
# in the values file below.
step4a_registry() {
  log "Step 4a - registry pull secret"

  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml \
    | apply_stdin "namespace/$NAMESPACE"

  kubectl create secret docker-registry "$PULL_SECRET" -n "$NAMESPACE" \
    --docker-server="$REGISTRY" \
    --docker-username="$REGISTRY_USERNAME" \
    --docker-password="$REGISTRY_PASSWORD" \
    --dry-run=client -o yaml \
    | apply_stdin "secret/$PULL_SECRET"
  info "secret $PULL_SECRET -> $REGISTRY"

  # A dry pass still needs a real file for the helm render below, but must not
  # clobber a hand-edited one -- so it writes a throwaway copy instead.
  if [[ "$DRY_RUN" == 1 ]]; then
    VALUES_FILE="$(mktemp)"
    CLEANUP_FILES+=("$VALUES_FILE")
    info "dry run: writing values to $VALUES_FILE instead of ${BDP_VALUES_FILE:-$HOME/pull-secrets.yaml}"
  fi

  # loki and alloy take their pull secrets under different keys than the
  # platform chart, so all three have to be named explicitly.
  cat > "$VALUES_FILE" <<EOF
# GENERATED by scripts/setup-existing-k8s.sh -- safe to delete and regenerate.
# Contains no credentials: it only names the secret created with kubectl.
global:
  registryCredentials:
    create: false
  imagePullSecrets: [{name: $PULL_SECRET}]
loki:
  imagePullSecrets: [{name: $PULL_SECRET}]
alloy:
  global:
    image:
      pullSecrets: [{name: $PULL_SECRET}]
EOF
  info "values: $VALUES_FILE"
}

# ── Step 4b: cert-manager CRDs ───────────────────────────────────────
# The chart renders Certificate/Issuer resources, so the CRDs must exist
# before the install -- and helm must be told it owns them, or it refuses
# with "invalid ownership metadata".
step4b_crds() {
  [[ "$TLS_MODE" == acme ]] || return 0
  log "Step 4b - cert-manager CRDs"

  run kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/$CERT_MANAGER_CRDS/cert-manager.crds.yaml"

  local crd
  # grep finds nothing on a dry pass against a cluster without the CRDs, which
  # is not an error here -- the apply above is what would have created them.
  for crd in $(kubectl get crd -o name 2>/dev/null | grep cert-manager.io || true); do
    run kubectl label    "$crd" app.kubernetes.io/managed-by=Helm --overwrite >/dev/null
    run kubectl annotate "$crd" "meta.helm.sh/release-name=$RELEASE" \
                                "meta.helm.sh/release-namespace=$NAMESPACE" --overwrite >/dev/null
  done
  info "CRDs applied and adopted into release $RELEASE"
}

# ── Step 4c: install ─────────────────────────────────────────────────
step4c_install() {
  log "Step 4c - helm install"

  local -a args=(
    "$RELEASE" "$CHART_DIR"
    -n "$NAMESPACE" --create-namespace
    -f "$VALUES_FILE"
    --set "global.externalDomain=$DOMAIN"
    --set "global.ingressClassName=$INGRESS_CLASS"
    --set "billing.mode=$BILLING_MODE"
    # Even without --wait, helm blocks on the post-install seed Job, and that
    # Job cannot finish until Keycloak and PostgreSQL are up -- ~11 minutes on
    # a cold first install. helm's default 5m gave up while the seed was still
    # running fine in the background.
    --timeout "${POD_TIMEOUT_SECS}s"
  )

  # Tool charts pinned to the private registry (nifi, api-gateway,
  # observability) are pulled by the provisioner's own helm OCI client, which
  # the image pull secret above does not cover: without these it pulls
  # anonymously and every such install 401s. Commas are escaped for --set.
  args+=(--set "global.airgapRegistryUsername=${REGISTRY_USERNAME//,/\\,}"
         --set "global.airgapRegistryPassword=${REGISTRY_PASSWORD//,/\\,}")

  # IP mode: Keycloak serves under /auth rather than /. The chart cannot set this
  # itself -- the Keycloak subchart consumes httpRelativePath directly, with no
  # tpl, so a conditional in values.yaml would be taken literally -- and it is
  # load-bearing beyond the URL: the subchart's readiness probe is built from
  # the same value, so a mismatch leaves the pod permanently NotReady.
  # templates/ingress.yaml refuses to render if this disagrees with the domain.
  if [[ "$IP_MODE" == true ]]; then
    args+=(--set keycloak.httpRelativePath=/auth)
  fi

  if [[ -n "$SHARED_STORAGE_CLASS" ]]; then
    args+=(--set "sharedStorage.storageClass=$SHARED_STORAGE_CLASS")
  else
    args+=(--set sharedStorage.enabled=false)
  fi

  case "$TLS_MODE" in
    acme)
      args+=(--set global.tls.mode=acme
             --set "global.tlsSecretName=$TLS_SECRET"
             --set "global.adminEmail=$ADMIN_EMAIL")
      ;;
    existing)
      args+=(--set "global.tlsSecretName=$TLS_SECRET")
      ;;
    none)
      args+=(--set global.insecureSkipTlsVerify=true)
      ;;
  esac

  # Keycloak host alias -- see the config block. Only meaningful without a
  # LoadBalancer, so "auto" resolves to the controller's ClusterIP there and to
  # nothing otherwise.
  local alias_ip="$KEYCLOAK_HOST_ALIAS_IP"
  # Meaningless in IP mode: hostAliases rewrites NAMES to addresses, and there is
  # no name here -- Keycloak is a path on the very address the pod would dial.
  # The chart ignores the value in IP mode too; this keeps the log honest.
  if [[ "$IP_MODE" == true ]]; then
    alias_ip=""
  elif [[ "$alias_ip" == auto ]]; then
    if [[ "$INGRESS_HOSTPORT_MODE" == true ]]; then
      # Identify the controller Service by the port it publishes, not by
      # `component=controller` alone: that label is generic (the chart's own
      # bdp-cert-manager carries it too) and a namespace-wide items[0] then
      # returns whichever sorts first -- silently pinning Keycloak at the wrong
      # service. The ingress controller is the one serving port 80; its
      # admission webhook Service serves only 443.
      alias_ip="$(kubectl get svc -A -l app.kubernetes.io/name=ingress-nginx --no-headers \
        -o custom-columns=IP:.spec.clusterIP,PORTS:.spec.ports[*].port 2>/dev/null \
        | awk '$2 ~ /(^|,)80(,|$)/ { print $1; exit }' || true)"
      [[ -n "$alias_ip" ]] || alias_ip="$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
        -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
      if [[ -n "$alias_ip" ]]; then
        info "hostPort ingress: pinning $KEYCLOAK_HOST to controller ClusterIP $alias_ip inside the cluster"
      else
        warn "hostPort ingress but the controller ClusterIP could not be found -- if login
   fails with error=OAuthSignin, set KEYCLOAK_HOST_ALIAS_IP by hand"
      fi
    else
      alias_ip=""
    fi
  fi
  if [[ -n "$alias_ip" ]]; then
    args+=(--set "global.keycloakHostAliasIp=$alias_ip")
  fi

  if [[ "$SMALL_NODE" == auto ]]; then
    # Allocatable, not capacity: what is actually schedulable is what the
    # requests have to fit inside. Smallest node decides, since the stack has
    # to land somewhere.
    local smallest_kb
    smallest_kb="$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.memory}{"\n"}{end}' 2>/dev/null \
      | sed 's/Ki$//' | sort -n | head -1)"
    if [[ -n "$smallest_kb" ]]; then
      local gb=$(( smallest_kb / 1024 / 1024 ))
      if (( gb < SMALL_NODE_THRESHOLD_GB )); then SMALL_NODE=true; else SMALL_NODE=false; fi
      info "smallest node has ${gb}Gi allocatable -> SMALL_NODE=$SMALL_NODE (threshold ${SMALL_NODE_THRESHOLD_GB}Gi)"
    else
      SMALL_NODE=true
      warn "could not read node allocatable memory -- assuming a small node"
    fi
  fi

  if [[ "$SMALL_NODE" == true ]]; then
    args+=(--set loki.chunksCache.allocatedMemory=512
           --set loki.resultsCache.allocatedMemory=256
           --set serviceDefaults.resources.requests.memory=256Mi)
    info "small-node sizing: loki caches 768Mi total, service requests 256Mi"
  fi

  if [[ "$DRY_RUN" == 1 ]]; then
    # client-side only: step 4b did not really apply the cert-manager CRDs on a
    # dry pass, so a server-side render would fail with "no matches for kind
    # Certificate" for reasons that say nothing about the values.
    info "DRY RUN -- rendering instead of installing"
    helm install "${args[@]}" --dry-run=client >/dev/null
    printf '   helm install %s\n' "${args[*]}" \
      | sed -E 's/(airgapRegistryPassword=)[^ ]*/\1*****/'
    return
  fi

  # Deliberately NO --wait: helm applies everything and returns, then the
  # cluster pulls several GB of images on its own -- routinely longer than any
  # sane --wait timeout on a first install. wait_for_pods below does the
  # waiting, and can report WHAT is stuck.
  #
  # The post-install/post-upgrade seed hook is the one thing helm blocks on
  # regardless of --wait, and a slow first boot can outlive even the
  # ${POD_TIMEOUT_SECS}s budget. When that happens every resource is applied
  # and the seed Job is still running in the cluster -- a slow install, not a
  # failed one. Catch exactly that error and hand the waiting to
  # wait_for_pods, which tracks the Job and fails loudly with the Job's own
  # log if the Job itself fails. Any other helm error still dies here.
  local helm_err rc=0
  helm_err="$(mktemp)"
  CLEANUP_FILES+=("$helm_err")

  if helm status "$RELEASE" -n "$NAMESPACE" >/dev/null 2>&1; then
    # A release none of whose revisions ever reached "deployed" (a first
    # install that died mid-flight) cannot be upgraded: helm refuses with
    # "has no deployed releases". The live resources all carry this release's
    # ownership metadata, so the non-destructive repair is to drop helm's
    # bookkeeping Secrets and install again -- helm adopts the resources in
    # place, re-runs the hooks and records a clean deployed revision.
    if helm history "$RELEASE" -n "$NAMESPACE" -o json 2>/dev/null \
         | grep -Eq '"status":[[:space:]]*"(deployed|superseded)"'; then
      info "release $RELEASE exists -- upgrading"
      warn "every upgrade re-runs the seed job, which ROTATES the admin/engineer passwords"
      helm upgrade "${args[@]}" 2>"$helm_err" || rc=$?
    else
      warn "release $RELEASE exists but no revision of it ever deployed (a previous
   run died mid-install). helm cannot upgrade from that state, so its release
   records are dropped and the chart reinstalled over the live resources --
   helm adopts them in place; nothing is deleted from the cluster."
      run kubectl delete secret -n "$NAMESPACE" -l "owner=helm,name=$RELEASE" --ignore-not-found
      helm install "${args[@]}" 2>"$helm_err" || rc=$?
    fi
  else
    helm install "${args[@]}" 2>"$helm_err" || rc=$?
  fi

  # helm's stderr was captured for the check below -- replay it either way.
  if [[ -s "$helm_err" ]]; then cat "$helm_err" >&2; fi

  if (( rc != 0 )); then
    if grep -Eq 'post-(install|upgrade)' "$helm_err" && grep -q 'timed out' "$helm_err"; then
      warn "helm gave up waiting on the seed hook. The chart is fully applied and
   the seed Job is still in the cluster -- the workload wait below keeps
   watching it and reports the Job's own error if it fails. helm has recorded
   this revision as 'failed'; the next run of this script repairs that
   automatically."
    else
      die "helm failed -- see the error above"
    fi
  fi
}

# ── Wait ─────────────────────────────────────────────────────────────
# ContainerCreating for a long while just means it is still downloading; only
# ImagePullBackOff and Pending are real failures, so those are named.
wait_for_pods() {
  [[ "$DRY_RUN" == 1 ]] && return 0
  log "Waiting for workloads (up to $((POD_TIMEOUT_SECS / 60)) minutes)"

  local deadline=$(( SECONDS + POD_TIMEOUT_SECS ))
  local broken_since=0

  while (( SECONDS < deadline )); do
    # Readiness is judged on Deployments/StatefulSets, not on the pod list.
    # helm returns before the controllers have created every pod, so an
    # almost-empty pod list momentarily satisfies "every pod is Running" and
    # the wait exits seconds after the install with nothing actually up.
    # Desired-vs-ready replica counts cannot be fooled that way.
    # custom-columns, never positional fields: kubectl's default table layout
    # is not stable across versions (v1.35 inserted a STATUS column into
    # `get job`, which turns a naive $2 into "Complete" and makes a finished
    # job look permanently unfinished). Asking for the fields by path pins it.
    local pending total
    pending="$(kubectl get deploy,statefulset -n "$NAMESPACE" --no-headers \
      -o custom-columns=NAME:.metadata.name,READY:.status.readyReplicas,WANT:.spec.replicas 2>/dev/null \
      | awk '{ r = ($2 == "<none>" ? 0 : $2); w = ($3 == "<none>" ? 0 : $3); if (r != w) print $1 }' || true)"
    total="$(kubectl get deploy,statefulset -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')"

    # Jobs (the Keycloak realm seed) are not replica-shaped: done means the
    # requested number of completions succeeded. completions defaults to 1 when
    # unset, and succeeded is absent until the first pod finishes.
    local jobs_pending
    jobs_pending="$(kubectl get job -n "$NAMESPACE" --no-headers \
      -o custom-columns=NAME:.metadata.name,OK:.status.succeeded,WANT:.spec.completions 2>/dev/null \
      | awk '{ s = ($2 == "<none>" ? 0 : $2); w = ($3 == "<none>" ? 1 : $3); if (s < w) print $1 }' || true)"

    if [[ -z "$pending" && -z "$jobs_pending" && "$total" -gt 0 ]]; then
      info "all $total workloads ready"
      return 0
    fi

    # A pod that cannot pull its image will never recover on its own, but one
    # CrashLoopBackOff sighting means little -- services legitimately restart
    # a couple of times while they wait for PostgreSQL to accept connections.
    # So a fault has to PERSIST before it is treated as terminal.
    local broken
    broken="$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null \
      | grep -E 'ImagePullBackOff|ErrImagePull|CrashLoopBackOff|InvalidImageName' || true)"

    # A Job that exhausted its backoff limit is terminal RIGHT NOW -- the loop
    # would otherwise burn the whole deadline on it in silence. This is also
    # the only reliable moment to read its logs: the pod janitor sweeps dead
    # pods later, and on one live cluster that erased the seed failure's only
    # evidence.
    local failed_jobs
    failed_jobs="$(kubectl get job -n "$NAMESPACE" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Failed")].status}{"\n"}{end}' 2>/dev/null \
      | awk -F'\t' '$2 ~ /True/ { print $1 }' || true)"
    if [[ -n "$failed_jobs" ]]; then
      printf '\n'
      local j
      for j in $failed_jobs; do
        warn "job $j failed -- its last log lines:"
        kubectl logs -n "$NAMESPACE" "job/$j" --tail=25 || true
      done
      die "a Job failed permanently (backoff limit exceeded) -- the log above is the
       real error. Once the cause is fixed, re-run the seed without a full
       reinstall:
         helm get hooks $RELEASE -n $NAMESPACE \\
           | awk 'BEGIN{RS=\"---\"} /name: bdp-seed/{printf \"---%s\", \$0}' \\
           | kubectl apply -n $NAMESPACE -f -"
    fi

    if [[ -n "$broken" ]]; then
      if (( broken_since == 0 )); then
        broken_since=$SECONDS
      elif (( SECONDS - broken_since > FAULT_GRACE_SECS )); then
        printf '\n'
        printf '%s\n' "$broken" >&2
        die "pods have been failing for over $FAULT_GRACE_SECS seconds. ImagePullBackOff here
       usually means the registry credentials are wrong (401) or the nodes cannot
       reach $REGISTRY; a persistent CrashLoopBackOff needs
       'kubectl logs -n $NAMESPACE <pod> --previous'.
       See TROUBLESHOOTING in docs/SETUP-EXISTING-KUBERNETES.txt."
      fi
    else
      broken_since=0
    fi

    local n
    n="$(printf '%s\n' "$pending" "$jobs_pending" | grep -cv '^$' || true)"
    printf '\r   %s workload(s) not ready yet (%ss elapsed)...   ' \
      "${n:-0}" "$(( SECONDS ))"
    sleep 15
  done

  printf '\n'
  kubectl get deploy,statefulset -n "$NAMESPACE" 2>&1 \
    | awk 'NR==1 { print; next } { split($2, a, "/"); if (a[1] != a[2]) print }' >&2
  kubectl get pods -n "$NAMESPACE" 2>&1 | awk 'NR==1 || ($3 != "Running" && $3 != "Completed")' >&2
  die "timed out after $POD_TIMEOUT_SECS seconds. Pending pods on a small node mean the
       node is out of CPU/memory requests -- see SMALL_NODE in the config block."
}

# ── Step 5: certificate ──────────────────────────────────────────────
step5_certificate() {
  [[ "$TLS_MODE" == acme ]] || return 0
  [[ "$DRY_RUN" == 1 ]] && return 0
  log "Step 5 - TLS certificate"

  # templates/certificate.yaml names the resource {{ .Release.Name }}-tls and
  # only its secretName comes from global.tlsSecretName. The two match at the
  # defaults (release bdp -> bdp-tls) but diverge the moment either is changed,
  # so the resource name has to be derived from the release, not the secret.
  local cert="$RELEASE-tls"

  local deadline=$(( SECONDS + 600 ))
  while (( SECONDS < deadline )); do
    local ready
    ready="$(kubectl get certificate "$cert" -n "$NAMESPACE" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    if [[ "$ready" == True ]]; then
      info "certificate $cert issued into secret $TLS_SECRET -- HTTPS is live"
      return 0
    fi
    printf '\r   waiting for the ACME challenge...'
    sleep 15
  done

  printf '\n'
  # Not fatal: everything else works, and the usual cause (DNS, or solver pods
  # in ImagePullBackOff on older charts) is fixable after the fact.
  warn "certificate $cert is not Ready after 10 minutes. Almost always DNS --
   BOTH $DOMAIN and $KEYCLOAK_HOST must resolve publicly to $INGRESS_IP.
   Inspect with: kubectl get order,challenge -n $NAMESPACE
   If cm-acme-http-solver-* pods are in ImagePullBackOff, attach the pull secret:
     kubectl patch serviceaccount default -n $NAMESPACE \\
       -p '{\"imagePullSecrets\":[{\"name\":\"$PULL_SECRET\"}]}'
     kubectl delete pods -n $NAMESPACE -l acme.cert-manager.io/http01-solver=true"
}

# ── Step 5b: pod DNS ─────────────────────────────────────────────────
# Pods inherit the node's DHCP search domain, and some ISP/cloud resolvers
# answer <anything>.<that-domain> with NOERROR (empty) instead of NXDOMAIN.
# musl-based images (Alpine/Node -- the UI) treat that as final and never try
# the bare public name, so login bounces forever with error=OAuthSignin while
# the name resolves fine from the node. Catch it here, not in the browser.
step5b_pod_dns() {
  [[ "$DRY_RUN" == 1 ]] && return 0
  log "Step 5b - pod DNS"

  if ! kubectl get deploy/bdp-ui -n "$NAMESPACE" >/dev/null 2>&1; then
    warn "deploy/bdp-ui not found -- skipping the pod DNS check"
    return
  fi

  # IP MODE: there is no name to resolve, so the DNS check below is meaningless.
  # The equivalent risk is REACHABILITY. NextAuth performs its token exchange
  # server-side, from inside this pod, against the same address the browser
  # uses -- so the pod must be able to open http://<ip>/auth itself. That
  # normally works, because the address is bound on a node and the ingress
  # listens there; it does NOT work when <ip> is a NAT'd address that lives
  # nowhere in the cluster, and the hostAliases trick used in domain mode cannot
  # help (it rewrites names, and there is no name). Catch it here rather than at
  # the login screen, where it appears only as error=OAuthSignin.
  if [[ "$IP_MODE" == true ]]; then
    local scheme=https probe
    [[ "$TLS_MODE" == none ]] && scheme=http
    probe="$scheme://$DOMAIN/auth/realms/bdp/.well-known/openid-configuration"
    info "IP mode: checking the UI pod can reach $probe"

    # Whichever client the image ships. A distroless UI image has neither, in
    # which case the probe is inconclusive rather than failed.
    if kubectl exec -n "$NAMESPACE" deploy/bdp-ui -- \
         sh -c "wget -q -T 10 -O- '$probe' || curl -sfk --max-time 10 '$probe'" >/dev/null 2>&1; then
      info "pods can reach Keycloak at $DOMAIN/auth"
    elif ! kubectl exec -n "$NAMESPACE" deploy/bdp-ui -- \
           sh -c 'command -v wget >/dev/null || command -v curl >/dev/null' >/dev/null 2>&1; then
      warn "the UI image has neither wget nor curl, so pod-to-ingress reachability
   could not be verified. If login fails with error=OAuthSignin, this is the
   first thing to check:
     kubectl exec -n $NAMESPACE deploy/bdp-ui -- wget -O- $probe"
    else
      warn "the UI pod CANNOT reach $probe.
   Login will fail with error=OAuthSignin: NextAuth exchanges the token
   server-side, from inside that pod, against this exact URL.
   $DOMAIN must be reachable FROM the pod network, not just from your desk.
   Usually this means the address is NAT'd and does not exist on any node --
   re-run with BDP_DOMAIN set to an address the nodes themselves carry."
    fi
    return
  fi

  if kubectl exec -n "$NAMESPACE" deploy/bdp-ui -- getent hosts "$KEYCLOAK_HOST" >/dev/null 2>&1; then
    info "pods resolve $KEYCLOAK_HOST"
    return
  fi

  info "pods cannot resolve $KEYCLOAK_HOST -- looking for the offending search domain"
  # `|| true`: a bare assignment here would abort the whole script under
  # `set -e -o pipefail` if the exec fails (a restarting pod, or an image with
  # no `cat`) -- in a function that is otherwise deliberately fail-soft.
  local search_domain
  search_domain="$(kubectl exec -n "$NAMESPACE" deploy/bdp-ui -- cat /etc/resolv.conf 2>/dev/null \
    | awk '/^search/ { for (i = 2; i <= NF; i++) if ($i !~ /cluster\.local$/ && $i != "") { print $i; exit } }' || true)"

  if [[ -z "$search_domain" ]]; then
    warn "no non-cluster search domain found; the DNS failure is something else.
   Check egress from the pod network and the cluster's upstream resolvers."
    return
  fi

  info "patching CoreDNS to answer $search_domain authoritatively with NXDOMAIN"
  local tmp
  tmp="$(mktemp)"
  kubectl -n kube-system get configmap coredns -o yaml > "$tmp"

  if grep -q "$search_domain:53" "$tmp"; then
    info "CoreDNS already has a server block for $search_domain"
    rm -f "$tmp"
  else
    sed -i "s|^    \\.:53 {|    $search_domain:53 {\\n        errors\\n        template ANY ANY {\\n            rcode NXDOMAIN\\n        }\\n    }\\n    .:53 {|" "$tmp"
    run kubectl apply -f "$tmp"
    rm -f "$tmp"
    run kubectl -n kube-system rollout restart deploy/coredns
    run kubectl -n kube-system rollout status deploy/coredns --timeout=120s
  fi

  sleep 15
  if kubectl exec -n "$NAMESPACE" deploy/bdp-ui -- getent hosts "$KEYCLOAK_HOST" >/dev/null 2>&1; then
    info "pods now resolve $KEYCLOAK_HOST"
  else
    warn "pods still cannot resolve $KEYCLOAK_HOST. This edit lives in the coredns
   ConfigMap in kube-system, outside the bdp release -- verify it applied:
     kubectl -n kube-system get configmap coredns -o yaml"
  fi
}

# ── Step 5c: realm ───────────────────────────────────────────────────
# The seed job is what creates the Keycloak bdp realm, and it runs as a helm
# hook that a slow first boot can kill. Every workload can be green while the
# realm is missing -- the only symptom is the login page reloading forever
# with error=OAuthSignin. One request tells the truth, so ask before claiming
# success. (IP mode already fetches this exact URL in step 5b.)
step5c_realm() {
  [[ "$DRY_RUN" == 1 ]] && return 0
  [[ "$IP_MODE" == true ]] && return 0
  log "Step 5c - Keycloak realm"

  command -v curl >/dev/null || { warn "curl not found -- skipping the realm check."; return 0; }

  local scheme=https
  [[ "$TLS_MODE" == none ]] && scheme=http
  local realm_url="$scheme://$KEYCLOAK_HOST/realms/bdp/.well-known/openid-configuration"
  local code
  code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 "$realm_url" 2>/dev/null || true)"

  case "$code" in
    200)
      info "realm bdp answers at $KEYCLOAK_HOST"
      ;;
    404)
      die "Keycloak is up but the bdp realm does not exist -- the seed job never
       completed, and login will loop with error=OAuthSignin. Re-run the seed
       (it regenerates the passwords and stores them in bdp-credentials):
         helm get hooks $RELEASE -n $NAMESPACE \\
           | awk 'BEGIN{RS=\"---\"} /name: bdp-seed/{printf \"---%s\", \$0}' \\
           | kubectl apply -n $NAMESPACE -f -
         kubectl logs -n $NAMESPACE -f -l app.kubernetes.io/name=bdp-seed"
      ;;
    *)
      warn "could not fetch $realm_url from this machine (HTTP ${code:-no response})
   -- inconclusive, not fatal. If login loops with error=OAuthSignin, that URL
   returning 404 means the seed job never created the realm."
      ;;
  esac
}

# ── Step 6: credentials ──────────────────────────────────────────────
# There is no default password: the post-install seed job generates random
# ones, sets them in Keycloak and stores them in bdp-credentials.
step6_credentials() {
  [[ "$DRY_RUN" == 1 ]] && return 0
  log "Step 6 - sign-in credentials"

  if ! kubectl get secret bdp-credentials -n "$NAMESPACE" >/dev/null 2>&1; then
    warn "secret bdp-credentials is missing -- the seed job failed after resetting the
   Keycloak passwords, so the generated ones are lost. Find the cause:
     kubectl logs -n $NAMESPACE job/\$(kubectl get job -n $NAMESPACE -o name | grep seed | head -1 | cut -d/ -f2)
   then re-run the seed, which regenerates and stores fresh passwords:
     helm get hooks $RELEASE -n $NAMESPACE \\
       | awk 'BEGIN{RS=\"---\"} /name: bdp-seed/{printf \"---%s\", \$0}' \\
       | kubectl apply -n $NAMESPACE -f -
   (a plain 'helm upgrade --reuse-values' also re-runs it, but is refused with
   'has no deployed releases' when the install itself failed -- re-running this
   script repairs that state automatically)"
    return
  fi

  local scheme=https
  [[ "$TLS_MODE" == none ]] && scheme=http
  PLATFORM_URL="$scheme://$DOMAIN"

  # Kept in globals so step 6b can mail them without re-reading the secret.
  ADMIN_PASSWORD="$(kubectl get secret bdp-credentials -n "$NAMESPACE" -o jsonpath='{.data.admin-password}' | base64 -d)"
  ENGINEER_PASSWORD="$(kubectl get secret bdp-credentials -n "$NAMESPACE" -o jsonpath='{.data.engineer-password}' | base64 -d)"

  printf '\n'
  printf '   URL       %s\n' "$PLATFORM_URL"
  printf '   admin     %s\n' "$ADMIN_PASSWORD"
  printf '   engineer  %s\n' "$ENGINEER_PASSWORD"
  printf '\n'
  info "The Keycloak admin-console superuser is separate: user admin, password in"
  info "secret bdp-keycloak, key admin-password."
  warn "EVERY helm upgrade re-runs the seed and ROTATES these two passwords."
}

# ── Step 6b: email the sign-in details ───────────────────────────────
# Entirely optional and ALWAYS fail-soft: the platform is already up and
# verified by the time this runs, so a mail problem must never turn a good
# install into a failed one. Every failure path here warns and returns 0.
step6b_notify() {
  [[ "$DRY_RUN" == 1 ]] && return 0
  [[ -n "$NOTIFY_EMAIL" ]] || return 0
  log "Step 6b - emailing the sign-in details"

  if [[ -z "$MAIL_USER" || -z "$MAIL_PASSWORD" ]]; then
    warn "NOTIFY_EMAIL is set but MAIL_USER/MAIL_PASSWORD are not -- skipping the email."
    return 0
  fi
  if [[ -z "${ADMIN_PASSWORD:-}" ]]; then
    warn "no credentials to send (bdp-credentials was missing) -- skipping the email."
    return 0
  fi
  command -v curl >/dev/null || { warn "curl not found -- skipping the email."; return 0; }

  # umask BEFORE mktemp: the config file holds the relay password, and passing
  # it via --user would expose it in the node's process list to every user.
  umask 077
  local cfg msg
  cfg="$(mktemp)" || { warn "mktemp failed -- skipping the email."; return 0; }
  msg="$(mktemp)" || { rm -f "$cfg"; warn "mktemp failed -- skipping the email."; return 0; }

  printf 'user = "%s:%s"\n' "$MAIL_USER" "$MAIL_PASSWORD" > "$cfg"

  local body
  if [[ "$NOTIFY_INCLUDE_PASSWORDS" == true ]]; then
    body="Sign in at $PLATFORM_URL

  admin     $ADMIN_PASSWORD
  engineer  $ENGINEER_PASSWORD

Change both passwords after your first sign-in. Note that every platform
upgrade regenerates them, so these stop working once an upgrade runs."
  else
    body="Your BDP platform is ready at $PLATFORM_URL

The sign-in passwords were generated during installation and stored in the
cluster. An operator with cluster access can read them with:

  kubectl get secret bdp-credentials -n $NAMESPACE -o jsonpath='{.data.admin-password}' | base64 -d"
  fi

  cat > "$msg" <<EOM
From: BDP Platform <$MAIL_FROM>
To: <$NOTIFY_EMAIL>
Subject: Your BDP platform is ready - $DOMAIN
Date: $(date -R)
Message-ID: <bdp-install-$(date +%s)@${DOMAIN}>
Content-Type: text/plain; charset=utf-8

$body

--
Installed $(date -u '+%Y-%m-%d %H:%M UTC') on $(hostname).
EOM

  if curl -sS -K "$cfg" --url "smtp://$MAIL_HOST:$MAIL_PORT" --ssl-reqd \
       --mail-from "$MAIL_FROM" --mail-rcpt "$NOTIFY_EMAIL" \
       --upload-file "$msg" --max-time 60 >/dev/null 2>&1; then
    info "sent to $NOTIFY_EMAIL via $MAIL_HOST"
    # A bare `[[ ]] && info` here would return 1 when false, and under set -e
    # that aborts the function before the relay password is shredded below.
    if [[ "$NOTIFY_INCLUDE_PASSWORDS" == true ]]; then
      info "the message contains live passwords -- it is as sensitive as the secret"
    fi
  else
    warn "could not send to $NOTIFY_EMAIL via $MAIL_HOST:$MAIL_PORT.
   The install itself is fine -- the credentials are above and in the
   bdp-credentials secret. Re-check MAIL_USER/MAIL_PASSWORD and that the
   node can reach the relay on port $MAIL_PORT."
  fi

  # The relay password must not outlive the send.
  shred -u "$cfg" 2>/dev/null || rm -f "$cfg"
  rm -f "$msg"
  return 0
}

# ── Done ─────────────────────────────────────────────────────────────
next_steps() {
  [[ "$DRY_RUN" == 1 ]] && { log "Dry run complete -- nothing was installed"; return; }
  log "Setup complete"

  cat <<EOF
   ACTIVATE THE LICENSE (step 7). Dashboard -> License -> Activate
   License: upload or paste your signed license.key, click Activate.
   Until then billing.mode=$BILLING_MODE blocks provisioning of data tools.
EOF

  if [[ "$IP_MODE" == true ]]; then
    cat <<EOF

   TOOL UIs ARE ON NODEPORTS. Because there is no DNS, each tool you install
   is published as http://$DOMAIN:<nodeport> rather than a subdomain; the
   Dashboard shows the exact port per tool. Those ports must be open on the
   node for anyone who needs to reach them, and they are plain HTTP.
EOF
  else
    cat <<EOF

   TLS FOR PROVISIONED TOOL UIs (step 8b). Tool ingresses are currently
   created without a certificate, so spark.$DOMAIN and friends show
   "connection is not private". The one-time issuer setup and the
   patch-all-tools loop are in docs/SETUP-EXISTING-KUBERNETES.txt --
   that loop runs after every tool install, not once, which is why it is
   not part of setup.
EOF
  fi

  cat <<EOF

   Health check:  kubectl get pods -n $NAMESPACE
   Troubleshooting: docs/SETUP-EXISTING-KUBERNETES.txt
EOF
}

main() {
  preflight
  step0_untaint
  step1_storage
  step2_ingress
  step3_dns
  step4a_registry
  step4b_crds
  step4c_install
  wait_for_pods
  step5_certificate
  step5b_pod_dns
  step5c_realm
  step6_credentials
  step6b_notify
  next_steps
}

main "$@"
