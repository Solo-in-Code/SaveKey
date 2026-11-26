# The SaveKey logo

The SaveKey logo (a fingerprint with a keyhole) and the SaveKey lettering ("Save" in ivory, "Key" in
orange) are **not open source**. They are Copyright © 2026 the SaveKey project, all rights reserved,
and they are **not covered by the GNU AGPL** that applies to the rest of SaveKey. Below, "the logo"
means both.

The logo is in these files:

- `Branding/savekey-icon.svg` and `Branding/savekey-mark.svg` (the masters)
- `Branding/savekey-banner.svg` (the banner at the top of the README)
- `Branding/savekey-social-preview.svg` and `Branding/savekey-social-preview.png` (GitHub's social
  preview)
- `Branding/make_logo.py` and `Branding/make_banner.py` (the scripts that draw them)
- `App/Assets.xcassets/AppIcon.appiconset/AppIcon.png` (the app icon)
- `App/Assets.xcassets/Logo.imageset/Logo.png` (the logo shown inside the app)

## What you may do

- **Build SaveKey for yourself** with the logo, changed or unchanged, as long as the build is for
  your own personal use.
- **Pass on official SaveKey releases** exactly as they are.
- **Show the logo to refer to SaveKey**, for example in an article, a review or a link to the
  project, without changing it and without suggesting that the SaveKey project endorses you.

## What you may not do

- **Distribute your own builds of SaveKey, or of a version based on it, with the logo**, in an app
  store or anywhere else, unless you do it on behalf of the SaveKey project. Replace the app icon and
  the in-app logo with your own (the two image sets listed above), and use a logo that can't be
  confused with SaveKey's.
- **Use the logo, or something that looks like it, for another app, product or service.**

The source code stays free under the GNU AGPL: replacing these image files is all a version of your
own needs. For any other use of the logo, ask the SaveKey project by opening an issue at <https://github.com/Solo-in-Code/SaveKey/issues>.

## Colours and fonts

| Colour | Where |
|---|---|
| Ivory `#fffff0` | the ridges and the keyhole; "Save" |
| Orange `#f15a30` | the two orange half-ridges; "Key" |
| Slate `#283438` | the background |

The lettering is IBM Plex Sans Bold, and the line under the logo on the social preview is IBM Plex
Mono, both used under the SIL Open Font License 1.1 (that license covers the fonts, not the logo).
The files contain the letters as outlines, so no font is needed to show them. The SVG files carry the
rights notice as a comment, and the PNG files that `make_banner.py` writes carry it as their
"Copyright" text field.

## Drawing the files again

- `python3 Branding/make_logo.py` draws the masters and the two app images (it needs Pillow and
  `rsvg-convert`).
- `python3 Branding/make_banner.py` draws the banner and the social preview (it also needs
  `fonttools`, `uharfbuzz` and the fonts IBM Plex Sans and IBM Plex Mono; see the top of the script).
  With `--kit FOLDER` it also writes every logo and banner file, as SVG and PNG, into that folder.

GitHub shows the social preview when someone shares a link to the repository, once
`savekey-social-preview.png` is uploaded in the repository's **Settings › General › Social
preview**.
