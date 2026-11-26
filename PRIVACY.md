# Privacy policy

*Last updated: 25 November 2026*

SaveKey is a password manager for iPhone that works with KeePass databases.

**SaveKey does not collect, store or share any personal data.** It has no accounts, no servers run
by the SaveKey project, no analytics, no advertising and no tracking. Its source code is public, so
anyone can check what it does.

## Your databases

Your passwords are kept in KeePass database files (`.kdbx`) that you choose: on your iPhone, in
iCloud Drive, in another cloud storage app, or in a folder kept in sync by an app such as Synctrain.
SaveKey opens and saves them where they are. They are encrypted with your master password and, if
you use one, your key file.

SaveKey never uploads your databases anywhere. Copying them between your devices is done by the
storage or sync service you choose, under that service's own privacy policy.

## What stays on your iPhone

- The list of databases you have opened (as references to the files) and your settings.
- If you turn on Face ID or Touch ID unlock: the key to that database, kept in the iPhone's
  Keychain. It can only be used after Face ID or Touch ID, and it is never included in backups or
  synced to other devices.
- If you turn on website icons: the logos that were downloaded.
- While a database is unlocked: attachments you open are decrypted into a protected temporary folder
  that is erased when the database locks.
- If you turn on QuickType suggestions for AutoFill (off by default): the usernames and website
  addresses of your entries are given to iOS, on your iPhone, so the keyboard can suggest them.
  Passwords are not.

## The internet

SaveKey connects to the internet for one optional feature: **website icons** (in Settings, off by
default). When it is on, SaveKey asks the website in an entry's web address for its logo, for
example `netflix.com` for a Netflix entry. It sends only the site's address, over HTTPS and without
cookies. Like any website you visit, that site can see your IP address and that its logo was
requested, but nothing from your database. You can turn the feature off and delete the downloaded
logos in Settings at any time.

Nothing else in SaveKey uses the internet.

## Camera, photos, Face ID and the clipboard

- **Camera:** used only when you scan a payment card or a one-time password QR code. The images are
  processed on your iPhone. Card photos are kept only if you choose to save them, inside your
  encrypted database.
- **Photos:** only images you pick yourself, for an entry icon or a payment card.
- **Face ID and Touch ID:** handled by iOS. SaveKey never sees your face or fingerprint data.
- **Clipboard:** passwords you copy stay on this iPhone (they are not shared with your other
  devices) and are removed after the time you choose in Settings (one minute by default).

## Crash reports

SaveKey contains no crash-reporting or analytics code. If SaveKey is installed from the App Store
and you allow iOS to share analytics with app developers, Apple may send anonymous crash reports to
the developer. You control this in iOS Settings › Privacy & Security › Analytics & Improvements.

## Children

SaveKey collects no data from anyone, including children.

## Changes to this policy

Changes are published in the SaveKey source repository, where every earlier version of this policy
stays visible in the history.

## Questions

Open an issue in the SaveKey source repository. For security problems, follow
[SECURITY.md](SECURITY.md) instead.
