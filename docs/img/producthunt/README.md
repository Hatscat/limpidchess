# Product Hunt launch assets

Landscape 1270×760 images for the Product Hunt gallery (PH's recommended size; also the
right shape for the social-preview card when the launch link is shared).

- **`feature_1270x760.png`** — the feature graphic at PH size. Use it as the **first**
  gallery image, because PH uses the first image as the social preview.
- **`gallery_01..06_*.png`** — phone screenshots on the brand gradient with a caption:
  home → three moves → the reveal → puzzles → Face to Face → review.
- **`build_gallery.py`** — regenerates the six cards. Run from `docs/img/`:
  `python3 producthunt/build_gallery.py` (reads `Screenshot_*_x3.png`, needs PIL +
  OpenDyslexic fonts under `assets/fonts/`).

Suggested PH gallery order: `feature_1270x760.png`, then `gallery_01..06`. Add the promo
video (YouTube URL) too; it leads the carousel. The app icon stays as the PH **Thumbnail**,
not a gallery image.

The feature card is rendered by the same generator as the Play Store 1024×500 graphic,
[`scripts/dev/shot_feature.gd`](../../../scripts/dev/shot_feature.gd), which now takes
size/output overrides (the 1024×500 default is unchanged, pixel for pixel):

```bash
LIMPID_FEAT_W=1270 LIMPID_FEAT_H=760 \
  LIMPID_FEAT_OUT="$PWD/docs/img/producthunt/feature_1270x760.png" \
  godot --path . -s res://scripts/dev/shot_feature.gd
```
