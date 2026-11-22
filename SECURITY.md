# Security policy

## Reporting a vulnerability

Report vulnerabilities privately through GitHub's **Report a vulnerability** flow on the repository Security tab. Do not open a public issue or include secrets, Temporary Access Pass values, tenant identifiers that are not already public, emergency-account details, recovery codes, webhook URLs, or deployment output containing secrets.

If private reporting is unavailable, contact the maintainer privately through the GitHub profile and include only the minimum detail needed to establish contact. Include the affected deployment mode, reproducible behavior, and suggested mitigation when available.

Treat an exposed password, Temporary Access Pass, Function key, or storage key as compromised and rotate or revoke it before submitting a report.

## Supported versions

This repository supports the current `main` branch and the latest published release, `v1.0.0`, for security fixes. Security fixes are prioritized for `main` and the next release. Older releases do not receive security backports unless this section explicitly lists them.

## Response targets

The sole maintainer aims to acknowledge a private report within 7 calendar days and provide an initial triage or next-steps decision within 14 calendar days. These are targets, not a guarantee of emergency staffing, an emergency response channel, or remediation time.

## Safe disclosure

Keep vulnerability details private until impact has been assessed and a fix, mitigation, or coordinated-disclosure decision is available. Share only the minimum reproduction detail needed through the private reporting channel and coordinate a public disclosure timeline with the maintainer. Do not publish credentials, signing or recovery material, tenant-specific values, emergency-account details, user or device data, callback URLs, connection strings, or sensitive deployment output in issues, pull requests, examples, or release bundles. This policy is not an emergency access channel.
