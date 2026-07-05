# Play Store listing

Versioned source for the Google Play **store listing text**, so it stays in sync with the app and
never lives only in the Play Console. Publishing is still manual (copy/paste into the Play Console),
but this is the single source of truth to copy from and to edit when features change.

## Layout

One folder per Play Console locale, with plain-text files named to match the
[Fastlane `supply`](https://docs.fastlane.tools/actions/supply/) convention (so it can feed automation
later):

```
store/
  en-US/  fr-FR/  es-ES/
    title.txt              # app name, max 30 chars
    short_description.txt   # one line, max 80 chars
    full_description.txt    # max 4000 chars
```

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
sentences here in **all three locales**. Current app state reflected below: three-move mechanic, the
game review, a daily Puzzles streak, friendly Stockfish bots, Face to Face two-player, EN/FR/ES,
3 free games + 1 puzzle streak per day, one-time Premium.
