# Security

## Reporting Vulnerabilities

If you discover a security vulnerability, **do not open a public issue.** Instead, email security concerns to the repository owner directly via GitHub (profile contact) or open a [private security advisory](https://github.com/duh17/oppi/security/advisories/new).

I take security seriously and will respond as quickly as possible.

## Architecture

Oppi is a self-hosted system — your code and credentials never leave your machine. The iOS app connects to your server over your local network or VPN.

### Threat Model

The primary threat is a **prompt injection attack** — a malicious instruction hidden in a file, webpage, or tool output that tricks the coding agent into executing unintended commands.

Oppi defends against this with layered controls:

1. **Permission gate** — Every tool call is evaluated against a policy engine before execution. Dangerous operations (writes, deletes, network access, installs) require explicit phone approval. The gate is **fail-closed**: if the phone is unreachable, risky operations are denied.

2. **Hard denies** — Immutable rules block the most dangerous operations regardless of user policy:
   - `rm -rf /`, `rm -rf ~`, `rm -rf /*`
   - Modifying system files (`/etc/`, `/System/`, `/Library/`)
   - Raw socket tools (`nc`, `ncat`, `socat`, `telnet`)
   - Pipe-to-shell patterns (`curl | sh`, etc.)
   - Command substitution probing for secrets

3. **Container isolation** — Apple container sandbox for untrusted work. The agent can only access mounted workspace directories and has no access to the host filesystem, network services, or other processes.

4. **Credential isolation** — API keys never enter containers. An auth proxy on the host injects real credentials into outbound LLM API requests, so the agent process never sees them.

5. **Signed pairing** — Ed25519 signed, time-limited, single-use pairing envelopes. No shared passwords.

6. **Timing-safe auth** — Bearer token comparison uses `timingSafeEqual`.

### Known Residual Risks

No defense against prompt injection is perfect. The detailed residual risk analysis is in [`server/docs/security-prompt-injection-residual-risk.md`](server/docs/security-prompt-injection-residual-risk.md).

Key residual risks:
- Agent could craft commands that are individually benign but dangerous in sequence
- Data exfiltration via DNS, steganography, or other covert channels in host mode
- Social engineering the user into approving dangerous operations

**Host mode** trusts the agent more than container mode. Use container mode for untrusted or experimental work.

### Privacy

- No user accounts or personal data collected
- No analytics or telemetry — the server has zero phone-home behavior
- Sentry crash reporting on iOS is opt-in (disabled by default, requires explicit DSN configuration)
- All data stays on your machine
- See [`ios/Oppi/Resources/PrivacyInfo.xcprivacy`](ios/Oppi/Resources/PrivacyInfo.xcprivacy) for the Apple Privacy Manifest

## Security Design Documents

- [Policy engine design](server/docs/policy-engine-v2.md)
- [Prompt injection residual risk analysis](server/docs/security-prompt-injection-residual-risk.md)
