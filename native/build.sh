#!/usr/bin/env bash
# Build the Stockfish GDExtension for Android (arm64). One command, from scratch:
# downloads the NDK + SCons + godot-cpp + Stockfish 11, then compiles the .so
# into ../addons/stockfish/bin/. Re-running is incremental (skips what exists).
#
#   cd native && ./build.sh
#
# Requirements on the build machine: bash, git, curl, unzip, python3, ~3 GB free.
# A C++ host compiler is NOT needed for Android (the NDK ships clang). It IS
# needed only for the optional desktop target (see the bottom of this script).
#
# Override anything via env vars, e.g.:
#   ANDROID_NDK_ROOT=~/Android/Sdk/ndk/23.2.8568313 ./build.sh
set -euo pipefail
cd "$(dirname "$0")"
HERE="$PWD"

NDK_VERSION="${NDK_VERSION:-r23c}"
GODOT_CPP_BRANCH="${GODOT_CPP_BRANCH:-4.5}"
STOCKFISH_TAG="${STOCKFISH_TAG:-sf_11}"
ANDROID_API="${ANDROID_API:-24}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"

say() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }

# --- 1. Android NDK ---------------------------------------------------------
if [ -z "${ANDROID_NDK_ROOT:-}" ]; then
	if [ -d "$HERE/android-ndk-$NDK_VERSION" ]; then
		ANDROID_NDK_ROOT="$HERE/android-ndk-$NDK_VERSION"
	else
		say "Downloading Android NDK $NDK_VERSION (~1 GB)…"
		curl -fL "https://dl.google.com/android/repository/android-ndk-$NDK_VERSION-linux.zip" -o ndk.zip
		unzip -q ndk.zip -d "$HERE"
		rm -f ndk.zip
		ANDROID_NDK_ROOT="$HERE/android-ndk-$NDK_VERSION"
	fi
fi
export ANDROID_NDK_ROOT
echo "NDK: $ANDROID_NDK_ROOT"

# --- 2. SCons ---------------------------------------------------------------
if command -v scons >/dev/null 2>&1; then
	SCONS=(scons)
elif python3 -m pip --version >/dev/null 2>&1; then
	python3 -m pip install --user --quiet scons
	SCONS=(python3 -m SCons)
else
	# No pip: vendor SCons from a wheel (it's pure Python).
	if [ ! -d "$HERE/.scons" ]; then
		say "Vendoring SCons (no pip available)…"
		curl -fL "https://files.pythonhosted.org/packages/py3/S/SCons/SCons-4.8.1-py3-none-any.whl" -o scons.whl
		mkdir -p "$HERE/.scons" && unzip -q scons.whl -d "$HERE/.scons" && rm -f scons.whl
	fi
	export PYTHONPATH="$HERE/.scons:${PYTHONPATH:-}"
	SCONS=(python3 -m SCons)
fi
echo "SCons: ${SCONS[*]}"

# --- 3. Sources -------------------------------------------------------------
[ -d godot-cpp ] || { say "Cloning godot-cpp ($GODOT_CPP_BRANCH)…"; \
	git clone --depth 1 --branch "$GODOT_CPP_BRANCH" https://github.com/godotengine/godot-cpp.git; }
[ -d stockfish ] || { say "Cloning Stockfish ($STOCKFISH_TAG)…"; \
	git clone --depth 1 --branch "$STOCKFISH_TAG" https://github.com/official-stockfish/Stockfish.git stockfish; }
# (Stockfish's C++11-vs-C++17 clamp ambiguity is handled in SConstruct by
#  compiling the Stockfish sources at -std=c++11 — no source patch needed.)

mkdir -p ../addons/stockfish/bin

# --- 4. Build Android arm64 (debug + release) -------------------------------
for TARGET in template_debug template_release; do
	say "Building android arm64 $TARGET…"
	# ANDROID_HOME= forces godot-cpp to use ANDROID_NDK_ROOT (our downloaded NDK)
	# instead of looking for $ANDROID_HOME/ndk/<version>.
	"${SCONS[@]}" platform=android arch=arm64 target="$TARGET" \
		android_api_level="$ANDROID_API" "ANDROID_HOME=" -j"$JOBS"
done

# --- 5. Optional desktop build (only if a host C++ compiler is present) ------
# Building desktop too makes the editor load the embedded engine on desktop as
# well (consistent everywhere). Without it, desktop falls back to the subprocess.
if [ "${BUILD_DESKTOP:-1}" = "1" ] && { command -v g++ >/dev/null || command -v clang++ >/dev/null; }; then
	for TARGET in template_debug template_release; do
		say "Building linux x86_64 $TARGET…"
		"${SCONS[@]}" platform=linux arch=x86_64 target="$TARGET" -j"$JOBS" || \
			echo "(desktop build failed — Android libs are still fine)"
	done
else
	echo "Skipping desktop build (no host g++/clang, or BUILD_DESKTOP=0)."
fi

# --- 6. Generate the .gdextension from what actually built ------------------
GDEXT=../addons/stockfish/stockfish.gdextension
shopt -s nullglob
LIBS=(../addons/stockfish/bin/libstockfish_gd.*)
if [ ${#LIBS[@]} -gt 0 ]; then
	{
		echo "[configuration]"
		echo 'entry_symbol = "stockfish_library_init"'
		echo 'compatibility_minimum = "4.5"'
		echo ""
		echo "[libraries]"
		for f in "${LIBS[@]}"; do
			base=$(basename "$f")
			mid=${base#libstockfish_gd.}; mid=${mid%.*}   # platform.template_x.arch
			platform=${mid%%.*}; rest=${mid#*.}; tgt=${rest%%.*}; arch=${rest#*.}
			cfg=release; [ "$tgt" = "template_debug" ] && cfg=debug
			echo "$platform.$cfg.$arch = \"res://addons/stockfish/bin/$base\""
		done
	} > "$GDEXT"
	say "Wrote $GDEXT — the embedded engine is now active. Built libraries:"
	ls -la ../addons/stockfish/bin/
	cat <<EOF

Next:
  • Open the project once so Godot registers the StockfishGD class.
  • Export the Android APK/AAB and run on a device — it now embeds Stockfish.
  • Emulator? re-run with arch=x86_64 to add that slice.
  • Desktop is unaffected: with only Android entries, Godot skips the extension on
    desktop (no error) and the game uses the Stockfish subprocess there. Build the
    desktop lib too (host compiler required) only if you want the embedded engine
    on desktop as well.
EOF
else
	echo "No libraries were produced — not writing the .gdextension."
fi
