class_name UI

## Shared UI tokens: colors, font sizes, spacings, and chess-board palette.
## The OpenDyslexic font + default font color/size live in
## [assets/default_theme.tres] (auto-applied via project.godot).
## This file is the single source of truth for everything else.
##
## Usage: reference these constants from scripts when adding controls / drawing
## dynamically. Static .tscn values must MIRROR these numbers; if you change a
## token here, search the scenes for the old literal and update it consistently.

# --- Core color palette (calm, "limpid" dark theme) ---

## Primary page background (Home, Bots, Premium, About, Game).
const BG_DARK := Color(0.09, 0.10, 0.12, 1)
## Slightly darker background used for the nav bar / panels.
const BG_PANEL := Color(0.07, 0.08, 0.10, 1)
## Card / pill surface color (one step lighter than BG_DARK).
const SURFACE := Color(0.13, 0.14, 0.17, 1)
## Pressed-state card surface.
const SURFACE_PRESSED := Color(0.11, 0.12, 0.15, 1)
## Subtle 1px hairline border on surfaces.
const BORDER_SUBTLE := Color(1, 1, 1, 0.08)

## Brand accent — a clear, limpid cyan. Used sparingly for emphasis.
const ACCENT := Color(0.40, 0.74, 0.85, 1)
## Pressed/!darker accent.
const ACCENT_DEEP := Color(0.28, 0.58, 0.70, 1)

## Default text color (theme default).
const TEXT_PRIMARY := Color(1, 1, 1, 1)
## Secondary text — body content that's not the focus.
const TEXT_DIM := Color(1, 1, 1, 0.6)
## Tertiary text — captions, hints, inactive nav labels.
const TEXT_FADED := Color(1, 1, 1, 0.45)

# --- Chess board palette ---

## Light squares — soft, low-glare off-white.
const BOARD_LIGHT := Color(0.90, 0.91, 0.89, 1)
## Dark squares — calm slate blue (the "limpid water" feel).
const BOARD_DARK := Color(0.46, 0.57, 0.66, 1)
## Last move played, tinted per side so it's clear who moved last.
const HL_LAST_WHITE := Color(0.96, 0.84, 0.36, 0.45)  ## warm amber = White's last move
const HL_LAST_BLACK := Color(0.66, 0.56, 0.96, 0.48)  ## cool violet = Black's last move
## Square the player has tapped / is moving from.
const HL_SELECTED := Color(0.40, 0.74, 0.85, 0.55)
## King-in-check square.
const HL_CHECK := Color(0.92, 0.36, 0.36, 0.70)
## Dot marking a legal destination square.
const HL_LEGAL := Color(0.06, 0.07, 0.09, 0.28)

# --- The three guided move options (best / not-bad / blunder) ---
# These tint the interactive arrows AND any chips that describe them.

## The engine's best move. Calm green.
const MOVE_BEST := Color(0.36, 0.78, 0.52, 1)
## A solid, "not bad" alternative. Friendly blue.
const MOVE_DECENT := Color(0.46, 0.66, 0.95, 1)
## A tempting mistake — the blunder option. Warm, soft red.
const MOVE_BLUNDER := Color(0.91, 0.49, 0.44, 1)

## Reward currencies / feedback accents.
const COIN_BEST := Color(0.98, 0.80, 0.34, 1)   ## gold "best move" coin
const COIN_BLUNDER := Color(0.78, 0.45, 0.40, 1) ## the "blunder" coin tally

# --- Type scale (font sizes in px) ---

## Page-banner title (Bots, Premium, About hero titles).
const FONT_DISPLAY := 40
## Compact title (Home / Game top bar, embedded with siblings).
const FONT_TITLE := 32
## Section heading.
const FONT_HEADING := 28
## Default body size (theme default, used implicitly by most labels).
const FONT_BODY := 20
## Small label (nav tabs, captions, secondary metadata).
const FONT_CAPTION := 16
## Smallest legible size (eyebrow text like "FIND · THE · BEST · MOVE").
const FONT_MICRO := 12

# --- Spacing & sizing ---

## Standard page side padding.
const PADDING_PAGE := 24
## Standard card / panel internal padding.
const PADDING_CARD := 16
## Standard corner radius for cards.
const RADIUS_CARD := 28
## Standard corner radius for pills / chips.
const RADIUS_PILL := 22

## Fixed-bottom navigation bar visual height.
const NAV_HEIGHT := 128
## Page bottom offset to keep content above the nav bar (NAV_HEIGHT + breathing room).
const NAV_BOTTOM_GAP := 136
