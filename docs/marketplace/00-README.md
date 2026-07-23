# BDP Azure Marketplace — Documentation Set

Two offers, three document types each. Read in order per offer.

| # | Document | Offer | Purpose |
|---|----------|-------|---------|
| 01 | [What's Been Done — VM](01-DONE-vm-offer.md) | VM | Everything built + validated so far |
| 02 | [What's Been Done — K8s](02-DONE-k8s-offer.md) | Kubernetes | Everything built + validated so far |
| 03 | [Manual Testing — VM](03-TESTING-vm-offer.md) | VM | Deploy + validate the VM image yourself |
| 04 | [Manual Testing — K8s](04-TESTING-k8s-offer.md) | Kubernetes | Deploy + validate the Helm chart yourself |
| 05 | [Marketplace Remaining — VM](05-MARKETPLACE-REMAINING-vm-offer.md) | VM | Partner Center steps left to publish |
| 06 | [Marketplace Remaining — K8s](06-MARKETPLACE-REMAINING-k8s-offer.md) | Kubernetes | CNAB + Partner Center steps left to publish |

## Suggested path
- **Catch up:** 01 + 02.
- **Test yourself:** 03 (VM) and/or 04 (K8s).
- **Ship:** 05 (VM) and/or 06 (K8s).

## Key facts
- **VM offer** = whole platform on one VM (PM2 + embedded k3s). Image **1.0.2** published to SIG.
- **K8s offer** = microservices on managed K8s (AKS) via Helm chart `bdp-marketplace-k8s/charts/bdp`, air-gapped through ACR `bdpmarketplace`.
- **All image builds/tests run on the remote build host / Azure — not locally.**
- Live AKS test cluster: `bdp-airgap` in RG `bdp-airgap-test` (bills hourly — delete when done). ACR is separate (`bdp-marketplace-images`) and stays.
- Repos: `bdp-platform` (bdp-V3), `bdp-ui` (bdp-ui-V3), `bdp-marketplace-k8s`, `bdp-marketplace-vm`.
