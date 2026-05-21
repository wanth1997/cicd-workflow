# Public Repository Policy

> Status: active policy
>
> Last updated: 2026-05-22

This repository is public. Assume every committed file can be read by anyone.

## Allowed

- reusable GitHub Actions workflow YAML
- generic helper scripts
- placeholder service manifests
- documentation for workflow inputs and outputs
- fake examples that use non-real domains, fake service names, and fake secret
  names
- secret names, when needed to document a contract

## Not Allowed

- GitHub secret values
- `.env` files or copied server environment files
- SSH private keys
- deploy user credentials
- real database URLs
- API keys, payment keys, LINE tokens, Telegram bot tokens, or webhook URLs
- staging or production logs
- customer data
- real private server inventory
- copied runtime configuration from a service host

## Review Checklist

Before pushing:

1. Run `git status --short` and check every staged file.
2. Search for obvious secret patterns.
3. Confirm examples use fake values.
4. Confirm service-specific runtime values are placeholders or intentionally
   public.
5. Keep secret values in the consuming service repository's GitHub
   Environments, not here.

Suggested local scan:

```bash
rg -n "BEGIN .*PRIVATE KEY|DATABASE_URL=|SECRET|TOKEN|PASSWORD|WEBHOOK|ssh-rsa|ssh-ed25519" .
```
