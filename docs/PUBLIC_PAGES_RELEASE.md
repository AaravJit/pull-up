# Public pages: integration and release gates

Added October 24, 2026. These pages support the initial free release. They do not establish that production configuration, moderation, rights, age controls, or provider contracts have been verified.

Public GitHub-rendered URLs after merge:

- Marketing: `https://github.com/AaravJit/pull-up/blob/main/docs/public/index.md`
- Privacy: `https://github.com/AaravJit/pull-up/blob/main/docs/public/privacy.md`
- Support: `https://github.com/AaravJit/pull-up/blob/main/docs/public/support.md`
- Community rules: `https://github.com/AaravJit/pull-up/blob/main/docs/public/community.md`
- Service/content terms: `https://github.com/AaravJit/pull-up/blob/main/docs/public/terms.md`

Use the rendered HTML GitHub pages, not raw Markdown download URLs. No purchased domain, new hosting service, or GitHub Pages configuration is required. Public issue reporting is an interim general contact route. **Obtain an owner-approved public support email before calling the support setup complete**; Apple's support metadata expects actual contact information. Do not publish the Apple Account login email or personal phone without explicit approval for that public use. Do not request private data in issues.

## App configuration

Set these in the production GitHub environment / Secrets.xcconfig **without** `https://`:

```
PULLUP_PRIVACY_POLICY = github.com/AaravJit/pull-up/blob/main/docs/public/privacy.md
PULLUP_SUPPORT_URL = github.com/AaravJit/pull-up/blob/main/docs/public/support.md
```

The existing app appends the HTTPS scheme. App Store Connect itself needs the complete HTTPS URLs. The pages must also be linked appropriately from onboarding/content submission, not just Settings. The content license is not proof users accepted it: implement an appropriate disclosed acceptance flow, version it, and enforce community rules before claiming content-rights readiness.

## Reconcile before submission

1. Confirm public support contact and operational report ownership; add monitored private contact for privacy/security/account requests.
2. Review provider contracts, subprocessors, processing regions, logging, backup retention and deletion. The policy intentionally does not invent a backup-erasure deadline. Verify safeguards support Apple's privacy-policy requirements.
3. Resolve the account-deletion pagination finding; test large-account cleanup. Configure and verify Apple token revocation.
4. Configure and verify retention cron before relying on the described scheduled cleanup. Reconcile any retained abuse/legal records with the actual deletion implementation.
5. Resolve the moderation filtering/monitoring gaps. Public rules alone do not implement moderation.
6. Decide and enforce the service's minimum age and applicable regional controls. A store rating of 13+ alone does not block underage access; the policy does not claim otherwise.
7. Reconcile privacy answers, manifest, page facts and all new Claude features with the submitted binary. Pro/affiliate links/Game Center/analytics changes require re-review.
8. Verify every public page signed out and test every link. Update contact and service wording before release if operational facts differ.

These are launch preparation documents, not a legal opinion, evidence of accepted user terms, proof of Apple approval, or permission to certify rights that have not been obtained. Account-holder agreements and trader declarations remain the owner's responsibility.
