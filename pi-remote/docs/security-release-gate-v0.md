# P0 Security Test Matrix + Release Gate (v0)

Date: 2026-02-11  
Owner: pi-remote / iOS security track (`TODO-82b0c933`)

## Scope

Release-gate evidence for bootstrap trust, transport policy, auth/log/push data handling,
and adversarial bypass paths for Pi Remote v0.

## Trust boundaries

| Boundary | Description |
|---|---|
| B1 Bootstrap invite | QR/onboarding payload from server to phone (signed `v2` invite only) |
| B2 Server identity | `/security/profile` + pinned fingerprint continuity |
| B3 Transport channel | HTTP/WS policy by host class (tailnet/local/public) |
| B4 Approval/policy gate | Tool-call allow/ask/deny evaluation and bypass resistance |
| B5 User/session isolation | Cross-user and cross-session API/WS boundary checks |
| B6 Notification/log surfaces | Push payloads + diagnostics paths (sensitive data leakage risk) |

## Required attack-class matrix

Status legend: `PASS`, `PARTIAL`, `BLOCK`.

| ID | Attack class | Boundary | Server evidence | iOS evidence | Adversarial E2E evidence | Status |
|---|---|---|---|---|---|---|
| S1 | Invite tamper reject | B1 | `pi-remote/tests/security-invite.test.ts` (`fails verification if payload is tampered`) | `ios/PiRemoteTests/ModelCodableTests.swift` (`decodeInvitePayloadRejectsTamperedSignedEnvelope`) | `test-security-adversarial.ts` (`tampered payload is rejected`) | PASS |
| S2 | Invite expiry/replay reject | B1 | Freshness check validated in adversarial script (server is issuer-only for invite parse) | `ModelCodableTests` (`decodeInvitePayloadRejectsExpiredSignedEnvelope`, `...FutureIssuedAtBeyondClockSkew`) | `test-security-adversarial.ts` (`replay invite freshness check detects expiry`) | PASS |
| S3 | Unsigned invite downgrade reject (`v1-unsigned`) | B1/B2 | `config-validation.test.ts` rejects non-`v2-signed` invite format | iOS accepts signed v2 invites only during onboarding/launch | Adversarial script runs strict profile posture | PASS |
| S4 | Pinned fingerprint mismatch hard-block | B2 | `/security/profile` identity hydration tests (`security-profile-api.test.ts`) | Launch path contains hard-block logic in `PiRemoteApp.swift`; onboarding mismatch handling in `OnboardingView.swift` | `test-security-adversarial.ts` mismatch class (`profile mismatch class detected`) | PARTIAL (needs dedicated iOS regression test) |
| S5 | Transport policy rejection outside tailnet | B3 | Server profile API tests for policy contract | `ios/PiRemoteTests/ConnectionSecurityPolicyTests.swift` | Covered by policy-host classification paths | PASS |
| S6 | Token/push/log redaction assertions | B6 | `pi-remote/tests/push-redaction.test.ts` (high-risk summary redaction + low-risk passthrough) | Lock-screen redaction path implemented in `PermissionNotificationService.swift` | N/A | PARTIAL (logging redaction matrix still incomplete) |
| S7 | Signing-key backend failure + fallback behavior | B1/B6 | `push-redaction.test.ts` (`createPushClient` invalid key -> `NoopAPNsClient`) | N/A | N/A | PASS (APNs path); invite-key backend still manual/audit |
| S8 | Biometric-gated trust-reset flow | B2 | N/A | Biometric gating implemented in onboarding trust flow (`OnboardingView.swift` + `BiometricService`) | Manual E2E required on device | PARTIAL (manual check required) |

## Additional adversarial coverage (policy/cross-user/exfil)

| Class | Evidence |
|---|---|
| Policy bypass (chained shell) | `pi-remote/tests/policy-fuzz.test.ts` (`chained-command bypass fuzz`), `policy-host.test.ts` |
| Credential exfil attempts | `policy-host.test.ts` + `policy-fuzz.test.ts` deny `auth.json` reads and secret-exfil patterns |
| Cross-user/session isolation | `permissions-pending-api.test.ts` ownership checks + `auth-proxy.test.ts` unregistered session rejection (403) |

## Consolidated findings

| ID | Severity | Finding | Repro/Evidence | Fix status | Owner |
|---|---|---|---|---|---|
| F-002 | Medium | Pinned fingerprint mismatch path lacks dedicated iOS regression test (logic exists) | Launch/onboarding logic in `PiRemoteApp.swift` + `OnboardingView.swift`; no direct unit test yet | Open | `TODO-150764f5` |
| F-003 | Medium | Redaction assertions strong for push payloads, but full client-log redaction matrix is not yet automated | `push-redaction.test.ts` passes; diagnostics ingest path needs explicit token-pattern assertions | Open | `TODO-a146a5aa` |
| F-004 | Medium | Biometric trust-reset flow remains manual verification only | Onboarding biometric branch exists; no deterministic unit test over LAContext flow | Open | `TODO-150764f5` |

## Residual risks

| Risk | Current mitigation | Residual owner |
|---|---|---|
| Sensitive strings in client diagnostics payloads | Entry limits + truncation; no semantic token scrub yet | `TODO-a146a5aa` |
| Device-auth UX edge cases (biometric cancel/retry) | Runtime gating present; tests/manual playbook incomplete | `TODO-150764f5` |

## Validation run snapshot (2026-02-11)

- `cd pi-remote && npx vitest run tests/security-invite.test.ts tests/security-profile-api.test.ts tests/config-validation.test.ts tests/push-redaction.test.ts tests/policy-fuzz.test.ts tests/policy-host.test.ts tests/auth-proxy.test.ts tests/permissions-pending-api.test.ts`
  - Result: **8 files passed, 179 tests passed**.
- `cd pi-remote && npm run test:security:adversarial`
  - Result: **7/7 checks passed** (tamper/replay/mismatch classes).
- `cd ios && xcodebuild ... -only-testing:PiRemoteTests/ServerCredentialsInviteSecurityTests -only-testing:PiRemoteTests/ConnectionSecurityPolicyTests`
  - Result: **11 tests passed across 2 suites**.

## Release gate decision

**Decision:** `BLOCK`  
**Date:** 2026-02-11  
**Scope:** P0 security umbrella for pi-remote + iOS (`TODO-2a12a17c`)

### Blockers to clear
1. Add explicit iOS regression for pinned-fingerprint mismatch hard-block path.
2. Complete logging redaction assertions for diagnostics ingress.
3. Execute and record biometric trust-reset manual runbook.

## Verification commands

```bash
# Server unit coverage for new matrix items
cd pi-remote
npx vitest run tests/security-invite.test.ts tests/security-profile-api.test.ts tests/config-validation.test.ts tests/push-redaction.test.ts tests/policy-fuzz.test.ts tests/policy-host.test.ts tests/auth-proxy.test.ts tests/permissions-pending-api.test.ts

# Adversarial replay/tamper/mismatch script
npm run test:security:adversarial

# iOS invite + transport checks
cd ../ios
xcodebuild -project PiRemote.xcodeproj -scheme PiRemote \
  -destination 'platform=iOS Simulator,OS=26.0,name=iPhone 16 Pro' test \
  -only-testing:PiRemoteTests/ModelCodableTests \
  -only-testing:PiRemoteTests/ConnectionSecurityPolicyTests
```
