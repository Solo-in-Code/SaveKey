# Publishing on the App Store

SaveKey is not on the App Store yet. This page lists what will be needed when it is published,
by the SaveKey project or by anyone else under [APP_STORE_EXCEPTION.md](../APP_STORE_EXCEPTION.md).
Check Apple's current rules when the time comes; they change.

## Account and name

- **Apple Developer Program.** Publishing needs a paid membership (99 USD a year at the time of
  writing). Password AutoFill needs it too, so build from `SaveKey.xcodeproj`.
- **Enrol as an organization** if the seller shouldn't be a person: Apple shows the organization's
  legal name as the seller and asks for its D-U-N-S number. An individual membership shows the
  person's legal name instead.
- **Signing:** put the organization's team and bundle ID in `SaveKey-Signing.xcconfig` next to the
  repository folder.
- **Name and icon:** app names must be unique on the App Store, so check early that "SaveKey" is
  still free. The logo is reserved for the SaveKey project ([Branding/README.md](../Branding/README.md));
  other people's versions must use their own name and icon (condition 3 of the app store
  permission).
- **Copyright notice:** to show the organization instead of "the SaveKey contributors", change it
  in the README's License section and in `AppConfig.copyrightNotice` (`Shared/AppConfig.swift`).

## License

- The GNU AGPL together with [APP_STORE_EXCEPTION.md](../APP_STORE_EXCEPTION.md) allows App Store
  distribution, including code from other contributors, who agree to the same terms
  ([CONTRIBUTING.md](../CONTRIBUTING.md) and the pull request template).
- Settings › License already links to the source code and to the privacy policy
  (`AppConfig.sourceCodeURL` and `AppConfig.privacyPolicyURL` in `Shared/AppConfig.swift`). Link to
  the source code (<https://github.com/Solo-in-Code/SaveKey>) in the App Store description too.

## Privacy

- **Privacy policy URL:** required for every app. Use <https://github.com/Solo-in-Code/SaveKey/blob/main/PRIVACY.md>; the app
  already links to it in Settings › License.
- **App Privacy questions** in App Store Connect: SaveKey collects no data, so the answer is
  "Data Not Collected". Website icons are requested straight from each website, as a browser
  does, and nothing reaches the SaveKey project; `PRIVACY.md` explains this. If a feature ever
  changes that, update `PRIVACY.md` and the answers first.
- **Support URL:** the repository's issues page works.

## Encryption (export compliance)

App Store Connect asks about encryption for every version. SaveKey uses standard algorithms, and
some of them are implemented in the app rather than taken from iOS (Argon2, ChaCha20, Salsa20), so
answer that it uses standard encryption algorithms. Then:

- Add `ITSAppUsesNonExemptEncryption` to the app's Info.plist (in `project.yml` and
  `project-free.yml`) with the value that matches those answers, so the questions aren't asked again
  for every build.
- Distributing in **France** requires a French encryption declaration uploaded to App Store Connect.
  Leaving France out at first avoids it until the declaration is ready.
- US export rules apply as well. Read Apple's "Overview of export compliance" in App Store Connect
  Help before the first upload.

## Before each release

- `swift test --package-path Packages/KeePassCore`, `Tools/SyncCheck/run.sh` and
  `python3 Tools/Localization/check_translations.py` pass (the CI workflow runs them).
- Raise `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in both project files and regenerate the
  projects with XcodeGen.
- Tag the release in the repository, so every App Store version has matching published source code.
