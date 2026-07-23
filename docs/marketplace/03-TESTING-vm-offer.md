# Manual Testing Guide — BDP VM Offer

_How to deploy and validate the VM image yourself, step by step. Last updated: 2026-07-23._

> All build/deploy commands run on the **remote build host / Azure**, not your local machine.

---

## Prerequisites
- Azure subscription (`f0d65415-751b-4673-bdb7-8482fd8a5f34`) and `az login`.
- The published **1.0.2** image in a Shared Image Gallery (SIG), OR the Packer template to build it.
- A DNS name you can point at the VM (optional but needed for real TLS).

---

## Approach A — Test the already-published SIG image (fastest)

### Step 1 — Create a VM from the SIG image
```bash
az vm create \
  --resource-group bdp-vm-test \
  --name bdp-vm-smoke \
  --image "/subscriptions/<sub>/resourceGroups/<sig-rg>/providers/Microsoft.Compute/galleries/<gallery>/images/bdp/versions/1.0.2" \
  --size Standard_D4s_v5 \
  --admin-username azureuser \
  --generate-ssh-keys \
  --public-ip-sku Standard
```
> Size guidance: **D4s_v5 (4 vCPU / 16 GB) minimum** — BDP + k3s + a couple of tools need headroom.

### Step 2 — Open ports
```bash
az vm open-port -g bdp-vm-test -n bdp-vm-smoke --port 80  --priority 900
az vm open-port -g bdp-vm-test -n bdp-vm-smoke --port 443 --priority 901
```

### Step 3 — (Optional) point DNS at the VM
Create an A record `bdp.<yourdomain>` → the VM public IP. If you skip this, use the raw IP / sslip.io; Caddy TLS needs a real domain to issue a Let's Encrypt cert (otherwise it self-signs).

### Step 4 — Wait for first boot to finish
First boot runs `bdp-first-boot.sh` (IMDS IP detect, Caddy TLS, kubeconfig perms, PM2 start). Give it **3–5 minutes**, then SSH in and check:
```bash
ssh azureuser@<vm-ip>
pm2 status                     # all BDP services 'online'
sudo systemctl status caddy    # active
sudo k3s kubectl get nodes     # Ready
```

### Step 5 — Access the UI
Open `https://bdp.<yourdomain>` (or `https://<vm-ip>` with a cert warning).
- Log in with the admin credentials (set in the image / first-boot output — check `sudo cat /var/log/bdp-first-boot.log` for the generated admin password if not preset).

### Step 6 — Functional checks
1. **Dashboard loads** — no 500s in the browser console.
2. **Deployment targets** — a "Local" target (the embedded k3s) is present and ACTIVE.
3. **Install a tool** — Services → install **MinIO** or **Spark**; watch it reach RUNNING.
4. **SSO** — open the installed tool's UI; log in via Keycloak (no "Insufficient Permissions").
5. **Tool UI access** — the tool URL opens (NodePort on the VM host — `http://<vm-ip>:<nodePort>`).

### Step 7 — Tear down (STOP BILLING)
```bash
az group delete -n bdp-vm-test --yes --no-wait
```

---

## Approach B — Build the image yourself with Packer (on the remote build host)

### Stage 1 — Prepare
```bash
cd bdp-marketplace-vm
# ensure Packer + Azure plugin installed; az login done
```

### Stage 2 — Build
```bash
packer init .
packer build \
  -var "subscription_id=f0d65415-751b-4673-bdb7-8482fd8a5f34" \
  -var "image_version=1.0.3" \
  azure-vm.pkr.hcl
```
This runs `provision/10-runtime.sh` (Caddy, k3s `--disable traefik servicelb`, PM2, JDK 21) and bakes the artifact.

### Stage 3 — Publish to SIG
Packer publishes the image version into the gallery (per the template's `shared_image_gallery_destination`). Confirm:
```bash
az sig image-version list --gallery-name <gallery> --gallery-image-definition bdp -o table
```

### Stage 4 — Launch + validate
Follow **Approach A, Steps 1–7** with the new version.

---

## Common issues checklist
| Symptom | Cause | Fix |
|---------|-------|-----|
| No HTTPS / cert error | No real domain → Caddy self-signs | Point DNS at the VM, reboot or `sudo systemctl restart caddy` |
| Port 80/443 refused | k3s grabbed them | Confirm k3s started with `--disable traefik servicelb`; only 1.0.2+ has this |
| Login redirects fail | NextAuth env not set | Check first-boot log; NEXTAUTH_URL must match the domain |
| Tool "Insufficient Permissions" | Old image without SSO fixes | Use 1.0.2+ |

---

## Sign-off checklist (VM offer ready to ship)
- [ ] VM boots and all PM2 services online
- [ ] HTTPS with valid cert (real domain)
- [ ] Login works
- [ ] At least one tool installs and reaches RUNNING
- [ ] Tool SSO works
- [ ] Smoke VM deleted after testing

➡️ When testing passes, finish the listing with `05-MARKETPLACE-REMAINING-vm-offer.md`.
