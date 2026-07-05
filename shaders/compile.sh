#!/usr/bin/env bash
# Compiles Arcana's HLSL shaders to .vcs (shaders/fxc/) with ShaderCompile.exe
# under wine.  Replaces the old Windows pipeline (Srlion/basic-gmod-shader's
# build_shaders.bat); the GMA packing step is not needed because
# lua/includes/modules/shader_to_gma.lua builds the GMA at runtime.
#
# Usage:
#   ./compile.sh                          # compile every *_ps*/_vs*.hlsl here
#   ./compile.sh arcana_circle_ps30 ...   # compile specific shaders (.hlsl optional)
#
# Shader model comes from the filename suffix: *30.hlsl -> SM3.0, else SM2.0b.
#
# A dedicated wine prefix (~/.cache/arcana-shadercompile, override with
# ARCANA_SHADER_WINEPREFIX) is used, and Microsoft's native d3dcompiler_47.dll
# is installed into it via winetricks on first run — with it, output bytecode
# is byte-identical to the old Windows pipeline.  Without it, wine's builtin
# HLSL compiler is used, which works but produces different bytecode.

set -uo pipefail

SHADERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPILER="$SHADERS_DIR/../tools/shadercompile/ShaderCompile.exe"
OUT_DIR="$SHADERS_DIR/fxc"
TMP_OUT="$SHADERS_DIR/shaders" # ShaderCompile always writes to <shaderpath>/shaders/fxc

export WINEPREFIX="${ARCANA_SHADER_WINEPREFIX:-$HOME/.cache/arcana-shadercompile}"
export WINEDEBUG="${WINEDEBUG:--all}"

command -v wine > /dev/null || { echo "error: wine is required" >&2; exit 1; }
[ -f "$COMPILER" ] || { echo "error: $COMPILER not found" >&2; exit 1; }

# One-time: native d3dcompiler_47 for output identical to MS fxc (best effort)
if [ ! -f "$WINEPREFIX/drive_c/windows/system32/d3dcompiler_47.dll" ] && command -v winetricks > /dev/null; then
	echo ">> installing native d3dcompiler_47 into $WINEPREFIX (one-time)"
	winetricks -q d3dcompiler_47 > /dev/null 2>&1 || echo ">> winetricks failed, using wine's builtin d3dcompiler" >&2
fi

# Resolve targets: explicit args, or every pixel/vertex shader in the directory
targets=("$@")
if [ ${#targets[@]} -eq 0 ]; then
	for f in "$SHADERS_DIR"/*_ps*.hlsl "$SHADERS_DIR"/*_vs*.hlsl; do
		[ -e "$f" ] || continue
		case "$(basename "$f")" in common*) continue ;; esac # shared includes, not entry points
		targets+=("$(basename "$f")")
	done
fi

failed=()
for t in "${targets[@]}"; do
	name="$(basename "$t" .hlsl)"

	if [ ! -f "$SHADERS_DIR/$name.hlsl" ]; then
		echo "error: $SHADERS_DIR/$name.hlsl not found" >&2
		failed+=("$name")
		continue
	fi

	ver="20b"
	case "$name" in *30) ver="30" ;; esac

	echo ">> $name (sm$ver)"
	rm -rf "$TMP_OUT"
	# ShaderCompile prints errors with file/line but always exits 0; the
	# missing .vcs below is the reliable failure signal.
	(cd "$SHADERS_DIR" && wine "$COMPILER" /O 3 -ver "$ver" -shaderpath "$SHADERS_DIR" "./$name.hlsl" 2>&1 \
		| grep -iv "^Compiling\|seconds elapsed\|^Writing\|^$\|libEGL\|pci id for fd\|dri2 screen" || true)

	if [ -f "$TMP_OUT/fxc/$name.vcs" ]; then
		mkdir -p "$OUT_DIR"
		mv -f "$TMP_OUT/fxc/$name.vcs" "$OUT_DIR/$name.vcs"
		echo "   -> fxc/$name.vcs"
	else
		echo "   COMPILE FAILED" >&2
		failed+=("$name")
	fi
done
rm -rf "$TMP_OUT"

if [ ${#failed[@]} -gt 0 ]; then
	echo "failed: ${failed[*]}" >&2
	exit 1
fi

echo "all shaders compiled."
