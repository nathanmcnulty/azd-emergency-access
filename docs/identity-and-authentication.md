# Identity and authentication

[Back to the quickstart](../README.md)

## Identity choices

The first-run wizard offers three paths:

1. **Create two accounts.** The template creates two cloud-only users, a security group, permanent Global Administrator assignments, and a restricted management administrative unit by default.
2. **Use existing accounts.** The template resolves the supplied UPNs or object IDs, ensures group membership and Global Administrator, and can create the group when it is missing.
3. **Use externally managed accounts.** The template requires exact object IDs and does not modify users, group membership, directory roles, administrative units, or TAP configuration.

The deployment records exact ownership IDs for objects it creates. It refuses to replace an owned privileged object until the original is explicitly cleaned up.

## Required administrator access

The deploying administrator normally needs:

- Azure subscription Contributor plus User Access Administrator, or Owner;
- Global Administrator or Privileged Role Administrator for the emergency-account role assignments;
- permission to grant the delegated Microsoft Graph scopes requested for the selected capabilities;
- access to the existing Log Analytics or Sentinel workspace when alerting is selected.

Activate eligible roles before `azd up`. Azure RBAC does not grant Microsoft Entra or Microsoft Graph privileges.

## Microsoft Graph authentication

Install the authentication module once:

```powershell
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
```

The first tenant phase calls standard `Connect-MgGraph` once with the complete scope set required by the wizard choices. Windows Account Manager, the current token cache, or a normal browser performs authentication. Later phases use `Connect-MgGraph -NoWelcome` and the same cached context.

If consent is missing, the deployment stops with the missing scopes instead of launching several new prompts. Device-code authentication, client secrets, and Azure CLI Graph tokens are not used.

Runtime workloads use managed identity with `Policy.Read.All`, `Policy.ReadWrite.ConditionalAccess`, and `Application.Read.All`. `Application.Read.All` is included because Conditional Access PATCH currently requires that application permission in addition to the policy permissions.

## Password handling

Microsoft Graph requires an initial password when a user is created. The template generates a cryptographically random value and immediately discards it. It is never printed, returned, stored in azd, written to disk, or placed in Key Vault.

The generated password cannot be recovered. Use TAP onboarding or your approved authentication-method process.

## TAP and passkeys

The wizard recommends TAP when the template manages the identities. When selected, it:

1. Merges the emergency group into the existing TAP policy targets without replacing other targets.
2. Creates one reusable two-hour TAP per account.
3. Displays each TAP once in the interactive terminal.

Immediately register at least two passkeys per account and test both. TAP values are not generated in noninteractive runs because they cannot be delivered safely.

If TAP configuration receives HTTP 403, core deployment remains valid. Complete TAP and passkey registration manually after granting the necessary authentication-method permissions.

## Security boundaries

- A restricted management administrative unit reduces routine administrative exposure, but Global Administrators can still manage restricted objects.
- Conditional Access exclusion preserves recoverability but bypasses the protections represented by those policies.
- Keep accounts cloud-only and separate their credentials, passkeys, devices, and custodians from normal administration.
- Treat every sign-in attempt, successful or failed, as security-relevant.
- Exercise the complete emergency procedure regularly; successful deployment alone does not prove recoverability.
