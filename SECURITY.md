# Security policy

SaveKey keeps passwords, so security reports matter a lot. Thank you for taking the time.

## Reporting a vulnerability

Please **don't open a public issue**. Report it privately on GitHub: open the repository's
**Security** tab and choose **Report a vulnerability**. Include:

- the SaveKey version (Settings › About) and your iOS version;
- what you found and why it matters;
- the steps to reproduce it.

If a database is needed, make a test database with made-up entries. Never send a real database,
password or key file.

SaveKey is a volunteer project, so there is no fixed response time, but security reports come first.
Once a fix is available, the report can be published with credit to you, if you like.

## Scope

In scope: the KDBX reader and writer and the cryptography in `Packages/KeePassCore`; master key and
key file handling; Face ID quick unlock and the Keychain; the AutoFill extension; the clipboard;
attachments; file access and sync.

Out of scope: attacks that need a jailbroken or already compromised device; weaknesses in other apps
or services (KeePassXC, sync tools, cloud storage); and weak master passwords.

## Supported versions

Only the latest version on the `main` branch gets security fixes.
