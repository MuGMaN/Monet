# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 1.x.x   | :white_check_mark: |

## Security Practices

Monet is designed with security in mind:

- **Credential Storage** — All tokens are stored in macOS Keychain, never in plain text
- **OAuth 2.0 + PKCE** — Industry-standard authentication with Proof Key for Code Exchange
- **No Telemetry** — No usage data or analytics collected
- **HTTPS Only** — All API communication uses TLS encryption
- **Minimal Permissions** — Only requests necessary entitlements

## Reporting a Vulnerability

If you discover a security vulnerability:

1. **Do NOT** open a public issue
2. Email the maintainer directly or use GitHub's private vulnerability reporting
3. Include:
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if any)

We will respond within 48 hours and work to address the issue promptly.

## Disclosure Policy

- We will acknowledge receipt of your report
- We will investigate and keep you informed of progress
- Once fixed, we will credit you in the release notes (unless you prefer anonymity)
