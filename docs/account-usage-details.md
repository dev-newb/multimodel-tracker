# Model usage and account attribution

## Detail controls

The bottom chevron on each account card opens/closes model details vertically using the Config panel's 0.12-second ease-out timing. The arrow retains its original 16-point row and plain styling. Both scroll containers use `.scrollIndicators(.never)` to hide their indicators even when a mouse is attached, including during expansion/contraction; wheel and trackpad scrolling remain enabled. Details scroll within a 240-point viewport, keeping the collapse control outside that scroll area; the outer list reveals the control after expansion if necessary. Reduced Motion disables the transition. Details refresh every minute while expanded; collapsing retains the loaded report. Background refresh does not insert/remove controls around the arrow. Historical usage bars compare model amounts within the selected report. Native quota bars use a fixed 0–100% scale and say “quota used.”

## OpenAI

Read the authenticated `GET /backend-api/wham/usage/daily-token-usage-breakdown` with that row's bearer token and ChatGPT account header. Request 30 UTC dates and aggregate `data[].attribution[].value`, falling back to `data[].models[].credits` only when a day has no attribution, preserving the response's declared units. Recent seven-day responses were empty while the 30-day response returned older activity. The UI shows the OpenAI server source, spelled-out units and latest reported activity date above the model bars; no current usage is invented from older values. Consumer responses tested on this Mac report `percent`; daily percentages are summed as percentage points (pp), not tokens, money, or remaining allowance. The response does not establish a token conversion or complete cross-device coverage. Do not add `models[].credits` to attribution: these are overlapping representations.

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

Subscription limits, including Weekly — Fable, appear only on the main account card. Expanded Anthropic details show the local Claude Code model totals and collection controls; they do not duplicate scoped quotas or poll the quota endpoint. An empty or disabled collector is identified explicitly. No profile request is needed until local events exist.

## Google Antigravity

Verified the installed local database schema and protobuf descriptors embedded in `/Applications/Antigravity.app/Contents/Resources/bin/language_server`. `gen_metadata` has model/token data; `trajectory_meta` has conversation IDs, source and type. `CortexStepMetadata`, `CortexTrajectoryMetadata`, `ChatModelMetadata`, `ChatStartMetadata` and `ModelUsageStats` do not expose a per-request account identity. The 36 bounded generation records inspected had custom keys for execution, step, model and trajectory information; response headers only included `sessionID`. None establishes which account paid for a request after switching accounts.

The Google detail panel now calls `fetchAvailableModels` with the selected account's credentials and project, and renders native individual model quotas, including Claude/GPT models available through Antigravity. Machine credentials are used only for an explicitly imported machine account. These are current quota percentages, not historical token totals; shared pools are called out. Account-authenticated pooled quotas continue working. This finding covers the installed schema and inspected records; it is not a claim that Google has no internal accounting data.

## Verification

Run `bash Tests/run-usage-tests.sh` (uses the real parsers and ledger; no Xcode/XCTest required), then `swift build --disable-sandbox -c release`. Render the collapsed/expanded design with `MultimodelTracker --render-details /absolute/path/preview.png`.

For a read-only live detail check, launch the installed bundle with `--detail-diagnostics /absolute/path/report.json`. It uses the same native detail service as the UI, after main refresh, and keeps that same process running. The report omits credentials and account identifiers.

Live native service verification on September 23 returned 23 Google model quota rows, five OpenAI model totals (latest activity September 15), and the Anthropic scoped Fable limit at 100% before the duplicate detail section was removed. Claude Code event count remained zero. A fresh, uncached OpenAI server request at 11:42 UTC on September 23 still returned percent units and zero model values for September 16–23. This is a limitation of the returned account history, not a local Codex log-reading dependency. Other-device reporting and account-switch billing have not been established by that response.

## Popover geometry regression

Both scroll viewports use measured document heights with explicit caps. `NSHostingController` automatic preferred-size updates are disabled; bounded geometry updates resize the popover relative to its status item. The fallback panel preserves its top edge and horizontal centre. Neither path uses `fittingSize` (which is zero with automatic hosting sizing disabled).

Run `.build/release/MultimodelTracker --test-popover-layout` after building. The native fixture posts 21 mouse presses to its own window, including the left edge of the arrow's full-width target, changes 23 models to 100, checks bounded height and menu anchor coordinates, and checks fallback panel growth/shrink. No Store, network requests or Keychain reads are initialized by this mode.

### Menu-bar window regression found in full-app validation

The earlier ordinary-window fixture did not cover the real menu-bar window. On the affected setup, `NSStatusBarWindow.screen` was nil and its frame was above the current display bounds. AppKit placed the popover at x=0 despite the status item being at x=2822. The corrected path selects the display from the item's frame (or nearest display for a stale frame), pins the window to that item, and does not re-show it during content resizing. Reopening a visible tracker retains its window and disclosure state. The unrequested increase in arrow spacing was reverted.

Use an isolated app identifier with `--mock --mock-three --open --layout-trace /absolute/path/layout.jsonl` for full UI checks. Mock model details make no credential or provider requests. The opt-in trace records only this app's window geometry, screen frames and timing. Validate normal UI actions through the native computer-use tool; the narrow self-test alone is insufficient evidence for menu-bar placement.

September 23 cleanup: native UI checks confirmed the installed Anthropic detail panel no longer repeats Weekly — Fable. An isolated full-app 23-model fixture verified expansion, scrolling to the bottom, and contraction with no scrollbar; `.hidden` was insufficient with a mouse attached, so the final build uses `.never`. The fixture retained its menu-bar anchor. After the final restart, the installed app reported Keychain user-canceled errors (-128) for Anthropic and OpenAI, so live UI refresh remains blocked; the read-only server check used the current Codex login, whose email matched the visible tracker account.
