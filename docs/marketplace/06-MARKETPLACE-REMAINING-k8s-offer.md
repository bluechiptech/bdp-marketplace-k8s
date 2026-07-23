# Azure Marketplace — Remaining Steps: Kubernetes Offer

_What is left to publish the BDP Kubernetes offer on Azure Marketplace, stage by stage. Last updated: 2026-07-23._

> Done already: umbrella Helm chart complete + validated, ACR air-gap (charts + images), live AKS deploy working, all 7 deploy bugs fixed and baked into the chart. This doc covers the **packaging + Partner Center** work that remains.

---

## Decide the offer type first
Azure has two relevant paths for a Kubernetes app. Pick one:

| Path | What it is | Best when |
|------|------------|-----------|
| **Azure Container offer (CNAB via `cpa`)** | A CNAB bundle referencing the Helm chart + images, deployed to the customer's AKS from Marketplace | You want a true Marketplace "Kubernetes application" |
| **Azure Application (Managed App)** | An ARM template that provisions AKS + installs the chart | You want to also provision the cluster |

The work below assumes the **Azure Container / Kubernetes-application (CNAB)** path, which was already started.

---

## Stage 0 — Finish the images (blocking, do on the remote build host)
Before packaging, rebuild + push the two images that carry the latest fixes (WebSocket, logout, tool-UI ingress), then confirm the chart references that tag:
```bash
# on the remote build host (Docker + source + az)
az acr login -n bdpmarketplace
cd bdp-marketplace-k8s
images/build-all.sh bdpmarketplace.azurecr.io/bdp 1.0.1     # or just ui + service-manager
# set global.bdpImageTag=1.0.1 in the chart/bundle values
```

## Stage 1 — Resolve the CNAB blocker (3 Bitnami subcharts)
The `cpa` (Container Package for Azure) tool requires **every** image to be listed in `global.azure.images` with a digest. Three Bitnami **subchart** images (postgresql, redis, keycloak) were rejected because their images aren't surfaced there.

**Options:**
1. Add each subchart image to `global.azure.images` with its pinned digest (from the ACR `tools/*` mirror), and template the subcharts' `image.registry/repository/tag` from those entries.
2. Or replace the Bitnami subcharts with your own thin charts whose images you fully control.

Verify with:
```bash
cpa verify --chart charts/bdp
```

## Stage 2 — Build the CNAB bundle
```bash
cpa buildbundle \
  --chart charts/bdp \
  --registry bdpmarketplace.azurecr.io \
  --output ./bundle
```
This produces the CNAB bundle and pushes referenced artifacts to the ACR. Confirm the bundle lists all images with digests.

## Stage 3 — Create the offer in Partner Center
1. Partner Center → **+ New offer** → **Azure Container** (Kubernetes application).
2. Offer ID `bdp-platform-k8s`, alias "Bluechip Data Platform (Kubernetes)".
3. **Plan → Technical configuration**: reference the **CNAB bundle** in the ACR (Partner Center pulls it).
4. Provide the **cluster extension** parameters (the Helm values the customer sets: `externalDomain`, `airgapRegistry`, `ingressClassName`, TLS secret, etc.) with sensible defaults + descriptions.

## Stage 4 — Offer properties + listing
Same as the VM offer:
1. Categories (Analytics, Databases, Developer Tools).
2. Legal (Terms + **Privacy Policy URL**).
3. Listing: name, descriptions, logo, screenshots.
4. Support + contacts.

## Stage 5 — Parameters / UI definition
Kubernetes-app offers expose a **createUiDefinition** so the customer supplies values in the portal:
- `externalDomain`, `ingressClassName`, `airgapRegistry`, `tlsSecretName`, admin email, node sizing hints.
- Mark required vs optional; provide defaults matching the chart.

## Stage 6 — Preview audience
Add your subscription(s) for private preview validation.

## Stage 7 — Validate in Preview
1. From the Marketplace **Preview** link, deploy the Kubernetes app onto a **test AKS** (ideally through the Marketplace flow, not raw helm).
2. Run `04-TESTING-k8s-offer.md` end-to-end.
3. Confirm the **air-gap** path works from the customer ACR with no public pulls.

## Stage 8 — Certification + Go Live
1. Partner Center runs certification (bundle scan, chart lint, image checks).
2. Fix findings (common: image without digest, missing UI-definition field, privacy URL).
3. Pass → **Go Live** → public listing.

---

## Remaining checklist
- [ ] Rebuild + push UI + service-manager images (remote host), bump `bdpImageTag`
- [ ] Real wildcard TLS (cert-manager) documented/wired for production
- [ ] Resolve 3 Bitnami subchart images in `global.azure.images`
- [ ] `cpa verify` passes
- [ ] `cpa buildbundle` produces a clean CNAB bundle in ACR
- [ ] Create the Azure Container offer in Partner Center
- [ ] createUiDefinition for customer parameters
- [ ] Offer properties + listing assets + legal/privacy
- [ ] Preview audience set
- [ ] Validate in Preview via the Marketplace deploy flow
- [ ] Pass certification → Go Live

## Known gotchas
| Gotcha | Mitigation |
|--------|-----------|
| `cpa` rejects subchart images | List every image (incl. subcharts) in `global.azure.images` with digests |
| Nodes can't pull from ACR | Customer AKS must be `--attach-acr` or given a pull secret; document it |
| LB doesn't hairpin (login fails) | Expose `keycloakHostAliasIp` param, or require cert-manager + real DNS |
| Tool UIs need wildcard DNS | Document `*.<domain>` → ingress LB requirement (sslip.io works for tests) |
| Self-signed cert warnings | Require `tlsSecretName` (cert-manager) for production; `insecureSkipTlsVerify` is testing-only |

➡️ Companion: the VM offer's remaining steps are in `05-MARKETPLACE-REMAINING-vm-offer.md`.
