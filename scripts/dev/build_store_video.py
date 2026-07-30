#!/usr/bin/env python3
"""Turn the vertical 1080x1920 promo master into the landscape 1920x1080 cut the Play
Store listing wants (Shorts / portrait are not eligible there).

Same look as the Product Hunt cards (docs/img/producthunt/build_gallery.py): the phone
footage sits left on the feature-graphic gradient, with an eyebrow + headline + subline
in OpenDyslexic on the right. Captions switch on the master's own scene cuts.

    python3 scripts/dev/build_store_video.py [SRC] [OUT]

Defaults to ~/Videos/limpid_chess_promo_1080x1920.mp4 ->
             ~/Videos/limpid_chess_promo_1920x1080.mp4

Re-detect the cuts after re-rendering the master (the CARDS timings below are hard-coded):
    ffmpeg -i SRC -vf "select='gt(scene,0.35)',showinfo" -f null - 2>&1 | grep pts_time
"""
import os
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FONTS = os.path.join(ROOT, "assets", "fonts")
BOLD = os.path.join(FONTS, "OpenDyslexic-Bold.otf")
REG = os.path.join(FONTS, "OpenDyslexic-Regular.otf")

W, H = 1920, 1080
ACCENT = (102, 189, 217)
WHITE = (237, 242, 247)
GRAY = (176, 190, 202)
MOVE_BEST = (92, 199, 133)   # UI.MOVE_BEST, the green the game reveals a best move in
G0 = (13, 15, 23)      # gradient top-left, matches shot_feature.gd
G1 = (23, 41, 54)      # gradient bottom-right

# phone plate, proportional to the 1270x760 gallery cards
PH_W, PH_H = 496, 882
PX, PY = 180, (H - PH_H) // 2
RADIUS = 39

TX = PX + PH_W + 121   # text column left edge
TW = W - TX - 97       # text column width
EYE_LH, HEAD_LH, SUB_LH = 48, 100, 60
GAP1, GAP2 = 39, 39

# (start_s, eyebrow, headline, subline) — starts are the master's scene cuts.
# No price, no "download now", no Play branding: Google rejects listing videos for those.
CARDS = [
    (0.00,  "LIMPID CHESS", "Smooth, relaxing chess",      "Find the best move each turn"),
    (3.73,  "EVERY TURN",   "Three moves, one color",      "No hints. Which one is best?"),
    (10.77, "PUZZLES",      "A streak that climbs",        "Go as far as you can"),
    (18.33, "REVIEW",       "Learn from every game",       "Replay the best line"),
    (23.00, "FACE TO FACE", "Play a friend",               "Two players, one device"),
    (25.00, "LIMPID CHESS", "Chess, without the headache", "No ads. No accounts. Offline."),
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


def build_bg(path):
    """Opaque backdrop: gradient + the phone's drop shadow."""
    card = gradient_bg().convert("RGBA")
    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    sd = Image.new("RGBA", (PH_W, PH_H), (0, 0, 0, 150))
    m = Image.new("L", (PH_W, PH_H), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, PH_W, PH_H], RADIUS, fill=255)
    sd.putalpha(m)
    shadow.paste(sd, (PX, PY + 14), sd)
    shadow = shadow.filter(ImageFilter.GaussianBlur(26))
    Image.alpha_composite(card, shadow).convert("RGB").save(path)


def build_mask(path):
    """Rounded-corner alpha mask for the footage."""
    m = Image.new("L", (PH_W, PH_H), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, PH_W, PH_H], RADIUS, fill=255)
    m.convert("RGB").save(path)


def build_fg(path, eyebrow, headline, sub):
    """Transparent overlay: the accent bezel + this segment's text block."""
    fg = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    draw = ImageDraw.Draw(fg)
    draw.rounded_rectangle([PX, PY, PX + PH_W, PY + PH_H], RADIUS,
                           outline=ACCENT + (90,), width=3)

    f_eye = ImageFont.truetype(BOLD, 38)
    f_head = ImageFont.truetype(BOLD, 82)
    f_sub = ImageFont.truetype(REG, 44)

    head_lines = wrap(draw, headline, f_head, TW)
    sub_lines = wrap(draw, sub, f_sub, TW)
    total = (EYE_LH + GAP1 + HEAD_LH * len(head_lines) + GAP2 + SUB_LH * len(sub_lines))
    y = (H - total) // 2

    draw_tracked(draw, (TX, y), eyebrow, f_eye, ACCENT, 9)
    y += EYE_LH + GAP1
    for ln in head_lines:
        draw.text((TX, y), ln, font=f_head, fill=WHITE)
        y += HEAD_LH
    y += GAP2
    for ln in sub_lines:
        draw.text((TX, y), ln, font=f_sub, fill=GRAY)
        y += SUB_LH
    fg.save(path)


def build_thumbnail(path):
    """YouTube custom thumbnail: 1280x720, two words per line, legible at 210px wide.

    Deliberately louder than the in-video cards. A thumbnail is read at thumbnail
    size, so it gets the "before move" screenshot (the three arrows are the whole
    pitch) and two short lines, the payoff line in the best-move green.
    """
    TW_, TH_ = 1280, 720
    bg = Image.new("RGB", (TW_, TH_))
    px = bg.load()
    maxd = (TW_ - 1) + (TH_ - 1)
    for y in range(TH_):
        for x in range(TW_):
            t = (x + y) / maxd
            px[x, y] = tuple(int(G0[i] + (G1[i] - G0[i]) * t) for i in range(3))
    card = bg.convert("RGBA")

    shot = Image.open(os.path.join(ROOT, "docs", "img", "Screenshot_before_move_x3.png"))
    ph = 620
    pw = round(ph * shot.size[0] / shot.size[1])
    shot = shot.resize((pw, ph), Image.LANCZOS).convert("RGBA")
    m = Image.new("L", (pw, ph), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, pw, ph], 26, fill=255)
    shot.putalpha(m)
    sx, sy = 90, (TH_ - ph) // 2

    shadow = Image.new("RGBA", (TW_, TH_), (0, 0, 0, 0))
    sd = Image.new("RGBA", (pw, ph), (0, 0, 0, 150))
    sd.putalpha(m)
    shadow.paste(sd, (sx, sy + 10), sd)
    card = Image.alpha_composite(card, shadow.filter(ImageFilter.GaussianBlur(18)))
    card.paste(shot, (sx, sy), shot)
    ImageDraw.Draw(card).rounded_rectangle([sx, sy, sx + pw, sy + ph], 26,
                                           outline=ACCENT + (90,), width=2)

    draw = ImageDraw.Draw(card)
    tx = sx + pw + 70
    tw = TW_ - tx - 56
    lines = [("Three moves.", WHITE), ("One is best.", MOVE_BEST)]

    size = 96                                    # shrink to fit the column
    while size > 40:
        f = ImageFont.truetype(BOLD, size)
        if max(draw.textlength(t, font=f) for t, _ in lines) <= tw:
            break
        size -= 2
    f_head = ImageFont.truetype(BOLD, size)
    f_eye = ImageFont.truetype(BOLD, 27)

    lh = round(size * 1.22)
    total = 34 + 30 + lh * len(lines)
    y = (TH_ - total) // 2
    draw_tracked(draw, (tx, y), "LIMPID CHESS", f_eye, ACCENT, 7)
    y += 34 + 30
    for text, fill in lines:
        draw.text((tx, y), text, font=f_head, fill=fill)
        y += lh

    card.convert("RGB").save(path)
    print("wrote", path)


def has_audio(src):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "a", "-show_entries",
         "stream=index", "-of", "csv=p=0", src],
        capture_output=True, text=True).stdout.strip()
    return bool(out)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    thumb_only = "--thumb" in sys.argv
    home = os.path.expanduser("~")
    src = args[0] if len(args) > 0 else f"{home}/Videos/limpid_chess_promo_1080x1920.mp4"
    out = args[1] if len(args) > 1 else f"{home}/Videos/limpid_chess_promo_1920x1080.mp4"

    build_thumbnail(os.path.join(ROOT, "docs", "img", "youtube_thumb_1280x720.png"))
    if thumb_only:
        return
    if not os.path.exists(src):
        sys.exit(f"source not found: {src}")

    tmp = tempfile.mkdtemp(prefix="limpid_video_")
    bg, mask = os.path.join(tmp, "bg.png"), os.path.join(tmp, "mask.png")
    build_bg(bg)
    build_mask(mask)
    fgs = []
    for i, (_, eye, head, sub) in enumerate(CARDS):
        p = os.path.join(tmp, f"fg{i}.png")
        build_fg(p, eye, head, sub)
        fgs.append(p)

    cmd = ["ffmpeg", "-y",
           "-framerate", "30", "-loop", "1", "-i", bg,
           "-i", src,
           "-framerate", "30", "-loop", "1", "-i", mask]
    for p in fgs:
        cmd += ["-framerate", "30", "-loop", "1", "-i", p]

    # footage -> rounded corners -> onto the backdrop -> caption plates gated by time
    graph = [f"[1:v]scale={PH_W}:{PH_H},format=rgba,fps=30[v]",
             "[v][2:v]alphamerge[va]",
             f"[0:v][va]overlay={PX}:{PY}[base]"]
    label = "base"
    for i, (start, *_rest) in enumerate(CARDS):
        end = CARDS[i + 1][0] if i + 1 < len(CARDS) else 10_000
        nxt = f"b{i}" if i + 1 < len(CARDS) else "outv"
        graph.append(f"[{label}][{i + 3}:v]overlay=0:0:"
                     f"enable='between(t,{start},{end})'[{nxt}]")
        label = nxt
    graph.append("[outv]format=yuv420p[out]")

    cmd += ["-filter_complex", ";".join(graph), "-map", "[out]"]
    if has_audio(src):
        cmd += ["-map", "1:a", "-c:a", "aac", "-b:a", "192k"]
    cmd += ["-c:v", "libx264", "-crf", "18", "-preset", "slow",
            "-pix_fmt", "yuv420p", "-movflags", "+faststart", "-shortest", out]

    print(" ".join(cmd))
    subprocess.run(cmd, check=True)
    print("wrote", out)


if __name__ == "__main__":
    main()
