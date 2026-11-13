#!/bin/bash
# Builds the Steam version's mod for multiplayer by invite (src/pcmod) into build/pcmod/TailcatInvites (and a .zip of
# it): the mod's DLL and manifest, plus its helper (src/tailcat/cmd/sts2-tailcat) for Windows, macOS and Linux.
# Players unzip it into the game's mods folder (README.md, "Playing with the Steam version").
#
# Usage: tools/build_pcmod.sh [--game <folder>] [--install]
#   --game     a Slay the Spire 2 install to build against (default: the Mac Steam install)
#   --install  also copy the mod into that install's mods folder (Mac Steam install only)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="$ROOT/build/tools"
OUT="$ROOT/build/pcmod"
GAME="$HOME/Library/Application Support/Steam/steamapps/common/Slay the Spire 2"; INSTALL=0
while [[ $# -gt 0 ]]; do
	case "$1" in
		--game) GAME="$2"; shift 2 ;;
		--install) INSTALL=1; shift ;;
		*) echo "usage: $0 [--game <folder>] [--install]" >&2; exit 1 ;;
	esac
done
die() { echo "error: $*" >&2; exit 1; }

DATA="$(dirname "$(find "$GAME" -name sts2.dll -path '*data_sts2_*' | sort | head -1)")"
[[ -f "$DATA/sts2.dll" && -f "$DATA/0Harmony.dll" ]] || die "no Slay the Spire 2 found in $GAME (pass --game)"

GO_VERSION="$(sed -n 's/^GO_VERSION="\(.*\)"/\1/p' "$ROOT/build.sh")"
GO="$TOOLS/go/bin/go"
if [[ ! -x "$GO" || "$("$GO" env GOVERSION 2>/dev/null)" != "go$GO_VERSION" ]]; then
	echo "==> Downloading Go $GO_VERSION"
	mkdir -p "$TOOLS" && rm -rf "$TOOLS/go"
	curl -fL --retry 3 --progress-bar -o "$TOOLS/go.tar.gz" \
		"https://go.dev/dl/go$GO_VERSION.darwin-$([[ "$(uname -m)" == arm64 ]] && echo arm64 || echo amd64).tar.gz"
	tar -xzf "$TOOLS/go.tar.gz" -C "$TOOLS" && rm "$TOOLS/go.tar.gz"
fi
DOTNET="$TOOLS/dotnet/dotnet"
[[ -x "$DOTNET" ]] || DOTNET="$(command -v dotnet)" || die "no .NET SDK: run ./build.sh once, or install .NET 9"

rm -rf "$OUT" && mkdir -p "$OUT/TailcatInvites/helper"
echo "==> Building the helper"
export GOROOT="$TOOLS/go" GOPATH="$TOOLS/go-path" GOCACHE="$TOOLS/go-cache" GOTOOLCHAIN=local GOFLAGS=-mod=readonly CGO_ENABLED=0
cd "$ROOT/src/tailcat"
"$GO" mod download github.com/tailscale/tailcat
TAGS="$(cat "$("$GO" list -m -f '{{.Dir}}' github.com/tailscale/tailcat)/build-tags.txt")"
for target in windows/amd64 windows/arm64 darwin/arm64 darwin/amd64 linux/amd64; do
	os="${target%/*}"; arch="${target#*/}"; ext=""; [[ "$os" == windows ]] && ext=".exe"
	GOOS="$os" GOARCH="$arch" "$GO" build -trimpath -buildvcs=false -tags "$TAGS" -ldflags='-s -w' \
		-o "$OUT/TailcatInvites/helper/sts2-tailcat-$os-$arch$ext" ./cmd/sts2-tailcat
done

echo "==> Building the mod against $DATA"
cp -R "$ROOT/src/pcmod" "$OUT/src"
"$DOTNET" build "$OUT/src/TailcatInvites.csproj" -c Release -nologo -v quiet -p:GameDataDir="$DATA" \
	-o "$OUT/dll" > "$OUT/dotnet.log" 2>&1 || { tail -n 30 "$OUT/dotnet.log" >&2; die "mod build failed"; }
cp "$OUT/dll/TailcatInvites.dll" "$ROOT/src/pcmod/TailcatInvites.json" "$OUT/TailcatInvites/"
rm -rf "$OUT/dll" "$OUT/src"
(cd "$OUT" && zip -qr TailcatInvites.zip TailcatInvites)
echo "Done: $OUT/TailcatInvites.zip"

if [[ $INSTALL -eq 1 ]]; then
	MODS="$GAME/SlayTheSpire2.app/Contents/MacOS/mods"
	[[ -d "$GAME/SlayTheSpire2.app" ]] || die "--install only knows the Mac Steam install"
	mkdir -p "$MODS" && rm -rf "$MODS/TailcatInvites" && cp -R "$OUT/TailcatInvites" "$MODS/"
	echo "Installed: $MODS/TailcatInvites"
fi
