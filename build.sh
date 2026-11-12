#!/bin/bash
# Builds Slay the Spire 2 for iPhone/iPad from your own copy of the game. See README.md.
set -euo pipefail

TESTED_GAME_VERSION="v0.107.1" # Steam's public branch
TESTED_BETA_VERSION="v0.113.0" # Steam's public-beta branch
GODOT_VERSION="4.5.1"
DOTNET_VERSION="9.0.318"
GDRE_VERSION="2.7.0"
FMOD_GDE_VERSION="6.1.0-4.5.0"
SPINE_VERSION="4.2"
GO_VERSION="1.27.2"

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
# .NET's iOS linker step breaks on paths with spaces, so build elsewhere if this folder's path has one.
if [[ "$BUILD" == *" "* ]]; then BUILD="$HOME/Library/Caches/sts2-ios-launch"; fi
TOOLS="$BUILD/tools"
WORK="$BUILD/work"
LOGS="$BUILD/logs"

usage() {
	cat <<EOF
Usage: ./build.sh --game <folder> [options]

  --game <folder>     Your Slay the Spire 2 install: the game folder copied from a PC, or the Mac Steam
                      folder. Default: ~/Library/Application Support/Steam/steamapps/common/Slay the Spire 2
  --team <id>         Apple team ID to sign with (Xcode > Settings > Accounts). Default: your only team in Xcode.
  --unsigned          Make an unsigned .ipa for Sideloadly/AltStore instead of signing with Xcode.
  --install           Install on the connected iPhone/iPad after building (signed builds only).
  --device <udid>     Which device to install on (default: the first connected one).
  --simulator         Build for the iOS Simulator on an Apple silicon Mac instead, e.g. to check layouts on the
                      iPhone Duo Simulator (Xcode 27.1+). With --install, installs on --device <simulator udid> or
                      the booted Simulator. Rendering there is only approximate (src/ios/simulator_metal.m).
  --bundle-id <id>    App bundle ID. Default: com.sts2ios.<team id> (or com.sts2ios.app when unsigned).
  --xcode <path>      Xcode (26 or newer) to build with. Default: the newest in /Applications, ~/Applications and
                      ~/Downloads. Xcode 27.1+ makes the game fill an iPhone Duo's screens (see README).
  --icon game         Use the game's own pixel-art icon instead of rendering the Ironclad close-up.
  --clean             Delete build/work first (downloaded tools are kept).
  --no-ota            Don't download script updates (see tools/ota.sh) in the app.
  --ota-url <url>     Where the app looks for script updates (a fork's own "ota" release).
  --shaders <folder>  Shader cache and pipelines harvested from a device (tools/harvest_shaders.sh) to precompile
                      into the app and warm up in the background at launch, so new effects don't freeze the game
                      while iOS compiles them. Default: build/shader-cache if it exists.

Everything goes in build/ (or ~/Library/Caches/sts2-ios-launch if this folder's path contains a space).
EOF
}

die() { echo "error: $*" >&2; exit 1; }
[[ "$BUILD" != *" "* ]] || die "the build folder can't have spaces in its path: $BUILD"
# Paths inside the repo are shown relative to it.
show() { local p="${1#$ROOT/}"; echo "$p"; }
step() { echo "==> $*"; }

GAME_DIR="${STS2_GAME_DIR:-}"; TEAM=""; UNSIGNED=0; INSTALL=0; DEVICE=""; BUNDLE_ID=""; XCODE_APP="${XCODE_APP:-}"; SIM=0
ICON_MODE="ironclad"; CLEAN=0
OTA=1; OTA_URL="https://github.com/FlyingViet/sts2-ios-launch/releases/download/ota/"; SHADERS=""
while [[ $# -gt 0 ]]; do
	case "$1" in
		--game) GAME_DIR="$2"; shift 2 ;;
		--team) TEAM="$2"; shift 2 ;;
		--unsigned) UNSIGNED=1; shift ;;
		--install) INSTALL=1; shift ;;
		--device) DEVICE="$2"; shift 2 ;;
		--simulator) SIM=1; shift ;;
		--bundle-id) BUNDLE_ID="$2"; shift 2 ;;
		--xcode) XCODE_APP="$2"; shift 2 ;;
		--icon) ICON_MODE="$2"; shift 2 ;;
		--clean) CLEAN=1; shift ;;
		--no-ota) OTA=0; shift ;;
		--ota-url) OTA_URL="$2"; shift 2 ;;
		--shaders) SHADERS="$2"; shift 2 ;;
		-h|--help) usage; exit 0 ;;
		*) usage; die "unknown option $1" ;;
	esac
done
[[ "$ICON_MODE" == "ironclad" || "$ICON_MODE" == "game" ]] || die "--icon must be 'game' (or omitted)"
[[ $UNSIGNED -eq 1 && $INSTALL -eq 1 ]] && die "--install needs a signed build; drop --unsigned"
[[ $SIM -eq 1 && $UNSIGNED -eq 1 ]] && die "--simulator builds aren't signed anyway; drop --unsigned"
[[ $SIM -eq 1 && "$(uname -m)" != "arm64" ]] && die "--simulator needs an Apple silicon Mac"
if [[ -n "$SHADERS" ]]; then
	[[ -d "$SHADERS" ]] || die "no such folder: $SHADERS"
	SHADERS="$(cd "$SHADERS" && pwd)"
elif [[ -d "$BUILD/shader-cache" ]]; then
	SHADERS="$BUILD/shader-cache"
fi

# Runs a command with its output in build/logs/<name>.log. run_ok returns its status; run stops the build with
# the end of the log if it fails.
run_ok() { local name="$1"; shift; "$@" > "$LOGS/$name.log" 2>&1; }
run() {
	local name="$1"; shift
	if ! run_ok "$name" "$@"; then
		echo "---- last lines of $(show "$LOGS/$name.log") ----" >&2
		tail -n 40 "$LOGS/$name.log" >&2
		die "$name failed (full log: $(show "$LOGS/$name.log"))"
	fi
}

# Fingerprint of files/folders/strings, to skip stages whose inputs didn't change.
fingerprint() {
	local x
	for x in "$@"; do
		if [[ -d "$x" ]]; then (cd "$x" && find . -type f ! -name '.DS_Store' | LC_ALL=C sort | xargs -I{} shasum "{}")
		elif [[ -f "$x" ]]; then shasum "$x"
		else echo "$x"; fi
	done | shasum | cut -d' ' -f1
}
up_to_date() { [[ -f "$WORK/$1.stamp" && "$(cat "$WORK/$1.stamp")" == "$2" ]]; }
mark_done() { echo "$2" > "$WORK/$1.stamp"; }

# ---------------------------------------------------------------------------------------------------- host
[[ "$(uname)" == "Darwin" ]] || die "this needs a Mac"
command -v python3 >/dev/null && python3 -c 1 2>/dev/null || die "python3 is missing: install Xcode first"
[[ $CLEAN -eq 1 ]] && rm -rf "$WORK"
mkdir -p "$TOOLS" "$WORK" "$LOGS"

# ---------------------------------------------------------------------------------------------------- Xcode
# Xcode 26 or newer; the newest one found is used. Built with the iOS 27.1 SDK (Xcode 27.1+), the game fills both
# screens of an iPhone Duo and follows it opening and closing; older SDKs give it a fixed iPhone-sized window there.
# Godot 4.5 doesn't use UIScene, which the iOS 27 SDK requires: src/ios/scene_delegate.cpp adds it.
xcode_major() { defaults read "$1/Contents/Info" CFBundleShortVersionString 2>/dev/null | cut -d. -f1; }
xcode_ok() { local m; m="$(xcode_major "$1")"; [[ "$m" =~ ^[0-9]+$ && "$m" -ge 26 ]]; }
if [[ -z "$XCODE_APP" ]]; then
	best=""; bestv=""
	for x in /Applications/Xcode*.app "$HOME/Applications"/Xcode*.app "$HOME/Downloads"/Xcode*.app \
		"$(dirname "$(dirname "$(xcode-select -p 2>/dev/null || echo /x/x)")")"; do
		[[ -d "$x" ]] && xcode_ok "$x" || continue
		v="$(defaults read "$x/Contents/Info" CFBundleShortVersionString)"
		if [[ -z "$best" ]] || [[ "$(printf '%s\n%s\n' "$bestv" "$v" | sort -V | tail -1)" == "$v" ]]; then best="$x"; bestv="$v"; fi
	done
	[[ -n "$best" ]] || die "Xcode 26 or newer not found. Install Xcode from the App Store (or
       https://developer.apple.com/download/all/), open it once, then run this again.
       Or point to it with --xcode /path/to/Xcode.app"
	XCODE_APP="$best"
fi
xcode_ok "$XCODE_APP" || die "$XCODE_APP is older than Xcode 26"
export DEVELOPER_DIR="$XCODE_APP/Contents/Developer"
xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1 || die "Xcode needs its first-launch setup: open $XCODE_APP once (or run
       sudo DEVELOPER_DIR=\"$DEVELOPER_DIR\" xcodebuild -runFirstLaunch), then run this again"
IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)" || die "the iOS SDK is missing from $XCODE_APP"
echo "Xcode: $XCODE_APP ($(defaults read "$XCODE_APP/Contents/Info" CFBundleShortVersionString))"

# ---------------------------------------------------------------------------------------------------- game files
if [[ -z "$GAME_DIR" ]]; then
	GAME_DIR="$HOME/Library/Application Support/Steam/steamapps/common/Slay the Spire 2"
	[[ -d "$GAME_DIR" ]] || { usage; die "pass --game <your Slay the Spire 2 folder>"; }
fi
[[ -d "$GAME_DIR" ]] || die "no such folder: $GAME_DIR"
GAME_DIR="$(cd "$GAME_DIR" && pwd)"
STS2_DLL="$(find "$GAME_DIR" -maxdepth 6 -name sts2.dll -type f | head -1 || true)"
[[ -n "$STS2_DLL" ]] || die "sts2.dll not found under $GAME_DIR: is this the Slay the Spire 2 folder?"
GAME_DATA="$(dirname "$STS2_DLL")"
PCK="$(find "$GAME_DIR" -maxdepth 6 -name 'SlayTheSpire2.pck' -type f | head -1 || true)"
[[ -n "$PCK" ]] || PCK="$(find "$GAME_DIR" -maxdepth 6 -name '*.pck' -type f -size +500M | head -1 || true)"
[[ -n "$PCK" ]] || die "SlayTheSpire2.pck not found under $GAME_DIR"
for f in GodotSharp.dll SmartFormat.dll; do [[ -f "$GAME_DATA/$f" ]] || die "$f missing next to sts2.dll"; done
GAME_VERSION="$TESTED_GAME_VERSION"
INFO="$(find "$GAME_DIR" -maxdepth 6 -name release_info.json -type f | head -1 || true)"
if [[ -n "$INFO" ]]; then GAME_VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$INFO")"; fi
echo "Game: $GAME_VERSION"
echo "      $PCK"
echo "      $GAME_DATA"
if [[ "$GAME_VERSION" != "$TESTED_GAME_VERSION" && "$GAME_VERSION" != "$TESTED_BETA_VERSION" ]]; then
	echo "warning: this was tested with $TESTED_GAME_VERSION (Steam's public branch) and $TESTED_BETA_VERSION (its beta)."
	echo "         Other versions may fail to patch, and multiplayer needs every player on the same version."
fi
SHORT_VERSION="${GAME_VERSION#v}"

# ---------------------------------------------------------------------------------------------------- signing
if [[ $UNSIGNED -eq 0 && -z "$TEAM" ]]; then
	# Simulator builds aren't signed; a team only keeps the Xcode project the same as for device builds.
	TEAMS="$(defaults export com.apple.dt.Xcode - 2>/dev/null | python3 -c '
import plistlib, sys
try: d = plistlib.loads(sys.stdin.buffer.read())
except Exception: d = {}
seen = {}
for teams in d.get("IDEProvisioningTeamByIdentifier", {}).values():
    for t in teams:
        seen[t["teamID"]] = t.get("teamName", "") + (" (Personal Team)" if t.get("isFreeProvisioningTeam") else "")
for k, v in seen.items(): print(k, v)
')"
	case "$(printf '%s' "$TEAMS" | grep -c . || true)" in
		0) [[ $SIM -eq 1 ]] && UNSIGNED=1 || die "no Apple account in Xcode. Either add your Apple ID in Xcode > Settings > Accounts (a free one works)
       and run this again, or build with --unsigned and install the .ipa with Sideloadly/AltStore" ;;
		1) TEAM="$(printf '%s' "$TEAMS" | cut -d' ' -f1)" ;;
		*) if [[ $SIM -eq 1 ]]; then UNSIGNED=1; else printf 'Teams in Xcode:\n%s\n' "$TEAMS"; die "pick one with --team <id>"; fi ;;
	esac
fi
if [[ $UNSIGNED -eq 1 ]]; then
	EXPORT_TEAM="AAAAAAAAAA"; BUNDLE_ID="${BUNDLE_ID:-com.sts2ios.app}"
	if [[ $SIM -eq 1 ]]; then echo "Signing: none (Simulator)"; else echo "Signing: none (unsigned .ipa)"; fi
else
	EXPORT_TEAM="$TEAM"; BUNDLE_ID="${BUNDLE_ID:-com.sts2ios.$(echo "$TEAM" | tr '[:upper:]' '[:lower:]')}"
	echo "Signing: team $TEAM"
fi
echo "Bundle ID: $BUNDLE_ID"

# ---------------------------------------------------------------------------------------------------- tools
export PATH="$TOOLS/dotnet:$PATH" DOTNET_ROOT="$TOOLS/dotnet" NUGET_PACKAGES="$TOOLS/nuget" DOTNET_CLI_HOME="$TOOLS/dotnet-home" \
	DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
GODOT="$TOOLS/godot/Godot_mono.app/Contents/MacOS/Godot"
GDRE="$TOOLS/gdre/Godot RE Tools.app/Contents/MacOS/Godot RE Tools"

fetch() { curl -fL --retry 3 --progress-bar -o "$2" "$1" || die "download failed: $1"; }

if [[ ! -x "$TOOLS/dotnet/dotnet" || "$("$TOOLS/dotnet/dotnet" --version 2>/dev/null)" != "$DOTNET_VERSION" ]]; then
	step "Downloading .NET SDK $DOTNET_VERSION"
	fetch https://dot.net/v1/dotnet-install.sh "$TOOLS/dotnet-install.sh"
	run dotnet-install bash "$TOOLS/dotnet-install.sh" --version "$DOTNET_VERSION" --install-dir "$TOOLS/dotnet" --no-path
fi
if [[ ! -f "$TOOLS/godot/.ok-$GODOT_VERSION" ]]; then
	step "Downloading Godot $GODOT_VERSION (.NET)"
	rm -rf "$TOOLS/godot" && mkdir -p "$TOOLS/godot"
	fetch "https://github.com/godotengine/godot/releases/download/$GODOT_VERSION-stable/Godot_v$GODOT_VERSION-stable_mono_macos.universal.zip" "$TOOLS/godot.zip"
	run godot-unzip ditto -x -k "$TOOLS/godot.zip" "$TOOLS/godot" && rm "$TOOLS/godot.zip"
	touch "$TOOLS/godot/._sc_" # self-contained: editor settings stay in build/tools/godot
	step "Downloading the Godot iOS export template"
	(cd "$TOOLS/godot" && run godot-template python3 "$ROOT/tools/rangezip.py" \
		"https://github.com/godotengine/godot/releases/download/$GODOT_VERSION-stable/Godot_v$GODOT_VERSION-stable_mono_export_templates.tpz" \
		templates/ios.zip)
	touch "$TOOLS/godot/.ok-$GODOT_VERSION"
fi
if [[ ! -f "$TOOLS/gdre/.ok-$GDRE_VERSION" ]]; then
	step "Downloading GDRE Tools $GDRE_VERSION"
	rm -rf "$TOOLS/gdre" && mkdir -p "$TOOLS/gdre"
	fetch "https://github.com/GDRETools/gdsdecomp/releases/download/v$GDRE_VERSION/GDRE_tools-v$GDRE_VERSION-macos.zip" "$TOOLS/gdre.zip"
	run gdre-unzip ditto -x -k "$TOOLS/gdre.zip" "$TOOLS/gdre" && rm "$TOOLS/gdre.zip"
	[[ -x "$GDRE" ]] || die "unexpected GDRE download layout"
	touch "$TOOLS/gdre/.ok-$GDRE_VERSION"
fi
if [[ ! -f "$TOOLS/fmod/.ok-$FMOD_GDE_VERSION" ]]; then
	step "Downloading fmod-gdextension $FMOD_GDE_VERSION"
	rm -rf "$TOOLS/fmod" "$TOOLS/fmod-zip" && mkdir -p "$TOOLS/fmod-zip"
	fetch "https://github.com/utopia-rise/fmod-gdextension/releases/download/$FMOD_GDE_VERSION/addons.zip" "$TOOLS/fmod.zip"
	run fmod-unzip ditto -x -k "$TOOLS/fmod.zip" "$TOOLS/fmod-zip" && rm "$TOOLS/fmod.zip"
	mv "$TOOLS/fmod-zip/fmod" "$TOOLS/fmod" && rm -rf "$TOOLS/fmod-zip"
	mv "$TOOLS/fmod/libs/iOS" "$TOOLS/fmod/libs/ios" # the .gdextension refers to libs/ios
	rm -rf "$TOOLS/fmod/libs/android" "$TOOLS/fmod/libs/linux" "$TOOLS/fmod/libs/windows"
	touch "$TOOLS/fmod/.ok-$FMOD_GDE_VERSION"
fi
if [[ ! -f "$TOOLS/spine/.ok-$SPINE_VERSION-$GODOT_VERSION" ]]; then
	step "Downloading spine-godot $SPINE_VERSION"
	rm -rf "$TOOLS/spine" "$TOOLS/spine-zip" && mkdir -p "$TOOLS/spine-zip"
	fetch "https://spine-godot.s3.eu-central-1.amazonaws.com/$SPINE_VERSION/$GODOT_VERSION-stable/spine-godot-extension-$SPINE_VERSION-$GODOT_VERSION-stable.zip" "$TOOLS/spine.zip"
	run spine-unzip ditto -x -k "$TOOLS/spine.zip" "$TOOLS/spine-zip" && rm "$TOOLS/spine.zip"
	SP="$(dirname "$(find "$TOOLS/spine-zip" -name spine_godot_extension.gdextension | head -1 || true)")"
	[[ -d "$SP/ios" && -d "$SP/macos" ]] || die "unexpected spine-godot download layout"
	mkdir -p "$TOOLS/spine" && cp -R "$SP/ios" "$SP/macos" "$SP/spine_godot_extension.gdextension" "$TOOLS/spine/"
	rm -rf "$TOOLS/spine-zip"
	touch "$TOOLS/spine/.ok-$SPINE_VERSION-$GODOT_VERSION"
fi
if [[ ! -x "$TOOLS/go/bin/go" || "$("$TOOLS/go/bin/go" env GOVERSION 2>/dev/null)" != "go$GO_VERSION" ]]; then
	step "Downloading Go $GO_VERSION"
	rm -rf "$TOOLS/go"
	fetch "https://go.dev/dl/go$GO_VERSION.darwin-$([[ "$(uname -m)" == arm64 ]] && echo arm64 || echo amd64).tar.gz" "$TOOLS/go.tar.gz"
	run go-untar tar -xzf "$TOOLS/go.tar.gz" -C "$TOOLS" && rm "$TOOLS/go.tar.gz"
fi
# The prebuilt spine-godot GDExtension reads every re-created mesh back from the GPU (RenderingServer.mesh_get_surface,
# which waits for all frames in flight): a 30-40 ms freeze on an iPhone whenever an attack or hit animation changes a
# mesh. Rebuild its iOS library from the same 4.2 sources with src/spine/no-gpu-readback.patch.
SPINE_SRC_COMMIT="e7dc1435fa4a0083ab431f1b28e083c14a1f5c68"
GODOT_CPP_COMMIT="27d9dd23c83871e0619fca5dc2cddfbfd69e926a" # godot-cpp 4.5 branch
SPINE_PATCH_ID="$(shasum "$ROOT/src/spine/no-gpu-readback.patch" | cut -c1-12)"
SPINE_IOS_LIB="$TOOLS/spine/ios/libspine_godot.ios.template_release.framework/libspine_godot.ios.template_release"
if [[ ! -f "$TOOLS/spine/.ok-ios-${SPINE_SRC_COMMIT:0:12}-$SPINE_PATCH_ID" ]]; then
	step "Building spine-godot for iOS from source (~2 min)"
	S="$TOOLS/spine-build"; rm -rf "$S" && mkdir -p "$S"
	R="$S/spine-runtimes"
	run spine-clone git clone -q --filter=blob:none --no-checkout https://github.com/EsotericSoftware/spine-runtimes.git "$R"
	run spine-sparse git -C "$R" sparse-checkout set spine-godot spine-cpp/spine-cpp
	run spine-checkout git -C "$R" checkout -q "$SPINE_SRC_COMMIT"
	run spine-patch git -C "$R" apply "$ROOT/src/spine/no-gpu-readback.patch"
	run godot-cpp-clone git clone -q --filter=blob:none https://github.com/godotengine/godot-cpp.git "$R/spine-godot/godot-cpp"
	run godot-cpp-checkout git -C "$R/spine-godot/godot-cpp" checkout -q "$GODOT_CPP_COMMIT"
	cp -R "$R/spine-cpp/spine-cpp" "$R/spine-godot/spine_godot/"
	run scons-venv python3 -m venv "$S/venv"
	run scons-install "$S/venv/bin/pip" install -q "scons==4.11.1"
	# godot-cpp defaults to /Applications/Xcode.app's compilers; use the selected Xcode's, to match its iOS SDK.
	(cd "$R/spine-godot" && run spine-scons "$S/venv/bin/scons" -j"$(sysctl -n hw.ncpu)" platform=ios target=template_release \
		IOS_TOOLCHAIN_PATH="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain")
	cp "$R/spine-godot/bin/ios/libspine_godot.ios.template_release.framework/libspine_godot.ios.template_release" "$SPINE_IOS_LIB"
	rm -rf "$S"
	touch "$TOOLS/spine/.ok-ios-${SPINE_SRC_COMMIT:0:12}-$SPINE_PATCH_ID"
fi
TOOLS_ID="godot $GODOT_VERSION dotnet $DOTNET_VERSION gdre $GDRE_VERSION fmod $FMOD_GDE_VERSION spine $SPINE_VERSION ios ${SPINE_SRC_COMMIT:0:12} $SPINE_PATCH_ID"
PCK_ID="$(stat -f '%z %m' "$PCK") $PCK"

# ---------------------------------------------------------------------------------------------------- icon
FP="$(fingerprint "$ROOT/src/icon" "$PCK_ID" "$ICON_MODE" "$TOOLS_ID")"
if ! up_to_date icon "$FP" || [[ ! -f "$WORK/icon.png" ]]; then
	step "Making the app icon from your game files"
	rm -f "$WORK/icon.png"
	if [[ "$ICON_MODE" == "ironclad" ]]; then
		I="$WORK/icon-render"; rm -rf "$I" && mkdir -p "$I"
		if run_ok icon-recover "$GDRE" --headless --recover="$PCK" --output="$I" \
				--include="res://animations/character_select/ironclad/*" --include="res://.godot/imported/characterselect_ironclad.*" \
			&& rm -rf "$I/addons" "$I/project.godot" && mkdir -p "$I/addons/spine" "$I/.godot" \
			&& cp -R "$TOOLS/spine/." "$I/addons/spine/" && cp "$ROOT/src/icon/"* "$I/" \
			&& echo "res://addons/spine/spine_godot_extension.gdextension" > "$I/.godot/extension_list.cfg" \
			&& { (cd "$I" && "$GODOT" --headless --path . --import > "$LOGS/icon-import.log" 2>&1) || true; } \
			&& (cd "$I" && perl -e 'alarm 180; exec @ARGV' "$GODOT" --path . --script res://render.gd -- "$WORK/icon.png" > "$LOGS/icon-render.log" 2>&1) \
			&& [[ -f "$WORK/icon.png" ]]; then
			:
		else
			echo "    (couldn't render the Ironclad icon; using the game's own icon. Details in $(show "$LOGS")/icon-*.log)"
			rm -f "$WORK/icon.png"
		fi
	fi
	if [[ ! -f "$WORK/icon.png" ]]; then
		rm -rf "$WORK/icon-game"
		run icon-extract "$GDRE" --headless --extract="$PCK" --include="res://images/icon_1024.png" --output="$WORK/icon-game"
		cp "$WORK/icon-game/images/icon_1024.png" "$WORK/icon.png"
	fi
	mark_done icon "$FP"
fi

# ---------------------------------------------------------------------------------------------------- Xcode project
# Export an empty Godot C# project (named like the game's assembly) as an Xcode project: this provides the stock
# Godot 4.5.1 iOS engine with FMOD and Spine. The game's code and data are swapped in afterwards.
X="$WORK/xcode"
FP="$(fingerprint "$ROOT/src/godot" "$ROOT/src/ios" "$WORK/icon.png" "$EXPORT_TEAM $BUNDLE_ID $SHORT_VERSION plist-bgaudio-scene-wifiaware" "$TOOLS_ID")"
if ! up_to_date export "$FP" || [[ ! -d "$X/sts2.xcodeproj" ]]; then
	step "Exporting the Godot iOS project"
	P="$WORK/proj"; rm -rf "$P" && mkdir -p "$P/addons"
	cp "$ROOT/src/godot/"* "$P/" && rm "$P/export_presets.cfg.in"
	sed -e "s|@EXPORT_PATH@|$X/sts2.ipa|" -e "s|@TEMPLATE@|$TOOLS/godot/templates/ios.zip|" -e "s|@TEAM@|$EXPORT_TEAM|" \
		-e "s|@BUNDLE_ID@|$BUNDLE_ID|" -e "s|@VERSION@|$SHORT_VERSION|" "$ROOT/src/godot/export_presets.cfg.in" > "$P/export_presets.cfg"
	cp -R "$TOOLS/fmod" "$P/addons/fmod" && cp -R "$TOOLS/spine" "$P/addons/spine"
	cp "$WORK/icon.png" "$P/icon.png"
	# The .NET editor needs dotnet on PATH (set above), else it blocks on a hidden alert. Import crashes at exit: harmless.
	(cd "$P" && "$GODOT" --headless --path . --import > "$LOGS/godot-import.log" 2>&1) || true
	rm -rf "$X" && mkdir -p "$X"
	(cd "$P" && run godot-export "$GODOT" --headless --path . --export-release iOS "$X/sts2.ipa")
	[[ -d "$X/sts2.xcodeproj" ]] || die "Godot export produced no Xcode project (see $(show "$LOGS/godot-export.log"))"
	sed -i '' 's/"Apple Distribution"/"Apple Development"/g' "$X/sts2.xcodeproj/project.pbxproj"
	/usr/libexec/PlistBuddy -c "Add :godot_cmdline array" -c "Add :godot_cmdline:0 string --force-steam=off" \
		-c "Add :godot_cmdline:1 string --log-file" -c "Add :godot_cmdline:2 string user://godot.log" \
		-c "Add :NSLocalNetworkUsageDescription string Slay the Spire 2 uses your local network to host and join multiplayer games." \
		-c "Add :UIBackgroundModes array" -c "Add :UIBackgroundModes:0 string audio" \
		-c "Add :UIApplicationSceneManifest dict" \
		-c "Add :UIApplicationSceneManifest:UIApplicationSupportsMultipleScenes bool false" \
		-c "Add :UIApplicationSceneManifest:UISceneConfigurations dict" \
		-c "Add :UIApplicationSceneManifest:UISceneConfigurations:UIWindowSceneSessionRoleApplication array" \
		-c "Add :UIApplicationSceneManifest:UISceneConfigurations:UIWindowSceneSessionRoleApplication:0 dict" \
		-c "Add :UIApplicationSceneManifest:UISceneConfigurations:UIWindowSceneSessionRoleApplication:0:UISceneConfigurationName string Default" \
		-c "Add :UIApplicationSceneManifest:UISceneConfigurations:UIWindowSceneSessionRoleApplication:0:UISceneDelegateClassName string PortSceneDelegate" \
		"$X/sts2/sts2-Info.plist"
	# Wi-Fi Aware: multiplayer between phones in the same room (src/ios/nearby_play.swift). A separate call: PlistBuddy
	# crashes on exit (after saving) when given all of these at once.
	/usr/libexec/PlistBuddy -c "Add :WiFiAwareServices dict" -c "Add :WiFiAwareServices:_sts2port._tcp dict" \
		-c "Add :WiFiAwareServices:_sts2port._tcp:Publishable dict" -c "Add :WiFiAwareServices:_sts2port._tcp:Subscribable dict" \
		"$X/sts2/sts2-Info.plist"
	/usr/libexec/PlistBuddy -c "Add :com.apple.developer.wifi-aware array" \
		-c "Add :com.apple.developer.wifi-aware:0 string Publish" -c "Add :com.apple.developer.wifi-aware:1 string Subscribe" \
		"$X/sts2/sts2.entitlements"
	# UIBackgroundModes audio: only used during multiplayer, to keep the game running in the background
	# (src/native/Port/PortKeepAlive.cs); otherwise the app is suspended as usual.
	# fmod-gdextension's iOS export plugin doesn't generate its plugin loader under Godot 4.5. Ours also swaps the
	# extension's racy async file callbacks for blocking reads from the pck (see the file).
	cat "$ROOT/src/ios/fmod_plugins_stub.cpp" >> "$X/sts2/dummy.cpp"
	# Lets the precompiled shaders below take effect (see the file). Uses the stub's pck reader, so it comes after.
	cat "$ROOT/src/ios/shader_cache_prep.cpp" >> "$X/sts2/dummy.cpp"
	# UIScene for Godot's window: required by the iOS 27 SDK, and what lets the game resize on an iPhone Duo.
	cat "$ROOT/src/ios/scene_delegate.cpp" >> "$X/sts2/dummy.cpp"
	mark_done export "$FP"
fi
FRAMEWORK="$X/sts2/dylibs/ExportRelease/sts2_aot.xcframework/ios-arm64/sts2.framework"
[[ -d "$FRAMEWORK" ]] || die "unexpected Godot export layout: $FRAMEWORK missing"

# ---------------------------------------------------------------------------------------------------- game code
# IL-patch the game's sts2.dll (Steam Cloud saves, direct-IP multiplayer, iOS fixes) and stock GodotSharp, then
# compile them with the port's code to one native iOS library (NativeAOT).
mkdir -p "$WORK/game-data"
rsync -a --delete --include='*.dll' --exclude='*' "$GAME_DATA/" "$WORK/game-data/"
# The macOS release bundles the .NET runtime alongside the game's assemblies.
# Use the SDK's reference assemblies instead of referencing runtime DLLs twice.
for ref in "$DOTNET_ROOT"/packs/Microsoft.NETCore.App.Ref/*/ref/net9.0/*.dll "$DOTNET_ROOT"/shared/Microsoft.NETCore.App/*/*.dll; do
	[[ -f "$ref" ]] && rm -f "$WORK/game-data/$(basename "$ref")"
done
rm -f "$WORK/game-data/System.Private.CoreLib.dll"
FP="$(fingerprint "$ROOT/src/patcher" "$ROOT/src/native" "$WORK/game-data" "$IOS_SDK" "$TOOLS_ID")"
if ! up_to_date native "$FP" || [[ ! -f "$WORK/native-out/sts2native.dylib" ]]; then
	step "Restoring stock GodotSharp $GODOT_VERSION"
	run restore dotnet restore "$WORK/proj/sts2.csproj"
	GODOTSHARP="$NUGET_PACKAGES/godotsharp/$GODOT_VERSION/lib/net8.0/GodotSharp.dll"
	[[ -f "$GODOTSHARP" ]] || die "GodotSharp $GODOT_VERSION not restored"
	step "Patching the game's code"
	rm -rf "$WORK/patcher" "$WORK/patched" && mkdir -p "$WORK/patched" && cp -R "$ROOT/src/patcher" "$WORK/patcher"
	(cd "$WORK/patcher" && run patch-godotsharp dotnet run -c Release -- "$GODOTSHARP" "$WORK/patched/GodotSharp.dll")
	if ! (cd "$WORK/patcher" && run patch-sts2 dotnet run -c Release --no-build -- "$WORK/game-data/sts2.dll" "$WORK/patched/sts2.dll"); then
		die "patching sts2.dll failed (game version $GAME_VERSION; tested with $TESTED_GAME_VERSION and $TESTED_BETA_VERSION)"
	fi
	step "Compiling the game for iOS (NativeAOT, takes a few minutes)"
	rm -rf "$WORK/native" "$WORK/native-out" && cp -R "$ROOT/src/native" "$WORK/native"
	(cd "$WORK/native" && run native-publish dotnet publish -c Release -o "$WORK/native-out" \
		-p:GameDataDir="$WORK/game-data" -p:PatchedDir="$WORK/patched" -p:IosSdkPath="$IOS_SDK" \
		-p:GameApi="$(cat "$WORK/patched/game-api.txt")")
	[[ -f "$WORK/native-out/sts2native.dylib" ]] || die "NativeAOT produced no library (see $(show "$LOGS/native-publish.log"))"
	mark_done native "$FP"
fi
cp "$WORK/native-out/sts2native.dylib" "$FRAMEWORK/sts2"
install_name_tool -id @rpath/sts2.framework/sts2 "$FRAMEWORK/sts2" 2>/dev/null

# ---------------------------------------------------------------------------------------------------- shaders
# Precompile the Metal shaders in a harvested shader cache (tools/bake_shaders.py) for the game data below, and
# list the recorded pipelines for the app's warm-up (src/ios/metal_pipelines.m).
BAKE="$WORK/shader-bake"; PIPES="$WORK/shader-pipelines"
if [[ -n "$SHADERS" ]]; then
	FP="$(fingerprint "$SHADERS" "$ROOT/tools/bake_shaders.py" "$IOS_SDK $(xcrun -sdk iphoneos metal --version 2>&1 | head -1)")"
	if ! up_to_date shaders "$FP" || [[ ! -d "$BAKE" ]]; then
		step "Precompiling shaders from $(show "$SHADERS")"
		xcrun -sdk iphoneos metal --version > /dev/null 2>&1 || die "Xcode's Metal compiler is missing: run
       xcodebuild -downloadComponent MetalToolchain (or drop --shaders / delete build/shader-cache)"
		run shader-bake python3 "$ROOT/tools/bake_shaders.py" --out "$BAKE" --objs "$WORK/shader-objs" --pipelines-out "$PIPES" "$SHADERS"
		grep -E "^(baked|warm-up list|no recorded)" "$LOGS/shader-bake.log" | sed 's/^/    /'
		mark_done shaders "$FP"
	fi
else
	rm -rf "$BAKE" "$PIPES" "$WORK/shaders.stamp"
fi

# ---------------------------------------------------------------------------------------------------- game data
# Add the port's scripts and settings (src/pck) to a copy of the game's pck, at the same res:// paths.
# The game's release_info.json (its version, which multiplayer joins compare) normally sits next to the
# executable; on iOS it's read from the pck instead (see src/patcher: ReleaseInfoManager).
# Script updates (src/pck/port/ota.gd, tools/ota.sh): the app trusts packs signed with src/ota/public.pem that were
# made for exactly this compiled code (OTA_COMPAT). built_at is when the scripts were added: older packs are ignored.
OTA_COMPAT="$(bash "$ROOT/tools/ota.sh" id)"
FP="$(fingerprint "$ROOT/src/pck" "$PCK_ID" "${INFO:-no-release-info}" "$ROOT/src/ota" "ota $OTA $OTA_URL $OTA_COMPAT" "$TOOLS_ID" \
	"$( [[ -d "$BAKE" ]] && fingerprint "$BAKE" || echo no-bake)" "$( [[ -d "$PIPES" ]] && fingerprint "$PIPES" || echo no-pipelines)")"
if ! up_to_date pck "$FP" || [[ ! -f "$WORK/sts2.pck" ]]; then
	step "Adding the port's files to the game data (about 2 GB)"
	PF=()
	while IFS= read -r f; do PF+=("--patch-file=$f=res://${f#$ROOT/src/pck/}"); done < <(find "$ROOT/src/pck" -type f ! -name '.DS_Store')
	[[ -n "$INFO" ]] && PF+=("--patch-file=$INFO=res://port/release_info.json")
	{
		echo "[ota]"
		echo "enabled=$([[ $OTA -eq 1 ]] && echo true || echo false)"
		echo "url=\"$OTA_URL\""
		echo "compat=\"$OTA_COMPAT\""
		echo "built_at=$(date -u +%s)"
	} > "$WORK/ota.cfg"
	PF+=("--patch-file=$WORK/ota.cfg=res://port/ota.cfg" "--patch-file=$ROOT/src/ota/public.pem=res://port/ota_public.pem")
	# Godot reads baked shaders from res://.godot/shader_cache (after its own cache in Documents).
	if [[ -d "$BAKE" ]]; then
		while IFS= read -r f; do PF+=("--patch-file=$f=res://.godot/shader_cache/${f#$BAKE/}"); done < <(find "$BAKE" -type f -name '*.cache')
	fi
	if [[ -d "$PIPES" ]]; then
		for f in "$PIPES"/*; do PF+=("--patch-file=$f=res://port/pipelines/$(basename "$f")"); done
	fi
	rm -f "$WORK/sts2.pck"
	run pck-patch "$GDRE" --headless --pck-patch="$PCK" --output="$WORK/sts2.pck" "${PF[@]}"
	[[ -f "$WORK/sts2.pck" ]] || die "pck patch produced no file (see $(show "$LOGS/pck-patch.log"))"
	mark_done pck "$FP"
fi
rm -f "$X/sts2.pck" && cp -c "$WORK/sts2.pck" "$X/sts2.pck" 2>/dev/null || cp "$WORK/sts2.pck" "$X/sts2.pck"

# ---------------------------------------------------------------------------------------------------- Metal hooks
# Records the pipelines the game creates, warms up the listed ones at launch, and times compiles
# (src/ios/metal_pipelines.m). Objective-C, so it's built here and linked in rather than appended to dummy.cpp.
# Named by content, so Xcode relinks when it changes.
metal_hooks() { # <sdk> <min-version flag> -> prints the object's path
	local o="$WORK/metal_pipelines-$1-$(fingerprint "$ROOT/src/ios/metal_pipelines.m" | cut -c1-12).o"
	if [[ ! -f "$o" ]]; then
		rm -f "$WORK"/metal_pipelines-"$1"-*.o
		run "metal-hooks-$1" xcrun -sdk "$1" clang -arch arm64 "$2" -fobjc-arc -O2 -c "$ROOT/src/ios/metal_pipelines.m" -o "$o"
	fi
	echo "$o"
}

# Multiplayer between phones in the same room over Wi-Fi Aware (src/ios/nearby_play.swift). Its API is Swift-only, so
# it's compiled here and linked in with the Swift libraries' search paths. Its two frameworks are weak-linked (and left
# out of the object's automatic links): on iOS before 26 the app starts without them and the feature stays off.
nearby_object() { # <sdk> <target> -> prints the object's path
	local o="$WORK/nearby_play-$1-$(fingerprint "$ROOT/src/ios/nearby_play.swift" | cut -c1-12).o"
	if [[ ! -f "$o" ]]; then
		rm -f "$WORK"/nearby_play-"$1"-*.o
		run "nearby-$1" xcrun -sdk "$1" swiftc -swift-version 5 -parse-as-library -target "$2" -O -module-name PortNearby \
			-Xfrontend -disable-autolink-framework -Xfrontend WiFiAware \
			-Xfrontend -disable-autolink-framework -Xfrontend DeviceDiscoveryUI \
			-c "$ROOT/src/ios/nearby_play.swift" -o "$o"
	fi
	echo "$o"
}
# Multiplayer from anywhere over Tailcat (src/ios/tailcat/tailcat_play.go). Go, built as a static library and
# force-loaded: nothing in the app refers to it, PortTailcat.cs looks its functions up at run time.
tailcat_library() { # <sdk> <clang target> -> prints the linker flag
	local a="$WORK/tailcat_play-$1-$(fingerprint "$ROOT/src/ios/tailcat" "$GO_VERSION" | cut -c1-12).a"
	if [[ ! -f "$a" ]]; then
		rm -f "$WORK"/tailcat_play-"$1"-*.a
		local go="$TOOLS/go/bin/go" tags
		export GOROOT="$TOOLS/go" GOPATH="$TOOLS/go-path" GOCACHE="$TOOLS/go-cache" GOTOOLCHAIN=local GOFLAGS=-mod=readonly
		cd "$ROOT/src/ios/tailcat"
		run tailcat-mod "$go" mod download github.com/tailscale/tailcat >&2
		tags="$(cat "$("$go" list -m -f '{{.Dir}}' github.com/tailscale/tailcat)/build-tags.txt")"
		CGO_ENABLED=1 GOOS=ios GOARCH=arm64 CC="$(xcrun -sdk "$1" -f clang) -isysroot $(xcrun -sdk "$1" --show-sdk-path) -target $2" \
			run "tailcat-$1" "$go" build -trimpath -buildvcs=false -tags "$tags" -ldflags='-s -w' -buildmode=c-archive -o "$a" . >&2
		rm -f "${a%.a}.h"
	fi
	echo "-Wl,-force_load,$a"
}
TAILCAT_LDFLAGS='-framework CoreFoundation -framework Security -lresolv'
NEARBY_LDFLAGS='-L$(SDKROOT)/usr/lib/swift -L$(TOOLCHAIN_DIR)/usr/lib/swift/$(PLATFORM_NAME) -weak_framework WiFiAware -weak_framework DeviceDiscoveryUI'

# ---------------------------------------------------------------------------------------------------- Simulator
# The same app for the iOS Simulator (Apple silicon). The engine, Spine and FMOD libraries and the NativeAOT game
# code exist only as arm64 device builds here; arm64 Simulators run that code natively, so a copy of the Xcode
# project gets them retagged as Simulator code (tools/arm64_to_sim.py, vtool), plus Metal stand-ins for the
# Simulator's GPU (src/ios/simulator_metal.m).
if [[ $SIM -eq 1 ]]; then
	step "Building the app for the iOS Simulator"
	SX="$WORK/sim-xcode"
	rm -rf "$SX" && cp -cR "$X" "$SX" 2>/dev/null || { rm -rf "$SX"; cp -R "$X" "$SX"; }
	to_sim() { # <device dylib> <output>; keeps its SDK version (the linker checks binaries built for newer SDKs harder)
		local sdk; sdk="$(xcrun vtool -show-build "$1" | awk '$1 == "sdk" { print $2; exit }')"
		xcrun vtool -set-build-version iossim 14.0 "${sdk:-17.0}" -replace -output "$2.tmp" "$1" \
			&& mv -f "$2.tmp" "$2" && codesign -f -s - "$2" 2>/dev/null
	}
	F="$SX/sts2/dylibs/ExportRelease/sts2_aot.xcframework/ios-arm64_x86_64-simulator/sts2.framework/sts2"
	[[ -f "$F" ]] || die "unexpected Godot export layout: $F missing"
	to_sim "$WORK/native-out/sts2native.dylib" "$F"
	install_name_tool -id @rpath/sts2.framework/sts2 "$F" 2>/dev/null && codesign -f -s - "$F" 2>/dev/null
	S="$SX/sts2/dylibs/addons/spine/ios/libspine_godot.ios.template_release.framework/libspine_godot.ios.template_release"
	to_sim "$S" "$S"
	XF="$SX/sts2/dylibs/addons/fmod/libs/ios/libGodotFmod.ios.template_release.xcframework"
	FW="libGodotFmod.ios.template_release.universal.framework"
	cp -R "$XF/ios-arm64" "$XF/ios-arm64-simulator"
	to_sim "$XF/ios-arm64/$FW/libGodotFmod.ios.template_release.universal" "$XF/ios-arm64-simulator/$FW/libGodotFmod.ios.template_release.universal"
	L=":AvailableLibraries:$(plutil -extract AvailableLibraries raw "$XF/Info.plist")"
	/usr/libexec/PlistBuddy -c "Add $L dict" -c "Add $L:BinaryPath string $FW" -c "Add $L:LibraryPath string $FW" \
		-c "Add $L:LibraryIdentifier string ios-arm64-simulator" -c "Add $L:SupportedArchitectures array" \
		-c "Add $L:SupportedArchitectures:0 string arm64" -c "Add $L:SupportedPlatform string ios" \
		-c "Add $L:SupportedPlatformVariant string simulator" "$XF/Info.plist"
	G="$SX/sts2.xcframework/ios-arm64_x86_64-simulator/libgodot.a" # Godot ships this one as x86_64 only
	rm -f "$G" && cp "$SX/sts2.xcframework/ios-arm64/libgodot.a" "$G"
	run sim-retag python3 "$ROOT/tools/arm64_to_sim.py" "$G"
	run sim-metal xcrun -sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=14.0 -fobjc-arc \
		-c "$ROOT/src/ios/simulator_metal.m" -o "$WORK/simulator_metal.o"
	HOOKS="$(metal_hooks iphonesimulator -mios-simulator-version-min=14.0) $(nearby_object iphonesimulator arm64-apple-ios17.0-simulator) $(tailcat_library iphonesimulator arm64-apple-ios17.0-simulator)"
	run xcodebuild-sim xcodebuild -project "$SX/sts2.xcodeproj" -scheme sts2 -configuration Release -sdk iphonesimulator \
		-destination "generic/platform=iOS Simulator" -derivedDataPath "$WORK/sim-derived" ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
		CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= \
		OTHER_LDFLAGS="-Wl,-U,_fmod_library_init $WORK/simulator_metal.o $HOOKS -framework Metal $NEARBY_LDFLAGS $TAILCAT_LDFLAGS" build
	APP="$WORK/sim-derived/Build/Products/Release-iphonesimulator/sts2.app"
	[[ -d "$APP" ]] || die "no Simulator app built (see $(show "$LOGS/xcodebuild-sim.log"))"
	C="$APP/.sts2.pck.clone"
	if cmp -s "$WORK/sts2.pck" "$APP/sts2.pck" && cp -c "$WORK/sts2.pck" "$C" 2>/dev/null; then
		touch -r "$APP/sts2.pck" "$C" && mv -f "$C" "$APP/sts2.pck"
	fi
	rm -f "$C" && rm -rf "$SX"
	echo
	echo "Done: $(show "$APP")"
	if [[ $INSTALL -eq 1 ]]; then
		SIMDEV="${DEVICE:-booted}"
		step "Installing on Simulator $SIMDEV"
		run sim-install xcrun simctl install "$SIMDEV" "$APP"
		echo "Installed. Start it from the Simulator's home screen, or: xcrun simctl launch $SIMDEV $BUNDLE_ID"
	fi
	exit 0
fi

# ---------------------------------------------------------------------------------------------------- app
step "Building the app with Xcode"
HOOKS="$(metal_hooks iphoneos -miphoneos-version-min=17.0) $(nearby_object iphoneos arm64-apple-ios17.0) $(tailcat_library iphoneos arm64-apple-ios17.0)"
XB=(xcodebuild -project "$X/sts2.xcodeproj" -scheme sts2 -configuration Release -destination generic/platform=iOS
	-derivedDataPath "$WORK/derived" OTHER_LDFLAGS="-Wl,-U,_fmod_library_init $HOOKS -framework Metal $NEARBY_LDFLAGS $TAILCAT_LDFLAGS")
if [[ $UNSIGNED -eq 1 ]]; then
	run xcodebuild "${XB[@]}" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
else
	XB+=(-allowProvisioningUpdates -allowProvisioningDeviceRegistration DEVELOPMENT_TEAM="$TEAM" build)
	if ! "${XB[@]}" > "$LOGS/xcodebuild.log" 2>&1; then
		if grep -qiE "personal development team|increased-memory-limit|Increased Memory Limit|wifi-aware|Wi-Fi Aware" "$LOGS/xcodebuild.log"; then
			# Free (personal) teams can't use the increased memory limit or Wi-Fi Aware entitlements.
			echo "    (your team can't use the increased memory limit or Wi-Fi Aware; building without them)"
			/usr/libexec/PlistBuddy -c "Delete :com.apple.developer.kernel.increased-memory-limit" "$X/sts2/sts2.entitlements" || true
			/usr/libexec/PlistBuddy -c "Delete :com.apple.developer.wifi-aware" "$X/sts2/sts2.entitlements" || true
			run xcodebuild "${XB[@]}"
		else
			echo "---- errors from $(show "$LOGS/xcodebuild.log") ----" >&2; grep -E "error:|BUILD FAILED" "$LOGS/xcodebuild.log" | tail -n 20 >&2
			die "Xcode build failed. If it's about provisioning: connect your iPhone/iPad by cable, unlock it, and
       make sure your Apple ID is in Xcode > Settings > Accounts"
		fi
	fi
fi
APP="$WORK/derived/Build/Products/Release-iphoneos/sts2.app"
[[ -d "$APP" ]] || die "no app built (see $(show "$LOGS/xcodebuild.log"))"
# Xcode makes a full 2 GB copy of the pck in the app. Swap in an APFS clone of the identical file to save that
# space (same bytes, so the app's signature still holds). Silently skipped on disks without clones.
C="$APP/.sts2.pck.clone"
if cmp -s "$WORK/sts2.pck" "$APP/sts2.pck" && cp -c "$WORK/sts2.pck" "$C" 2>/dev/null; then
	touch -r "$APP/sts2.pck" "$C" && mv -f "$C" "$APP/sts2.pck"
fi
rm -f "$C"

if [[ $UNSIGNED -eq 1 ]]; then
	step "Packaging the .ipa"
	rm -rf "$WORK/ipa" "$BUILD/SlayTheSpire2.ipa" && mkdir -p "$WORK/ipa/Payload"
	cp -c -R "$APP" "$WORK/ipa/Payload/" 2>/dev/null || cp -R "$APP" "$WORK/ipa/Payload/"
	(cd "$WORK/ipa" && run ipa zip -qr -1 "$BUILD/SlayTheSpire2.ipa" Payload)
	rm -rf "$WORK/ipa"
	echo
	echo "Done: $(show "$BUILD/SlayTheSpire2.ipa")"
	echo "Install it with Sideloadly or AltStore (see README). It's built from your copy of the game: keep it to yourself."
	exit 0
fi

echo
echo "Done: $(show "$APP")"
if [[ $INSTALL -eq 1 ]]; then
	# Prefer the default (newest) Xcode's devicectl: it supports the newest iOS versions.
	DC=(env -u DEVELOPER_DIR xcrun devicectl)
	"${DC[@]}" list devices >/dev/null 2>&1 || DC=(xcrun devicectl)
	if [[ -z "$DEVICE" ]]; then
		"${DC[@]}" list devices --json-output "$WORK/devices.json" >/dev/null 2>&1 || true
		DEVICE="$(python3 -c '
import json, sys
try: devices = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception: devices = []
for d in devices:
    hw, cp = d.get("hardwareProperties", {}), d.get("connectionProperties", {})
    if hw.get("reality") == "physical" and hw.get("platform") == "iOS" and cp.get("pairingState") == "paired" \
            and cp.get("tunnelState") != "unavailable":
        print(hw.get("udid") or d["identifier"]); break
' "$WORK/devices.json")"
		[[ -n "$DEVICE" ]] || die "no paired iPhone/iPad found: connect it by cable, unlock it and tap Trust"
	fi
	step "Installing on $DEVICE"
	# Wi-Fi connections to the device sometimes drop during the 2 GB copy; retry a couple of times.
	for attempt in 1 2 3; do
		if run_ok install "${DC[@]}" device install app --device "$DEVICE" "$APP"; then break; fi
		if [[ $attempt -eq 3 ]]; then
			tail -n 20 "$LOGS/install.log" >&2
			die "install failed: keep the device unlocked and nearby (a cable is most reliable), then run this again"
		fi
		echo "    (install interrupted; retrying)"; sleep 15
	done
	echo "Installed. First launch: if iOS says the developer isn't trusted, go to Settings > General >"
	echo "VPN & Device Management and trust your Apple ID."
fi
