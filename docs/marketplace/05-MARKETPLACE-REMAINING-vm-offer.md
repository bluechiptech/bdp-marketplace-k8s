# Azure Marketplace — Remaining Steps: VM Offer

_What is left to publish the BDP VM offer on Azure Marketplace, stage by stage. Last updated: 2026-07-23._

> Done already: image 1.0.2 built, published to SIG, smoke-tested. This doc covers the **Partner Center listing** work that remains.

---

## Prerequisites (you have these)
- Microsoft **Partner Center** account with the **Commercial Marketplace** program enrolled.
- Azure subscription `f0d65415-751b-4673-bdb7-8482fd8a5f34`.
- The **1.0.2 image version** in a Shared Image Gallery (SIG).

---

## Stage 1 — Create the offer
1. Partner Center → **Marketplace offers** → **+ New offer** → **Azure Virtual Machine**.
2. Offer ID: `bdp-platform-vm` (internal, permanent). Offer alias: "Bluechip Data Platform (VM)".
3. Setup details: sell **through Microsoft** (transactable) or **free/BYOL** — pick your billing model.

## Stage 2 — Offer properties
1. **Categories**: Analytics, Databases, Developer Tools.
2. **Legal**: attach your **Terms of Use** + **Privacy Policy URL** (required).
3. Industries / app version.

## Stage 3 — Offer listing (marketing)
1. Name, search summary, short + long description.
2. **Marketing assets**: logo (216×216, 48×48, 90×90), at least 1 screenshot (1280×720), optional video.
3. Support + contact info (support URL, engineering + support contacts).
4. Privacy policy link.

## Stage 4 — Preview audience
Add the Azure **subscription IDs** (or a tenant) that may see the offer before it goes public — include your own for validation.

## Stage 5 — Plans (technical configuration) — the core VM work
1. **+ Create new plan** → Plan ID `byol` or `standard`, plan name.
2. **Plan setup**: Azure regions, is it hidden, etc.
3. **Pricing and availability**: per-core-hour / flat / BYOL. Set the price or "free/BYOL".
4. **Technical configuration** (the important part):
   - **Operating system**: Linux (the base of your image).
   - **Image source**: point to the **SIG image version 1.0.2** (Partner Center imports from your gallery — the image must be in the **same subscription/tenant** and generalized).
   - **VM generation**: Gen 2 (match how the image was built).
   - Recommended VM sizes: **D4s_v5+**.
   - **Ports/pricing per SKU** as needed.
5. Add any **custom data / cloud-init** notes the customer must supply (e.g. the domain for TLS).

> ⚠️ The image must be **generalized** (deprovisioned with `waagent -deprovision`) and captured properly, or certification fails. Verify the 1.0.2 SIG version is generalized.

## Stage 6 — Co-sell / resell (optional)
Skip unless you want Microsoft co-sell.

## Stage 7 — Review and publish
1. **Review and publish** → Partner Center runs **automated certification** (image scan, malware, VM boot test).
2. Fix any certification findings (common: image not generalized, missing privacy URL, boot timeout).
3. Once certification passes, the offer enters **Preview** — validate with your preview audience (deploy from the Marketplace preview link, run `03-TESTING-vm-offer.md`).
4. **Go Live** → Microsoft final review → public listing (can take a few days).

---

## Remaining checklist
- [ ] Create the VM offer in Partner Center
- [ ] Offer properties (categories, legal, privacy URL)
- [ ] Listing assets (logo, screenshots, descriptions)
- [ ] Preview audience (your subscription)
- [ ] Plan + technical config pointing at SIG image 1.0.2 (Gen2, generalized)
- [ ] Pricing model set
- [ ] Pass automated certification
- [ ] Validate in Preview (deploy from Marketplace, run the test guide)
- [ ] Go Live

## Known gotchas
| Gotcha | Mitigation |
|--------|-----------|
| Image not generalized | Re-capture with deprovision; Packer template should handle this |
| Certification VM won't boot | Ensure first-boot script is idempotent and doesn't require custom data to boot |
| TLS needs a domain | Document in the listing that the customer supplies a domain via custom data |
| Missing legal/privacy URLs | Prepare these before Stage 2 |

➡️ Companion: the Kubernetes offer's remaining steps are in `06-MARKETPLACE-REMAINING-k8s-offer.md`.
