# Security Policy

## Supported scope

This repository contains a local integration layer and operator tooling. Security reports are welcome for:

- token handling in startup and verification scripts
- MCP request/response handling in `capability-hub/src/`
- unsafe logging, path exposure, or accidental credential disclosure
- public-repo packaging mistakes that leak local environment data

## Reporting

Please report vulnerabilities privately to the maintainer instead of opening a public issue with exploit details.

When reporting:

- describe the affected file or workflow
- include reproduction steps
- include impact and suggested mitigation if known

## Sensitive material that must never be committed

- gateway tokens
- tokenized Control UI or dashboard URLs
- machine-local config snapshots
- raw runtime logs and state files
- personal filesystem paths if they are not required for generic documentation

If you believe sensitive data was committed, rotate the secret first, then report the incident.
