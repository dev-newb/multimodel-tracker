# Model usage and account attribution

## Detail controls

The bottom chevron on each account card opens/closes model details vertically using the Config panel's 0.12-second ease-out timing. Reduced Motion disables the transition. Details refresh every minute while mounted. Bars compare model amounts within the selected report; they are not separate quota pools.

## OpenAI

Read the authenticated `GET /backend-api/wham/usage/daily-token-usage-breakdown` with that row's bearer token and ChatGPT account header. Aggregate `data[].attribution[].value` over seven UTC dates, preserving the response's declared units. Consumer responses tested on this Mac report `percent`; display percentage points, not tokens, money, or remaining allowance. Do not add `models[].credits` to attribution: these are overlapping representations.

The authenticated endpoint returns per-model data. Backend billing behavior when the same conversation is continued under two accounts has not been independently verified. The UI says so. Local Codex logs are not a substitute: the inspected token events have no payer identity.

Imported CLI credentials are no longer silently replaced from the CLI's current login when the old token expires/disappears. Explicitly sign in or import again so switching the CLI cannot relabel another account's card.

Sources:
- https://github.com/openai/codex/blob/main/codex-rs/backend-client/src/client/analytics.rs
- https://github.com/openai/codex/issues/16323

## Claude Code

An optional local OTLP/HTTP JSON log collector listens only on `127.0.0.1:43189`. Enable/stop controls are inside Anthropic details. Enabling merges the required environment variables into `~/.claude/settings.json`, saves a backup, preserves unrelated settings, and refuses to replace another log exporter. Restart Claude Code after configuration changes. Existing sessions, remote machines, Claude Desktop chat, and periods when the tracker is stopped are not backfilled.

Only `api_request` events with an explicit account UUID, organization ID, request ID, model, valid timestamp and token counters are accepted. Aggregation matches the OAuth profile's account **and** organization IDs. No attribution is inferred from the session's current login or email. Retries are deduplicated by organization/account/request. Missing identity is excluded. Input, output, cache-read and cache-creation tokens contribute to total tokens; these are not subscription charges.

Only the allowlisted usage metadata is persisted in `~/Library/Application Support/MultimodelTracker/claude-usage.json` (mode 0600), with 30-day/100,000-event retention. Prompts, responses, email addresses, tools and raw log bodies are not persisted. HTTP requests require an installation-specific Authorization header and a bounded Content-Length. Claude Code versions using chunked OTLP exports must be upgraded (Anthropic documents Content-Length support restored in v2.1.212).

Synthetic tests verify per-event account switching, organization isolation, duplicate delivery, reload, and content exclusion. The receiver has been tested live with an empty authenticated batch and an unauthenticated rejection. There was no installed Claude CLI/usable Claude Code credential to produce a live event in this session, so upstream identity freshness across `/login` remains an integration limitation.

Source: https://code.claude.com/docs/en/monitoring-usage

## Claude saved resets

Read-only OAuth probes explicitly request `cedar_ember=1` and `at_wall=1` with `skip_spend=1`. The user's tracker credential returned `ineligible_reason: "surface"` for both, despite the October 22 offer being visible in Claude web. Never interpret that response or a null program as zero saved resets.

Claude's current public frontend confirms its web route is `/api/organizations/{organization}/usage?cedar_ember=1&skip_spend=1`. The optional **Connect Claude web for reset offers** button opens an isolated per-account WebKit login. After login, Refresh details checks `/api/account`, requires an exact account UUID and organization membership match to the OAuth profile, then reads the offer. It never chooses the first organization or redeems a reset. A separate web sign-in is needed; browser cookies are not imported. This authenticated web integration still needs end-to-end verification after that sign-in.

Sources:
- https://assets-proxy.anthropic.com/claude-ai/v2/assets/v1/shared-0-XAxgp5z9.js
- https://github.com/can1357/oh-my-pi/issues/12883
- https://support.claude.com/en/articles/17007452-what-is-a-limit-reset

## Google Antigravity

Verified the installed local database schema and protobuf descriptors embedded in `/Applications/Antigravity.app/Contents/Resources/bin/language_server`. `gen_metadata` has model/token data; `trajectory_meta` has conversation IDs, source and type. `CortexStepMetadata`, `CortexTrajectoryMetadata`, `ChatModelMetadata`, `ChatStartMetadata` and `ModelUsageStats` do not expose a per-request account identity. The 36 bounded generation records inspected had custom keys for execution, step, model and trajectory information; response headers only included `sessionID`. None establishes which account paid for a request after switching accounts.

Therefore the Google detail panel explicitly reports account-specific model history unavailable. Account-authenticated quota pools continue working. This finding covers the installed schema and inspected records; it is not a claim that Google has no internal accounting data.

## Verification

Run `bash Tests/run-usage-tests.sh` (uses the real parsers and ledger; no Xcode/XCTest required), then `swift build --disable-sandbox -c release`. Render the collapsed/expanded design with `MultimodelTracker --render-details /absolute/path/preview.png`.
