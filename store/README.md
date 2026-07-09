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
  tr-TR/  pl-PL/  id/  vi/  uk/  el/
    title.txt              # app name, max 30 chars
    short_description.txt   # one line, max 80 chars
    full_description.txt    # max 4000 chars
```

13 locales, matching the app's in-app languages. Google Play locale codes for Indonesian, Vietnamese,
Ukrainian and Greek have no country suffix (`id`, `vi`, `uk`, `el`); Portuguese uses `pt-BR` (Brazil).
The "Available in N languages" bullet in every full_description hard-codes the count, so bump it when
the language set changes.

## Graphics (already in the repo, not duplicated here)

The listing images live under [`docs/img/`](../docs/img) (shared with the website):

- **Phone screenshots** (1080×1920-ish, upload these): `Screenshot_home_x3.png`,
  `Screenshot_before_move_x3.png`, `Screenshot_after_move_x3.png`, `Screenshot_moves_review_x3.png`,
  `Screenshot_puzzle_x3.png`, `Screenshot_facetoface_x3.png`, `Screenshot_review_x3.png`
- **Feature graphic** (1024×500): `feature_graphic.png`
- **App icon** (512×512): `icon.png`

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
