#!/usr/bin/env python3
"""Build landscape 1270x760 Product Hunt gallery cards: a phone screenshot on the
feature-graphic's dark gradient, with an eyebrow + headline + subline in OpenDyslexic.
Run from docs/img/ (reads Screenshot_*_x3.png, writes producthunt/gallery_NN_*.png)."""
import os
from PIL import Image, ImageDraw, ImageFont, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
IMG = os.path.dirname(HERE)                       # docs/img
FONTS = "/home/lucien/limpid-chess/assets/fonts"
BOLD = os.path.join(FONTS, "OpenDyslexic-Bold.otf")
REG = os.path.join(FONTS, "OpenDyslexic-Regular.otf")

W, H = 1270, 760
ACCENT = (102, 189, 217)
WHITE = (237, 242, 247)
GRAY = (176, 190, 202)
# feature-graphic gradient endpoints
G0 = (13, 15, 23)      # top-left  (0.05,0.06,0.09)
G1 = (23, 41, 54)      # bottom-right (0.09,0.16,0.21)

# (screenshot, eyebrow, headline, subline)
CARDS = [
    ("home",         "LIMPID CHESS", "Smooth, relaxing chess",   "Find the best move each turn"),
    ("before_move",  "EVERY TURN",   "Three moves, one color",   "No hints. Which one is best?"),
    ("after_move",   "THE REVEAL",   "See why",                  "Green best, blue OK, red blunder"),
    ("puzzle",       "PUZZLES",      "A streak that climbs",     "Go as far as you can"),
    ("facetoface",   "FACE TO FACE", "Play a friend",            "Two players, one device"),
    ("moves_review", "REVIEW",       "Learn from every game",    "Replay the best line"),
]


def gradient_bg():
    """Diagonal top-left -> bottom-right gradient, matching shot_feature.gd."""
    bg = Image.new("RGB", (W, H))
    px = bg.load()
    maxd = (W - 1) + (H - 1)
    for y in range(H):
        for x in range(W):
            t = (x + y) / maxd
            px[x, y] = tuple(int(G0[i] + (G1[i] - G0[i]) * t) for i in range(3))
    return bg


def rounded(im, radius):
    """Return im as RGBA with rounded corners."""
    im = im.convert("RGBA")
    mask = Image.new("L", im.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, im.size[0], im.size[1]], radius, fill=255)
    im.putalpha(mask)
    return im


def wrap(draw, text, font, max_w):
    words, lines, cur = text.split(), [], ""
    for w in words:
        trial = (cur + " " + w).strip()
        if draw.textlength(trial, font=font) <= max_w:
            cur = trial
        else:
            if cur:
                lines.append(cur)
            cur = w
    if cur:
        lines.append(cur)
    return lines


def draw_tracked(draw, xy, text, font, fill, tracking):
    """Draw text with extra letter spacing (for the eyebrow)."""
    x, y = xy
    for ch in text:
        draw.text((x, y), ch, font=font, fill=fill)
        x += draw.textlength(ch, font=font) + tracking


def build(name, eyebrow, headline, sub, idx):
    card = gradient_bg()

    # --- phone screenshot, left third, rounded + border + soft shadow ---
    shot = Image.open(os.path.join(IMG, f"Screenshot_{name}_x3.png"))
    ph_h = 620
    ph_w = round(ph_h * shot.size[0] / shot.size[1])
    shot = shot.resize((ph_w, ph_h), Image.LANCZOS)
    shot = rounded(shot, 26)
    px, py = 120, (H - ph_h) // 2

    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    sd = Image.new("RGBA", (ph_w, ph_h), (0, 0, 0, 150))
    sd = rounded(sd, 26)
    shadow.paste(sd, (px, py + 10), sd)
    shadow = shadow.filter(ImageFilter.GaussianBlur(18))
    card = Image.alpha_composite(card.convert("RGBA"), shadow)
    card.paste(shot, (px, py), shot)
    # thin accent-tinted border
    ImageDraw.Draw(card).rounded_rectangle(
        [px, py, px + ph_w, py + ph_h], 26, outline=(102, 189, 217, 90), width=2)

    draw = ImageDraw.Draw(card)
    f_eye = ImageFont.truetype(BOLD, 25)
    f_head = ImageFont.truetype(BOLD, 54)
    f_sub = ImageFont.truetype(REG, 29)

    tx = px + ph_w + 80          # text column left edge
    tw = W - tx - 64             # text column width
    head_lines = wrap(draw, headline, f_head, tw)
    sub_lines = wrap(draw, sub, f_sub, tw)

    # measure total block height (line boxes + gaps) to vertically center it
    EYE_LH, HEAD_LH, SUB_LH = 32, 66, 40
    GAP1, GAP2 = 26, 26
    total = EYE_LH + GAP1 + HEAD_LH * len(head_lines) + GAP2 + SUB_LH * len(sub_lines)
    y = (H - total) // 2

    draw_tracked(draw, (tx, y), eyebrow, f_eye, ACCENT, 6)
    y += EYE_LH + GAP1
    for ln in head_lines:
        draw.text((tx, y), ln, font=f_head, fill=WHITE)
        y += HEAD_LH
    y += GAP2
    for ln in sub_lines:
        draw.text((tx, y), ln, font=f_sub, fill=GRAY)
        y += SUB_LH

    out = os.path.join(HERE, f"gallery_{idx:02d}_{name}.png")
    card.convert("RGB").save(out)
    print("wrote", os.path.basename(out))


if __name__ == "__main__":
    for i, (name, eye, head, sub) in enumerate(CARDS, start=1):
        build(name, eye, head, sub, i)
