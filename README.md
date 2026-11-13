# Slay the Spire 2 for iPhone and iPad (unofficial)

Turn **your own copy** of Slay the Spire 2 from Steam into a native iPhone or iPad app. One command on a Mac
patches your game files and installs the app on your phone.

This repository contains **no game files**, so you need to own Slay the Spire 2 on Steam. This is a fan
project, not affiliated with or endorsed by Mega Crit.

> **Don't share the app or `.ipa` you build.** It contains the game, so it's yours alone. Friends should build
> their own from this repository.

## Install

You need:

- **A Mac** (Apple silicon recommended) with about 15 GB free.
- **Slay the Spire 2 on Steam**, on the public branch: tested with **v0.107.1**. The beta branch's **v0.113.0** works
  too (see [Playing the beta](#playing-the-beta)).
- **An iPhone or iPad** on iOS 17 or later, and a cable to connect it to the Mac.
- **An Apple ID.** A free one works (see [Keeping it working](#keeping-it-working)).

### 1. Get your game files onto the Mac

On a Windows PC with the game installed, open Steam, right-click **Slay the Spire 2** → **Manage** →
**Browse local files**. Copy that whole folder to your Mac (a USB drive or a shared network folder works). It contains
`SlayTheSpire2.pck` and a `data_sts2_windows_x86_64` folder.

<details>
<summary>No PC, or the game is installed with Steam for Mac</summary>

- **Steam for Mac:** if the game is installed there, skip this step and leave out `--game` in step 4.
- **No PC (not yet tested):** download the Windows version with Valve's
  [SteamCMD](https://developer.valvesoftware.com/wiki/SteamCMD) and your Steam login, then use `~/sts2-game`
  as your game folder:

  ```sh
  steamcmd +@sSteamCmdForcePlatformType windows +force_install_dir ~/sts2-game \
    +login <your Steam username> +app_update 2868840 validate +quit
  ```

</details>

### 2. Set up Xcode

1. Install **Xcode 26 or newer** from the Mac App Store. For the **iPhone Duo**, use Xcode 27.1 or newer
   (see [iPhone Duo](#iphone-duo)).
2. Open Xcode once and let it finish installing its components.
3. In Xcode, go to **Settings** → **Accounts**, click **+**, and sign in with your Apple ID.

### 3. Connect your iPhone or iPad

1. Connect it to the Mac with a cable and unlock it.
2. Tap **Trust** if it asks whether to trust this computer.
3. Turn on **Developer Mode**: Settings → Privacy & Security → Developer Mode, then let it restart. If you
   don't see Developer Mode yet, it appears after step 4 first tries to install. Turn it on then, and run
   step 4 again.

### 4. Build and install

Open **Terminal** and run:

```sh
git clone https://github.com/FlyingViet/sts2-ios-launch.git
cd sts2-ios-launch
./build.sh --install --game "/path/to/Slay the Spire 2"
```

Replace `/path/to/Slay the Spire 2` with the folder from step 1. The easiest way to get it right is to type
`./build.sh --install --game ` (with a space at the end), drag the game folder from Finder into the Terminal
window, and press Return.

This one command does everything: it downloads the build tools, patches your copy of the game for iOS,
compiles it, and installs the app on your phone. The first run downloads about 2 GB and takes roughly 5–15
minutes. If something is wrong (no Apple ID in Xcode, wrong folder, phone not connected), it stops and tells you
what to fix.

No Git? Click **Code** → **Download ZIP** on this page, unzip it, and `cd` into that folder instead of running
`git clone`.

### 5. Open the app

The first time, iOS may say the developer isn't trusted. Go to Settings → General → **VPN & Device
Management**, tap your Apple ID, and tap **Trust**. Then open **Slay the Spire 2** and sign in to Steam to sync
your saves (or skip that).

### Keeping it working

- **Free Apple ID:** the app stops opening after 7 days. Connect your phone and run the same `./build.sh`
  command again. It takes about a minute, and your saves are kept (they're also in Steam Cloud). A paid
  Apple Developer account lasts a year.
- **Updating to a newer version of this port:** run `git pull` (or download the ZIP again), then the same
  `./build.sh` command.
- **Small fixes arrive on their own:** see [Script updates](#script-updates).
- **Game updated on Steam?** Copy the new game files over and rebuild. If the patch step fails, this port
  hasn't caught up with that game version yet.

### Other ways to install

- **Sideloadly or AltStore instead of Xcode signing:** `./build.sh --unsigned --game "/path/to/Slay the Spire 2"`
  makes `build/SlayTheSpire2.ipa`. Install that with [Sideloadly](https://sideloadly.io) or
  [AltStore](https://altstore.io), which sign it with your Apple ID.
- **iOS Simulator:** see `--simulator` in [Options](#options).

## What you get

- **The full game**, running natively with Metal (it's not an emulator or streaming).
- **Touch controls.** Tap to click, drag cards to play them, and touch and hold anything to see its tooltip.
- **Full-screen layout** that keeps the UI clear of the notch, the Dynamic Island and the rounded corners.
  Plays in either landscape direction.
- **Steam Cloud saves.** Sign in with Steam on first launch (Steam Guard supported) and your progress syncs
  with your PC. Sync happens at startup and in the background while you play. A **Steam Cloud** button on the
  main menu lets you check sync status and pull or push saves by hand.
  - **Offline play:** without a connection the game starts normally and saves on the device. Once Steam is
    reachable again, your progress uploads automatically. If another device saved something newer in the
    meantime, it loads the next time you're on the main menu. When both changed, the newer save wins and the
    other copy is kept as a backup on the device.
- **Multiplayer over direct IP**, on your home Wi-Fi or over [Tailscale](https://tailscale.com):
  - **Hosting:** Multiplayer → Host. A banner shows the address for others to join.
  - **Up to 6 players** when an iPhone or iPad hosts (the game's own limit is 4). Everyone needs this app;
    a PC can't join an iOS host. Players 5 and 6 sit beside the logs at rest sites and get their own relic
    in treasure rooms.
  - **Joining:** Multiplayer → Join. Games hosted by iPhones and iPads on the same Wi-Fi are listed (with the
    host's name and player count): tap one to join. Otherwise enter the host's IP; recent addresses, including
    Tailscale ones, are checked and listed too.
  - **Nearby, without Wi-Fi** (iOS 26, iPhone 12 or later): phones in the same room play over Wi-Fi Aware, with no
    router, shared network or IP address. Pair each pair of phones once (**Pair a phone** under Join, or on the
    host's banner), then the host's game shows up under Join as "*phone*, nearby". Builds signed with a free Apple ID
    leave this out (Apple doesn't offer Wi-Fi Aware to them). Not yet tested between two phones.
  - **By invite, from anywhere:** the host taps **Copy invite** on its banner and sends it (Messages, etc.); the
    other player copies it and taps **Paste invite** under Join. The game travels through an encrypted
    [Tailcat](https://github.com/tailscale/tailcat) tunnel (WireGuard, set up through Tailscale's public relays, phone to
    phone when the networks allow it): no Tailscale account, app or VPN, and it works with a free Apple ID.
    Steam players join in with the [Tailcat Invites mod](#playing-with-the-steam-version).
  - **Names:** players see each other's Steam names. Names come from the iOS host, so with a PC host
    they show as "Host" / "Player 123456".
  - **Keeps running when you leave the app:** during a multiplayer game, pulling down Notification Center or
    switching apps doesn't pause the game for everyone else. The app uses iOS background audio (silent, and it
    mixes with your music) only while a multiplayer game is connected.
  - **With a PC:** the PC must host, and PC-hosted games stay at 4 players. Add `--fastmp` to the game's
    Steam launch options, then use Multiplayer → Host on the PC.
  - **Versions:** everyone needs the same game version.
  - **Steam:** friends lists, invites and Steam lobbies aren't available, because Steam doesn't exist on iOS.
- **120 FPS by default** on ProMotion iPhones (the game's default is 60); change it in Settings → FPS. To save
  battery and heat, the screen drops to 60 Hz after 2 seconds without touches or animations, and returns to 120 the
  moment you touch it or something moves.
- Sound and music through FMOD (they follow the silent switch).
- **Extra custom-run modifiers** (singleplayer only), at the bottom of Singleplayer → Custom → modifiers:
  - **Supercharged:** 20 extra Energy every turn.
  - **Perfected Deck:** after every other modifier, your whole deck turns into Perfected Strike+.

Tested on an iPhone 16 Pro Max running iOS 27.

## Playing with the Steam version

The **Tailcat Invites** mod ([`src/pcmod`](src/pcmod)) lets Windows, Mac and Linux players host and join invite games
with iPhones and iPads (and with each other), next to the usual Steam multiplayer:

1. Build it with `tools/build_pcmod.sh` (on a Mac with the game installed through Steam; `--install` also puts it in
   that install's mods folder), then give players `build/pcmod/TailcatInvites.zip`.
2. Players unzip it into the game's `mods` folder, next to the game's executable (on Windows,
   `…\steamapps\common\Slay the Spire 2\mods`; on a Mac, right-click the game in Finder, Show Package Contents, then
   `Contents/MacOS/mods`), start the game and accept its mods warning.
3. Under **Multiplayer**, **Host** (and **Load**) asks whether to host via Steam or with an invite code; with a code,
   **Copy invite code** appears at the top of the screen. **Join** asks whether to join a Steam friend or enter an
   invite code.

Don't add `--fastmp` to the launch options: the mod switches it on for invite games only. Games with a Steam
player stay at 4 players. The mod doesn't affect gameplay, so it doesn't stop
anyone joining. Everyone still needs the same game version. Not yet tested in a real game.

## Playing the beta

To play the beta (v0.113.0: the Fool, Blitz and Dread), switch Slay the Spire 2 to `public-beta` in Steam
(Properties → Game Versions & Betas), let it update, copy the game files again and rebuild. The beta's new lobbies
(Blitz and Dread) get the same 6-player hosting as standard and custom runs.

Your saves follow you: Steam Cloud saves are shared by both branches, and the beta upgrades them to newer save
formats. The main branch, and builds of this port made from it, then drop what they don't know (beta-only progress
such as the Fool's unlocks). Play the beta on all your devices at once, or not at all.

## Script updates

Fixes to the port's scripts (touch input, layout, menus, the multiplayer and Steam Cloud screens) arrive as small
signed downloads, without rebuilding. The app checks once per launch on the main menu, downloads a newer one in the
background, and uses it from the next launch. Compiled code (the game patches, Steam
Cloud, multiplayer, frame pacing) can't change this way, because iOS only runs code that was signed at install; when
an update needs that, the app tells you to rebuild instead. Details:

- Updates are signed with the repository owner's key, and the app only accepts updates made for exactly the code it
  was built from, and newer than your build.
- If an update ever stops the game from reaching the main menu, the next launch goes back to the built-in scripts.
- To turn it off, build with `--no-ota`. A fork can point at its own release with `--ota-url` (and its own key, see
  [`tools/ota.sh`](tools/ota.sh)).

## Smoother first launches

The first time each effect appears after installing (or after an iOS update), Godot 4.5 compiles its Metal shader
and pipeline while the game waits: about 0.3 s per new effect on an iPhone 16 Pro Max, and up to a second for new
particle effects. Builds can skip most of that with shaders harvested from a device you've played on:

1. Build and install as usual, then play for a while (a few fights, a shop, an event). The app keeps the shaders it
   compiled and records each Metal pipeline it creates.
2. With the device connected, run `tools/harvest_shaders.sh --bundle-id <the bundle ID the build printed>`. It
   copies them into `build/shader-cache`. Run it again after more play to add to it.
3. Build again. Every later build includes them:
   - **Precompiled shaders** ([`tools/bake_shaders.py`](tools/bake_shaders.py)): the harvested shaders compiled
     with Xcode's Metal compiler, so the game loads them instead of compiling them.
   - **Pipeline warm-up** ([`src/ios/metal_pipelines.m`](src/ios/metal_pipelines.m)): right after launch, two
     background threads build the recorded pipelines in the order the game first needed them, so they're ready
     before the game asks. Once that's done for a build and iOS version, later launches skip it.

These need Python 3.14 or newer and Xcode's Metal toolchain (`xcodebuild -downloadComponent MetalToolchain`).
The precompiled shaders and the warm-up work on every iPhone and iPad with an A13 or M1 chip or newer, whichever of
them you harvested from, as long as it runs the same or a newer major iOS version than the harvesting device (Godot
generates the same shaders for all of them). Older devices compile their own shaders as before. The
harvest holds compiled copies of the game's shaders, so keep it out of anything you share. `godot.log` reports the
time the game waited for compiles (`[PERF] metal`).

## Options

| Option | What it does |
| --- | --- |
| `--game <folder>` | Your Slay the Spire 2 folder. Default: the Steam for Mac install. |
| `--install` | Install on the connected device after building. |
| `--device <udid>` | Device to install on, if more than one is connected. |
| `--team <id>` | Apple team to sign with, if your Xcode has more than one. |
| `--bundle-id <id>` | App ID. Default: `com.sts2ios.<team id>`. |
| `--unsigned` | Make an unsigned `.ipa` instead (see above). |
| `--xcode <path>` | Which Xcode (26 or newer) to use, instead of the newest one found. |
| `--simulator` | Build for the iOS Simulator instead (Apple silicon Macs); with `--install`, installs on the booted Simulator or `--device <udid>`. For checking layouts, e.g. on the iPhone Duo Simulator; rendering there is approximate. |
| `--icon game` | Use the game's own pixel-art icon instead of the Ironclad close-up. |
| `--clean` | Rebuild everything (downloaded tools are kept). |
| `--no-ota` | Don't download script updates in the app. |
| `--ota-url <url>` | Where the app looks for script updates. |
| `--shaders <folder>` | Shaders and pipelines harvested from a device, to precompile and warm up (see [Smoother first launches](#smoother-first-launches)). Default: `build/shader-cache` if it exists. |

## iPhone Duo

Built with Xcode 27.1 or newer (the iOS 27.1 SDK), the game fills the iPhone Duo's outer screen when it's closed
and its inner screen when it's open, and follows the phone as it opens, closes, folds or turns over, even mid-fight.
The port keeps the game's buttons clear of the camera and status column on the outer screen, and keeps the hand of
cards between the energy orb and End Turn on the squarer screens. Built with Xcode 26, iOS shows the game in a
fixed iPhone-sized window on the Duo instead.

Godot 4.5's iOS runtime doesn't use the UIScene app lifecycle, which apps built with the iOS 27 SDK must adopt
(they're stopped at launch otherwise) and which the Duo needs to resize apps. The build adds it
([`src/ios/scene_delegate.cpp`](src/ios/scene_delegate.cpp)).

The game stays landscape in every pose. A real iPhone Duo can still resize it to the upright outer screen while
it's in the background (folded and held upright in another app); the game then asks iOS to turn it back to landscape
([`src/ios/scene_delegate.cpp`](src/ios/scene_delegate.cpp)).

Tested in the iPhone Duo Simulator (`--simulator`) closed, half open and open, both ways round, and played on a real
iPhone Duo (iOS 27.2).

## Troubleshooting

- **Build logs** are in `build/logs/`. The script prints the end of the log for whichever step failed.
- **"Permission denied" running `./build.sh`:** run `bash build.sh …` instead.
- **Folder path with a space in it:** the build goes to `~/Library/Caches/sts2-ios-launch` instead of
  `build/`, because .NET's iOS linker can't handle spaces in paths. The script prints where the result is.
- **"patching sts2.dll failed":** your game version differs from the ones this was made for (v0.107.1 on the
  public branch, v0.113.0 on the beta). Switch Slay the Spire 2 to one of them (Properties → Game Versions &
  Betas), let it update, and copy the files again.
- **Signing or provisioning errors:** check your Apple ID is in Xcode → Settings → Accounts, and that your
  device is connected, unlocked and trusted. With a free Apple ID, Apple allows 3 sideloaded apps at a time
  and 10 new app IDs a week.
- **No sound:** check the silent switch.
- **A game isn't listed in Join:** both devices must be on the same Wi-Fi (guest networks often block devices from
  seeing each other), the host must be on the Multiplayer → Host screen, and Local Network access must be on
  (Settings → Privacy & Security → Local Network). PC hosts are never listed: type their IP.
- **"Version mismatch" when joining:** everyone needs the same game version (all on the public branch or all on
  the beta), and
  iOS devices need a build of this repository from after the fix for this (October 8, 2026).
- **The app's own log:** Files app → On My iPhone → Slay the Spire 2 → `godot.log`.

## Known limits

- **Rejoining a run in progress isn't supported** (the game itself only rejoins lobbies). If someone drops
  mid-run, the host can use Pause → Save & Quit, then Continue, and everyone joins the saved run again; the
  current room restarts.
- **Multiplayer combat runs slower than singleplayer** on the host (around 40 fps measured on an iPhone 16 Pro
  Max). Not yet investigated.
- **Not yet tested with real players:** a full 5–6 player run, and an iPhone joining a PC host.
- **A PC can't join a game hosted on iOS** (the PC game's Join only connects to itself), so PC players must host.

## How it works

The game is made with Godot (Mega Crit's fork of Godot 4.5) and C#. Its data (`SlayTheSpire2.pck`) and code
(`sts2.dll`) don't depend on the platform, so the build assembles them into an iOS app:

1. **Engine:** exports an empty Godot 4.5.1 C# project ([`src/godot`](src/godot)) for iOS. That produces an
   Xcode project with the stock iOS engine and the FMOD and Spine extensions the game uses. Spine's iOS library
   is rebuilt from its 4.2 source with [`src/spine/no-gpu-readback.patch`](src/spine/no-gpu-readback.patch):
   the prebuilt one reads each changed character mesh back from the GPU, which froze the game for 30–40 ms on
   attacks and hits.
2. **Patching:** patches the game's `sts2.dll` with Mono.Cecil ([`src/patcher`](src/patcher)) to add hooks for
   Steam Cloud saves and direct-IP multiplayer (including the 6-player limit), to read the game's version from
   the app, to default to 120 FPS, and to make a few fixes for iOS.
3. **Compiling:** compiles the game's code and the port's code ([`src/native`](src/native)) into a native iOS
   library with .NET NativeAOT, since iOS can't run .NET code just in time. The port's code includes:
   - a small Steam client used only for Cloud saves. Your Steam password isn't stored, only a sign-in token in
     the iOS Keychain.
   - a side channel for multiplayer on UDP port 33772, next to the game's own 33771. It carries player names,
     Wi-Fi game discovery, and a light heartbeat that keeps the iPhone's Wi-Fi from dozing between moves.
   - frame pacing, garbage collection moved to calm moments (no finger down, nothing animating) so it doesn't
     interrupt animations, and the background keep-alive used during multiplayer.
4. **Data:** adds the port's settings and scripts ([`src/pck`](src/pck)) to a copy of the game's `.pck`:
   - touch input
   - display and safe-area layout
   - the Steam Cloud screens
   - the multiplayer join and host screens
   - your copy's `release_info.json` (the game version that multiplayer compares)
   - the script updater's settings and public key
   - precompiled shaders and the pipeline warm-up list, if you've harvested them
     ([Smoother first launches](#smoother-first-launches))
5. **App build:** builds and signs the app with Xcode, adding UIScene support to Godot's iOS app
   ([`src/ios/scene_delegate.cpp`](src/ios/scene_delegate.cpp)) and the Metal hooks that record, time and warm up
   pipelines ([`src/ios/metal_pipelines.m`](src/ios/metal_pipelines.m)).

These tools are downloaded from their official sources during the build. None of them are included here:

- [.NET SDK](https://dotnet.microsoft.com)
- [Godot](https://godotengine.org)
- [GDRE Tools](https://github.com/GDRETools/gdsdecomp)
- [fmod-gdextension](https://github.com/utopia-rise/fmod-gdextension), which includes FMOD, under
  [FMOD's license](https://www.fmod.com/licensing)
- [spine-godot](https://esotericsoftware.com/spine-godot) (prebuilt, and its source for the iOS library), under the
  [Spine Runtimes license](https://esotericsoftware.com/spine-runtimes-license), built with
  [godot-cpp](https://github.com/godotengine/godot-cpp) and [SCons](https://scons.org)

## Credits

- [Ekyso/StS2-Launcher](https://github.com/Ekyso/StS2-Launcher), the Android port, was the reference for the
  Steam Cloud sync.
- Slay the Spire 2 is by [Mega Crit](https://www.megacrit.com). Buy it on
  [Steam](https://store.steampowered.com/app/2868840/).

The code in this repository is MIT-licensed (see [LICENSE](LICENSE)). The game and its files are not covered by
that license.
