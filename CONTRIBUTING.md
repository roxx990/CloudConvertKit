# Contributing

Issues and pull requests are welcome. Pull requests go against `main`, where CI runs the tests on them. Before opening one:

- **No third-party dependencies.** The core imports only Foundation, Network and os.
- **Keep the core UI-free.** `CloudConvertKit` never imports UIKit, SwiftUI or Combine; the SwiftUI adapter belongs in `CloudConvertKitUI`.
- **Keep builds warning-free.** Every target builds with strict concurrency checking, and `CloudConvertKitSwift6Tests` in the Swift 6 language mode.
- **Localize user-facing strings.** Route them through `CloudConvertLocalization` with a new, stable key.
- **Treat analytics codes as a contract.** `CloudConvertError.analyticsCode` values feed dashboards; add new ones, never rename existing ones.
- **Never bill twice.** A change to retries, rebuilds or resuming must keep a file from being converted, and billed, a second time; `FailureHandlingTests`, `ResumeTests` and `StressTests` check it.
- **Test both platforms.** Add a test with every behaviour change, in the file for its subject (see [Testing](Docs/Testing.md)), then run `swift test`, `swift test --sanitize=thread` and the iOS simulator command.
- **Update the docs.** Record the change under `## Unreleased` in `CHANGELOG.md`, and update the README or the page in `Docs/` that covers it when behaviour or API changes.

## Releasing

Releases follow [semantic versioning](https://semver.org) and are published as git tags. To release, rename the changelog's `## Unreleased` heading to the version (`## 2.1.0`), merge to `main`, then tag that commit and push the tag:

```bash
git tag -a 2.1.0 -m "CloudConvertKit 2.1.0" && git push origin 2.1.0
```

[`release.yml`](.github/workflows/release.yml) then checks that the tag is on `main` and in the changelog, runs the tests on it, and publishes the GitHub release "CloudConvertKit 2.1.0" with that changelog section as its notes. If a check fails, nothing is published; delete the tag, fix, and tag again.
