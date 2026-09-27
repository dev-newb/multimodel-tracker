# Keychain reads and safe app updates

The app does not receive or validate the Mac login/Keychain password; macOS owns the approval dialog. The app has no code to change or reset that password.

A rebuilt ad hoc app has a new code identity. Replacing an app bundle while its old process is still making Keychain requests can leave stale requests associated with an old process or signature. Always install with:

```sh
bash make-app.sh release
python3 scripts/install-app.py
```

The installer stages and verifies the complete bundle, stops the process at the destination, waits for exit, and only then swaps bundles. It aborts without replacing the destination if the process does not exit. The default leaves the app stopped; `--launch` explicitly reopens it. Packaging also refuses to overwrite a running build-directory bundle.

Credential handling:

- Validate the running caller's signature before requesting secret data.
- Share a serial read queue and a per-item in-flight operation across provider polling and model details.
- Cache denial/error results as well as successes. Polling does not repeatedly request approval after a failure.
- Show the macOS status for stored-account access failures, with an explicit Retry Keychain action. An access denial is not treated as a missing OAuth credential or routed to a different login method.
- Update existing items with `SecItemUpdate`; only add when the item is genuinely missing. Never delete an existing credential to save a replacement. Propagate save failures.
- Seed the in-memory cache after a successful save to avoid an immediate extra Keychain read.
- Keep per-account caches separate and prevent an old in-flight result from overwriting a newer saved value.

Checks: `bash Tests/run-keychain-tests.sh`, `python3 Tests/test_installer.py`, release build, and signature verification. The regression tests use fake read/write callbacks and temporary app folders; they do not access credentials, request passwords, or modify the login Keychain.

These safeguards do not provide a stable signing identity. Developer signing is still required to preserve approvals across builds reliably. Successful tests do not establish that a particular user's next macOS approval dialog will accept their password; that requires a user-controlled live check.
