# Model usage and account attribution

## Detail controls

The bottom chevron on each account card opens/closes model details vertically using the Config panel's 0.12-second ease-out timing. Reduced Motion disables the transition. Details refresh every minute while mounted. Historical usage bars compare model amounts within the selected report. Native quota bars use a fixed 0–100% scale and say “quota used.”

## OpenAI

Read the authenticated `GET /backend-api/wham/usage/daily-token-usage-breakdown` with that row's bearer token and ChatGPT account header. Request 30 UTC dates and aggregate `data[].attribution[].value`, falling back to `data[].models[].credits` only when a day has no attribution, preserving the response's declared units. Recent seven-day responses were empty while the 30-day response returned older activity. The UI shows the latest reported activity date; no current usage is invented from older values. Consumer responses tested on this Mac report `percent`; display percentage points, not tokens, money, or remaining allowance. Do not add `models[].credits` to attribution: these are overlapping representations.

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

Removed the provisional reset probes, embedded Claude Usage window, web connection controls, and web reset session reads at the user's request. The OAuth offer was surface-restricted; no reliable native inventory was established. No reset was redeemed. Existing hidden legacy sign-in support remains for quota fetching.

## Anthropic native quotas

The expanded panel shows the account's provider-reported scoped model limits, with reset times and a fixed percentage scale. These reuse the main account reading, avoiding a duplicate OAuth poll from the detail panel; they update when that reading changes. A live 429 during validation motivated removing the extra request. They remain available even when there are no local Claude Code events. Token collection is a separate section; an empty collector is explicitly identified instead of implying that the subscription quota fetch failed. No profile request is needed until local events exist.

## Google Antigravity

Verified the installed local database schema and protobuf descriptors embedded in `/Applications/Antigravity.app/Contents/Resources/bin/language_server`. `gen_metadata` has model/token data; `trajectory_meta` has conversation IDs, source and type. `CortexStepMetadata`, `CortexTrajectoryMetadata`, `ChatModelMetadata`, `ChatStartMetadata` and `ModelUsageStats` do not expose a per-request account identity. The 36 bounded generation records inspected had custom keys for execution, step, model and trajectory information; response headers only included `sessionID`. None establishes which account paid for a request after switching accounts.

The Google detail panel now calls `fetchAvailableModels` with the selected account's credentials and project, and renders native individual model quotas, including Claude/GPT models available through Antigravity. Machine credentials are used only for an explicitly imported machine account. These are current quota percentages, not historical token totals; shared pools are called out. Account-authenticated pooled quotas continue working. This finding covers the installed schema and inspected records; it is not a claim that Google has no internal accounting data.

## Verification

Run `bash Tests/run-usage-tests.sh` (uses the real parsers and ledger; no Xcode/XCTest required), then `swift build --disable-sandbox -c release`. Render the collapsed/expanded design with `MultimodelTracker --render-details /absolute/path/preview.png`.

For a read-only live detail check, launch the installed bundle with `--detail-diagnostics /absolute/path/report.json`. It uses the same native detail service as the UI, after main refresh, and keeps that same process running. The report omits credentials and account identifiers.

Live native service verification on September 23 returned 23 Google model quota rows, five OpenAI model totals (latest activity September 15), and the Anthropic scoped Fable limit at 100%. Claude Code event count remained zero.
