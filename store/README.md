# Play Store listing

Versioned source for the Google Play **store listing text**, so it stays in sync with the app and
never lives only in the Play Console. Publishing is still manual (copy/paste into the Play Console),
but this is the single source of truth to copy from and to edit when features change.

The one-time Premium in-app product copy (title + 200-char description) is versioned separately in
[`premium_unlock.md`](premium_unlock.md).

## Layout

One folder per Play Console locale, with plain-text files named to match the
[Fastlane `supply`](https://docs.fastlane.tools/actions/supply/) convention (so it can feed automation
later):

```
store/
  en-US/  fr-FR/  es-ES/  pt-BR/  de-DE/  it-IT/  ru-RU/
  tr-TR/  pl-PL/  id/  vi/  uk/  el-GR/
  es-419/  fr-CA/  pt-PT/        # regional variants: changelogs only, see below
    title.txt              # app name, max 30 chars
    short_description.txt   # one line, max 80 chars
    full_description.txt    # max 4000 chars
    changelogs/
      <versionCode>.txt     # "What's new" release notes, max 500 chars
```

**Folder names are Play Console locale codes, and the Console is the authority.** Indonesian,
Vietnamese and Ukrainian have no country suffix (`id`, `vi`, `uk`); Greek is `el-GR` (not bare `el`).

13 of these match the app's in-app languages. The Console listing additionally carries three
**regional variants** the app does not translate separately: `es-419` (Latin American Spanish),
`fr-CA` and `pt-PT`. They have changelogs here but **no `full_description.txt` yet**: the live
listing text for them was not authored in this repo, so it is untracked and, notably, still missing
the GPL source URL that the other 13 carry. Write them (adapting es-ES / fr-FR / pt-BR to regional
vocabulary: celular, casse-têtes, telemóvel) or drop the languages from the Console.

To check the real set, open a release in the Console: the release-notes box pre-fills one `<tag>`
per listing language. That list, in that order, is what a paste must match.

The "Available in N languages" bullet in every full_description hard-codes the count (the app's 13,
not the listing's 16), so bump it when the app's language set changes.

Several full_descriptions sit within ~25 chars of the 4000 limit (fr-FR is the tightest), so measure
before adding a sentence. Every one of them ends with the GPL-3.0 credit **and the source URL** —
that link is a GPLv3 §6(d) obligation ("clear directions next to the object code"), not a nicety.
Don't drop it to win back characters.

`changelogs/` is named by Android `versionCode` (see `version/code` in
[`export_presets.cfg`](../export_presets.cfg)), per the Fastlane convention. Play falls back to the
default language when a locale has no changelog, so only en-US is strictly required.

## Graphics (already in the repo, not duplicated here)

The listing images live under [`docs/img/`](../docs/img) (shared with the website):

- **Phone screenshots** (1080×1920-ish, upload these): `Screenshot_home_x3.png`,
  `Screenshot_before_move_x3.png`, `Screenshot_after_move_x3.png`, `Screenshot_moves_review_x3.png`,
  `Screenshot_puzzle_x3.png`, `Screenshot_facetoface_x3.png`, `Screenshot_review_x3.png`
- **Feature graphic** (1024×500): `feature_graphic.png`
- **App icon** (512×512): `icon.png`
- **Promo video** (Play listing links a YouTube URL, not a file): a 21 s vertical 1080×1920
  gameplay montage, regenerable with `scripts/dev/promo_video.gd` (see HOW_TO.md, "Promo /
  store video"). Final + sources in `~/Videos/` on the dev box.

Regenerate screenshots with the `scripts/dev/shot_*.gd` harnesses (see the top of each file).

## Keep in sync

When a user-facing feature, price, mode name, or supported-language set changes, update the matching
sentences here in **all 13 locales**. Current app state reflected below: three-move mechanic, the
game review, a daily Puzzles streak, friendly Stockfish bots, Face to Face two-player, 13 languages
(EN, FR, ES, PT, DE, IT, RU, TR, PL, ID, VI, UK, EL), 3 free games + 1 puzzle streak per day, one-time
Premium.

The Face to Face mode name in each locale matches its in-app translation (e.g. de "Zu zweit",
ru "Лицом к лицу", vi "Đối mặt"). The non-English listings were machine-translated (Claude) and are
worth a native proofread before a big marketing push.
