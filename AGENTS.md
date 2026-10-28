# Claude Preflight v1 workspace instructions

This is the Windows-only Claude Preflight v1 project.
Preserve LICENSE and NOTICE.md. Read README.md and docs/RELEASE-v1.md before changing behavior. The v1 release documentation is now prepared; the author's private project guide remains outside the public package.
Unused imported implementations, artwork, installers and historical source-audit files have been removed. Do not restore them as runtime dependencies or claim macOS/Linux support.

- Continue work in this preview; do not alter the original live checkout or its installed rules.
- The v1 entry is Start-ClaudePreflight.cmd and windows/local + windows/direct. The duplicate Start-ClaudeSwitcher.cmd has been removed.
- Disabled legacy strict-system entry scripts were removed from the release tree. Do not restore them during ordinary v1 work.
- Windows PowerShell scripts must retain UTF-8 BOM and support Windows PowerShell 5.1.
- settings.json is local and ignored; settings.example.json contains documentation placeholders.
- Do not commit real exit IPs, usernames, device IDs, credentials, generated inventories, snapshots or runtime logs.
- Mocked tests are safe to run. Firewall/service/adapter mutations need explicit task authorization and Windows UAC.
- Keep Tailscale/WSL internal networking intact. Do not claim complete child-process isolation, zero leaks or guaranteed account safety.
- Do not publish, push, create a GitHub repository or install automation without an explicit request.
- Personal parameters are persisted only through windows/local/Configuration.ps1 into settings.json. Do not add private defaults to UI, core, fixtures, logs or inventories.
- Keep LocalePolicy.ps1 a public policy catalogue. Region pairing is a product constraint, not an official account-risk claim.
- Keep windows/local/Test-LocalGuard.ps1: it is an active launch-regression suite called by tests/Run-Tests.ps1, not a disabled strict-system entry. StrictPolicy.ps1 also retains functions used by the current runtime.
- Run tests/Run-Tests.ps1 for configuration, launch or public-export behavior changes. Use Export-PublicPreview.cmd for sanitized archives.
