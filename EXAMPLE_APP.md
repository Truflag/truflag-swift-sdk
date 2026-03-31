# iOS Swift Sample Operations Guide

This guide describes the low-cost testing loop for the private monorepo Swift SDK sample.

## Windows local loop (cheap tier)

1. Run Swift SDK package tests in Docker:
   - `cd sdk`
   - `npm run test:native:ios:docker`
2. Run contract fixtures and static checks:
   - `npm run test:contracts`
   - `npm run lint`
   - `npm run typecheck`
3. Only trigger macOS workflow when SDK/sample/docs-ios changes are meaningful.

## When to trigger macOS build

Use `.github/workflows/ios-swift-sample.yml` in these cases:

- Manual verification before merging high-risk SDK networking/identity changes.
- Scheduled confidence runs (twice weekly).
- Release tag candidate validation (`sdk-ios-v*`).

Do not run macOS jobs on every PR by default.

## Cost controls (private repo)

- Keep `sdk-cheap-ci` as the default gate.
- Keep macOS workflow manual/scheduled/release scoped.
- Use workflow concurrency cancellation to avoid stacked macOS jobs.
- Keep timeout limits enabled.
- Configure GitHub billing budget alerts at low thresholds in repo/org settings.

## Pre-release checklist (physical iPhone)

Before publishing React/RN SDK versions that depend on backend parity, run one signed iOS device pass:

1. Configure sample with real `client-side-id` and relay URL.
2. Validate configure/login/setAttributes/logout flows.
3. Validate flag reads with explicit fallback values.
4. Confirm assignment payload metadata (`reason`, `configVersion`) in debug panel.
5. Send one event and one explicit exposure event.
6. Confirm behavior when refresh fails (last known values retained).
7. Confirm archived-flag behavior aligns with SDK fallback semantics.
