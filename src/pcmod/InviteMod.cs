using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading.Tasks;
using Godot;
using HarmonyLib;
using MegaCrit.Sts2.Core.Entities.Multiplayer;
using MegaCrit.Sts2.Core.Helpers;
using MegaCrit.Sts2.Core.Multiplayer;
using MegaCrit.Sts2.Core.Multiplayer.Connection;
using MegaCrit.Sts2.Core.Nodes;
using MegaCrit.Sts2.Core.Nodes.Screens.MainMenu;

namespace TailcatInvites;

// Multiplayer by invite for the Steam version, compatible with the iOS port (github.com/FlyingViet/sts2-ios-launch).
// Turning on "Invite play" under Multiplayer makes the game act as if launched with --fastmp, which it already
// supports: hosting uses its direct (ENet, UDP 33771) host instead of a Steam lobby, and Join connects to 127.0.0.1.
// A helper (src/tailcat/cmd/sts2-tailcat) carries those ports through a Tailcat tunnel: when hosting it prints the
// invite to share; when joining it relays 127.0.0.1 to the invite on the clipboard. The game loads this assembly and
// applies the patches below (no ModInitializer, so it calls Harmony's PatchAll).
static class Invite
{
	public static bool On;
	public const ushort GamePort = 33771;
	const string ConfigPath = "user://tailcat_invites.cfg";

	static Helper? _host, _join;
	static string _invite = "";
	static long _copiedAt = long.MinValue / 2;

	public static void Log(string msg) => GD.Print("[TailcatInvites] " + msg);

	// Stable per-machine player id when joining: the game's default 1000 would collide when two PCs join one host,
	// and the iOS port's own ids are 1001 and up, picked at random the same way.
	static ulong ClientId()
	{
		var cfg = new ConfigFile();
		cfg.Load(ConfigPath);
		long id = cfg.GetValue("invite", "client_id", 0L).AsInt64();
		if (id <= 1000)
		{
			id = Random.Shared.Next(1001, 1_000_000);
			cfg.SetValue("invite", "client_id", id);
			cfg.Save(ConfigPath);
		}
		return (ulong)id;
	}

	static SignalAwaiter Wait(double seconds)
	{
		var tree = (SceneTree)Engine.GetMainLoop();
		return tree.ToSignal(tree.CreateTimer(seconds, true, false, true), SceneTreeTimer.SignalName.Timeout);
	}

	// ---- join ----

	public static async Task Join(NJoinFriendScreen screen)
	{
		StopJoin();
		string invite = DisplayServer.ClipboardGet().Trim();
		if (!invite.StartsWith("tc", StringComparison.Ordinal) || invite.Length < 20)
		{
			Overlay.Show("Copy the host's invite first, then choose Join again.", "", 6);
			Back(screen);
			return;
		}
		Overlay.Show("Connecting to the host…");
		var ready = new TaskCompletionSource<string?>(TaskCreationOptions.RunContinuationsAsynchronously);
		_join = Helper.Start(new[] { "join", invite }, (kind, e) =>
		{
			if (kind == "ready") ready.TrySetResult(null);
			else ready.TrySetResult(e.TryGetProperty("message", out var m) ? m.GetString() : "the helper stopped");
		});
		if (_join == null)
		{
			Overlay.Show("Invite play isn't available: its helper is missing from the mod's folder.", "", 8);
			Back(screen);
			return;
		}
		var done = await Task.WhenAny(ready.Task, Task.Delay(25_000));
		string? error = done == ready.Task ? ready.Task.Result : "timed out";
		if (error != null)
		{
			Log("couldn't connect: " + error);
			StopJoin();
			Overlay.Show("Couldn't connect with that invite. Check the host is still hosting, or ask for a new invite.", "", 8);
			Back(screen);
			return;
		}
		Overlay.Hide();
		ulong id = ClientId();
		Log($"joining by invite as player {id}");
		await screen.JoinGameAsync(new ENetClientConnectionInitializer(id, "127.0.0.1", GamePort));
	}

	static void StopJoin()
	{
		_join?.Stop();
		_join = null;
	}

	// Leaves the join screen as if its back button was pressed.
	static void Back(NJoinFriendScreen screen)
	{
		var back = screen.GetNodeOrNull<Control>("BackButton");
		back?.EmitSignal("Released", back);
	}

	// ---- host ----

	public static void BeforeHost() => StopJoin(); // its listener would hold the game's port

	public static void OnHost(NetHostGameService service)
	{
		_host?.Stop();
		_invite = "";
		var host = _host = Helper.Start(new[] { "host" }, (kind, e) =>
		{
			if (kind == "ready") _invite = e.GetProperty("invite").GetString() ?? "";
			else Log("hosting by invite stopped: " + (e.TryGetProperty("message", out var m) ? m.GetString() : "the helper exited"));
		});
		if (host == null)
		{
			Overlay.Show("Invite play isn't available: its helper is missing from the mod's folder.", "", 8);
			return;
		}
		_ = HostLoop(service, host);
	}

	static async Task HostLoop(NetHostGameService service, Helper host)
	{
		while (host == _host && service.IsConnected)
		{
			if (NGame.Instance?.MainMenu != null) // the lobby; hide once the run starts
			{
				int players = service.ConnectedPeers.Count + 1;
				if (_invite == "") Overlay.Show($"Hosting by invite · getting an invite… · {players} player{(players == 1 ? "" : "s")} here");
				else Overlay.Show($"Hosting by invite · {players} player{(players == 1 ? "" : "s")} here",
					System.Environment.TickCount64 - _copiedAt < 3000 ? "Copied" : "Copy invite");
			}
			else Overlay.Hide();
			await Wait(1);
		}
		if (host == _host)
		{
			host.Stop();
			_host = null;
			_invite = "";
			Overlay.Hide();
		}
	}

	public static void CopyInvite()
	{
		if (_invite == "") return;
		DisplayServer.ClipboardSet(_invite);
		_copiedAt = System.Environment.TickCount64;
	}

	// ---- the toggle under Multiplayer ----

	public static void AddToggle(NMultiplayerSubmenu menu)
	{
		if (menu.HasNode("TailcatInvitesToggle")) return;
		var toggle = new CheckButton
		{
			Name = "TailcatInvitesToggle",
			Text = "Invite play (with iPhone/iPad and other invite players)",
			ButtonPressed = On,
			FocusMode = Control.FocusModeEnum.None,
		};
		toggle.AddThemeFontSizeOverride("font_size", 26);
		if (ResourceLoader.Exists(Overlay.FontPath)) toggle.AddThemeFontOverride("font", GD.Load<Font>(Overlay.FontPath));
		toggle.SetAnchorsPreset(Control.LayoutPreset.CenterBottom);
		toggle.GrowHorizontal = Control.GrowDirection.Both;
		toggle.GrowVertical = Control.GrowDirection.Begin;
		toggle.OffsetBottom = -40;
		toggle.Toggled += on =>
		{
			On = on;
			SetFastMp(on);
			Log(on ? "invite play on" : "invite play off");
		};
		menu.AddChild(toggle);
		Log("added the Invite play toggle");
	}

	// The game's own command line arguments, where it looks for --fastmp. Set there rather than by patching
	// CommandLineHelper.HasArg: that's small enough for the JIT to inline into its callers, past any patch.
	static readonly Godot.Collections.Dictionary<string, string>? Args =
		AccessTools.Field(typeof(CommandLineHelper), "_args")?.GetValue(null) as Godot.Collections.Dictionary<string, string>;
	static bool _addedFastMp;

	static void SetFastMp(bool on)
	{
		if (Args == null)
		{
			Log("can't find the game's command line arguments; invite play won't work in this game version");
			return;
		}
		if (on && !Args.ContainsKey("fastmp"))
		{
			Args["fastmp"] = "";
			_addedFastMp = true;
		}
		else if (!on && _addedFastMp)
		{
			Args.Remove("fastmp");
			_addedFastMp = false;
		}
	}
}

// The helper process for this platform, from the mod's helper folder. Reports its events on the main thread.
sealed class Helper
{
	readonly Process _process;
	bool _stopped;

	Helper(Process process) => _process = process;

	static string? PathForThisMachine()
	{
		string os = OperatingSystem.IsWindows() ? "windows" : OperatingSystem.IsMacOS() ? "darwin" : "linux";
		string arch = RuntimeInformation.OSArchitecture == Architecture.Arm64 ? "arm64" : "amd64";
		string dir = Path.GetDirectoryName(typeof(Helper).Assembly.Location) ?? "";
		string path = Path.Combine(dir, "helper", $"sts2-tailcat-{os}-{arch}{(OperatingSystem.IsWindows() ? ".exe" : "")}");
		return File.Exists(path) ? path : null;
	}

	public static Helper? Start(string[] args, Action<string, JsonElement> onEvent)
	{
		string? path = PathForThisMachine();
		if (path == null) return null;
		if (!OperatingSystem.IsWindows())
		{
			File.SetUnixFileMode(path, File.GetUnixFileMode(path) | UnixFileMode.UserExecute);
			// A zip downloaded in a browser marks its files as quarantined, and macOS won't run them.
			if (OperatingSystem.IsMacOS())
				try { Process.Start("/usr/bin/xattr", new[] { "-d", "com.apple.quarantine", path })?.WaitForExit(2000); } catch { }
		}
		var info = new ProcessStartInfo(path)
		{
			UseShellExecute = false, CreateNoWindow = true,
			RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
		};
		foreach (var a in args) info.ArgumentList.Add(a);
		var process = new Process { StartInfo = info, EnableRaisingEvents = true };
		var helper = new Helper(process);
		bool reported = false;
		void Report(string kind, JsonElement e) => Callable.From(() =>
		{
			if (helper._stopped || (reported && kind != "ready")) return;
			if (kind != "ready") reported = true;
			onEvent(kind, e);
		}).CallDeferred();
		process.OutputDataReceived += (_, line) =>
		{
			if (string.IsNullOrWhiteSpace(line.Data)) return;
			try
			{
				var e = JsonDocument.Parse(line.Data).RootElement.Clone();
				Report(e.GetProperty("event").GetString() ?? "", e);
			}
			catch (Exception ex) { Invite.Log("helper: " + ex.Message); }
		};
		process.ErrorDataReceived += (_, line) => { if (!string.IsNullOrWhiteSpace(line.Data)) Invite.Log("helper: " + line.Data); };
		process.Exited += (_, _) => Report("exited", JsonDocument.Parse("{}").RootElement.Clone());
		try
		{
			process.Start();
			process.BeginOutputReadLine();
			process.BeginErrorReadLine();
		}
		catch (Exception ex)
		{
			Invite.Log("couldn't start the helper: " + ex.Message);
			return null;
		}
		return helper;
	}

	// Closing its input stops it; it also stops by itself if the game exits.
	public void Stop()
	{
		if (_stopped) return;
		_stopped = true;
		try
		{
			_process.StandardInput.Close();
			if (!_process.WaitForExit(1000)) _process.Kill();
		}
		catch { }
	}
}

// A banner at the top of the screen with an optional button.
static class Overlay
{
	public const string FontPath = "res://themes/kreon_bold_shared.tres";
	static CanvasLayer? _layer;
	static Label? _label;
	static Button? _button;
	static int _generation;

	static void Ensure()
	{
		if (_layer != null && GodotObject.IsInstanceValid(_layer)) return;
		_layer = new CanvasLayer { Layer = 115, ProcessMode = Node.ProcessModeEnum.Always };
		var row = new CenterContainer { MouseFilter = Control.MouseFilterEnum.Ignore };
		row.SetAnchorsPreset(Control.LayoutPreset.TopWide);
		row.Position = new Vector2(0, 14);
		var panel = new PanelContainer { MouseFilter = Control.MouseFilterEnum.Ignore };
		var box = new StyleBoxFlat
		{
			BgColor = new Color(0.05f, 0.06f, 0.08f, 0.9f), BorderColor = new Color(0.95f, 0.82f, 0.45f, 0.6f),
			ContentMarginLeft = 20, ContentMarginRight = 20, ContentMarginTop = 12, ContentMarginBottom = 12,
		};
		box.SetBorderWidthAll(2);
		box.SetCornerRadiusAll(14);
		panel.AddThemeStyleboxOverride("panel", box);
		var content = new HBoxContainer { MouseFilter = Control.MouseFilterEnum.Ignore };
		content.AddThemeConstantOverride("separation", 18);
		_label = new Label { SizeFlagsVertical = Control.SizeFlags.ShrinkCenter };
		_label.AddThemeFontSizeOverride("font_size", 24);
		_button = new Button { FocusMode = Control.FocusModeEnum.None, CustomMinimumSize = new Vector2(150, 50) };
		_button.AddThemeFontSizeOverride("font_size", 24);
		if (ResourceLoader.Exists(FontPath))
		{
			var font = GD.Load<Font>(FontPath);
			_label.AddThemeFontOverride("font", font);
			_button.AddThemeFontOverride("font", font);
		}
		_button.Pressed += Invite.CopyInvite;
		content.AddChild(_label);
		content.AddChild(_button);
		panel.AddChild(content);
		row.AddChild(panel);
		_layer.AddChild(row);
		((SceneTree)Engine.GetMainLoop()).Root.AddChild(_layer);
	}

	/// action: button text (the only button copies the invite). seconds: hide after that long (0: stay).
	public static void Show(string text, string action = "", double seconds = 0)
	{
		Ensure();
		_label!.Text = text;
		_button!.Text = action;
		_button.Visible = action != "";
		_layer!.Visible = true;
		int generation = ++_generation;
		if (seconds > 0)
		{
			var tree = (SceneTree)Engine.GetMainLoop();
			tree.CreateTimer(seconds, true, false, true).Timeout += () => { if (generation == _generation) Hide(); };
		}
	}

	public static void Hide()
	{
		if (_layer != null && GodotObject.IsInstanceValid(_layer)) _layer.Visible = false;
	}
}

// ---- patches ----

[HarmonyPatch(typeof(NMultiplayerSubmenu), nameof(NMultiplayerSubmenu._Ready))]
static class AddToggle
{
	static void Postfix(NMultiplayerSubmenu __instance) => Invite.AddToggle(__instance);
}

[HarmonyPatch(typeof(NJoinFriendScreen), "FastMpJoin")]
static class JoinByInvite
{
	static bool Prefix(NJoinFriendScreen __instance, ref Task __result)
	{
		if (!Invite.On) return true; // a real --fastmp launch
		__result = Invite.Join(__instance);
		return false;
	}
}

[HarmonyPatch(typeof(NetHostGameService), nameof(NetHostGameService.StartENetHost))]
static class HostByInvite
{
	static void Prefix()
	{
		if (Invite.On) Invite.BeforeHost();
	}

	static void Postfix(NetHostGameService __instance, NetErrorInfo? __result)
	{
		if (Invite.On && __result == null) Invite.OnHost(__instance);
	}
}
