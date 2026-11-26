# Contributing to SaveKey

Thanks for helping! Bug reports, translations, documentation and code are all welcome.

## Reporting bugs

Open an issue with the SaveKey version (Settings › About), your iOS version, the steps that lead to
the problem and what you expected instead. If it involves a database, describe how it was made
(KeePassXC, KeePassDX, SaveKey…) and its settings (cipher, KDF). **Never attach a real database,
password or key file**; make a test database with made-up entries instead.

Security problems go through a private report, not an issue: see [SECURITY.md](SECURITY.md).

## Building

See the README: use `SaveKey-Free.xcodeproj` with a free Apple ID or `SaveKey.xcodeproj` with a paid
developer account, and put your bundle ID and team in `SaveKey-Signing.xcconfig` **next to** the
repository folder. That file stays out of git, so you never commit signing details.

The Xcode projects are generated from `project.yml` and `project-free.yml` with
[XcodeGen](https://github.com/yonaskolb/XcodeGen). If you change either file, regenerate both
projects and commit them:

```
xcodegen generate --spec project.yml
xcodegen generate --spec project-free.yml
```

## Tests

```
swift test --package-path Packages/KeePassCore    # the KeePass engine: macOS or Linux
Tools/SyncCheck/run.sh                             # the file-sync code: Linux (or Docker on a Mac)
python3 Tools/Localization/check_translations.py   # every on-screen text is translated
```

The [CI workflow](.github/workflows/tests.yml) runs all three on every push and pull request. The
SwiftUI app itself needs Xcode, so please build and try your change on an iPhone or the simulator.

## Translations

Translations live in the tables in `Tools/Localization/strings_*.py`, one line per text:
`K(english, de, es, fr, it, pt_BR, pt_PT)` (the last one may be left out when it is the same as
Brazilian Portuguese). Don't edit the `.strings` files by hand; after changing a table, run:

```
python3 Tools/Localization/make_strings.py          # writes Shared/Localization, checks placeholders
python3 Tools/Localization/check_translations.py    # shows texts that still need translating
```

Corrections from native speakers are especially welcome: the current translations have not been
reviewed by native speakers yet. Adding a language means adding it to `make_strings.py`,
`AppLanguage.supported` in `Shared/AppLanguage.swift`, and `CFBundleLocalizations` in both
project files.

## Code

- **Engine:** `Packages/KeePassCore` must stay free of UIKit and SwiftUI so it builds and tests on
  Linux. Changes to cryptography or the KDBX format need tests, ideally with published test vectors
  or files made by other KeePass apps.
- **App:** SwiftUI, Swift 5 language mode, iOS 16 or later. Shared code between the app and the
  AutoFill extension goes in `Shared/`.
- **Texts:** write on-screen texts as `Text("…")`, `Button("…")`, `String(localized: "…")` and so
  on, so they can be translated, and add them to a translation table.
- **Privacy:** SaveKey only goes online to fetch website icons, when that option is on. Please don't
  add analytics, crash reporters or other network calls.
- **License header:** start new source files with `// SPDX-License-Identifier: AGPL-3.0-or-later`
  (or `#` in Python).
- **Logo:** the SaveKey logo is not open source ([Branding/README.md](Branding/README.md)), so
  changes to it can't be accepted as contributions.

## License

SaveKey is licensed under the GNU Affero General Public License, version 3 or later, with an
additional permission for app stores ([APP_STORE_EXCEPTION.md](APP_STORE_EXCEPTION.md)). By
contributing, you agree that your contributions are licensed under the same terms, including that
permission, so SaveKey can be offered on the App Store while staying open source. The pull request
template asks you to confirm this.
