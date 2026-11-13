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
// Multiplayer's Host, Load and Join ask whether to go through Steam or an invite code. With a code, the game acts as
// if launched with --fastmp, which it already supports: hosting uses its direct (ENet, UDP 33771) host instead of a
// Steam lobby, and Join connects to 127.0.0.1. A helper (src/tailcat/cmd/sts2-tailcat) carries those ports through a
// Tailcat tunnel: when hosting it prints the code to share; when joining it relays 127.0.0.1 to the code entered.
// The game loads this assembly and applies the patches below (no ModInitializer, so it calls Harmony's PatchAll).
static class Invite
{
	public static bool On; // the current Host, Load or Join is by invite code
	public static bool Bypass; // running the game's own Host, Load or Join after the choice
	public const ushort GamePort = 33771;
	const string ConfigPath = "user://tailcat_invites.cfg";

	static Helper? _host, _join;
	static string _invite = "", _code = "";
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
		string invite = _code;
		Overlay.Show("Connecting to the host…");
		var ready = new TaskCompletionSource<string?>(TaskCreationOptions.RunContinuationsAsynchronously);
		_join = Helper.Start(new[] { "join", invite }, (kind, e) =>
		{
			if (kind == "ready") ready.TrySetResult(null);
			else ready.TrySetResult(e.TryGetProperty("message", out var m) ? m.GetString() : "the helper stopped");
		});
		if (_join == null)
		{
			Overlay.Show("Invite codes aren't available: the mod's helper is missing from its folder.", "", 8);
			Back(screen);
			return;
		}
		var done = await Task.WhenAny(ready.Task, Task.Delay(25_000));
		string? error = done == ready.Task ? ready.Task.Result : "timed out";
		if (error != null)
		{
			Log("couldn't connect: " + error);
			StopJoin();
			Overlay.Show("Couldn't connect with that code. Check the host is still hosting, or ask for a new code.", "", 8);
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
			Overlay.Show("Invite codes aren't available: the mod's helper is missing from its folder.", "", 8);
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
				string here = $"{players} player{(players == 1 ? "" : "s")} here";
				if (_invite == "") Overlay.Show($"Hosting with an invite code · getting a code… · {here}");
				else Overlay.Show($"Hosting with an invite code · send it to the others · {here}",
					System.Environment.TickCount64 - _copiedAt < 3000 ? "Copied" : "Copy invite code");
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

	// ---- the choice: Steam or invite code ----

	const string CodeHint = "Anyone with the code can join, including on iPhone and iPad with the iOS port.";

	public static void ChooseHost(Action host, bool load)
	{
		Dialog.Choose(load ? "Continue the multiplayer run" : "Host a multiplayer game",
			"Through Steam, your Steam friends join you. With an invite code, you get a code to send to the others. " + CodeHint,
			new[] { load ? "Continue via Steam" : "Host via Steam", load ? "Continue with an invite code" : "Host with an invite code" },
			choice =>
			{
				if (choice < 0) return;
				SetMode(choice == 1);
				Run(host);
			});
	}

	public static void ChooseJoin(Action join)
	{
		Dialog.Choose("Join a multiplayer game", "Join a Steam friend's game, or enter the invite code the host sent you. " + CodeHint,
			new[] { "Join a Steam friend", "Join with an invite code" },
			choice =>
			{
				if (choice == 0)
				{
					SetMode(false);
					Run(join);
				}
				else if (choice == 1)
					Dialog.AskCode(code =>
					{
						if (code == null) return;
						_code = code;
						SetMode(true);
						Run(join);
					});
			});
	}

	static void Run(Action action)
	{
		Bypass = true;
		try { action(); }
		finally { Bypass = false; }
	}

	public static void SetMode(bool invite)
	{
		if (invite != On) Log(invite ? "using an invite code" : "using Steam");
		On = invite;
		SetFastMp(invite);
	}

	public static bool LooksLikeCode(string text) => text.StartsWith("tc", StringComparison.Ordinal) && text.Length > 20;

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

// Centered dialogs over a dimmed screen, styled like the banner.
static class Dialog
{
	static readonly Color Gold = new(0.95f, 0.82f, 0.45f);

	/// Calls done with the chosen option's index, or -1 for Cancel.
	public static void Choose(string title, string text, string[] options, Action<int> done)
	{
		var (layer, column) = Open(title, text);
		var row = Row(column);
		for (int i = 0; i < options.Length; i++)
		{
			int choice = i;
			var b = Button(options[i], () => { layer.QueueFree(); done(choice); });
			row.AddChild(b);
			if (i == 0) b.CallDeferred(Control.MethodName.GrabFocus);
		}
		row.AddChild(Button("Cancel", () => { layer.QueueFree(); done(-1); }));
	}

	/// Calls done with the code entered, or null for Cancel.
	public static void AskCode(Action<string?> done)
	{
		var (layer, column) = Open("Join with an invite code",
			"Ask the host to tap Copy invite code and send it to you, then paste it here.");
		var field = new LineEdit
		{
			PlaceholderText = "Invite code (starts with tc)", CustomMinimumSize = new Vector2(820, 64),
			SizeFlagsHorizontal = Control.SizeFlags.ExpandFill,
		};
		field.AddThemeFontSizeOverride("font_size", 24);
		string clip = DisplayServer.ClipboardGet().Trim();
		if (Invite.LooksLikeCode(clip)) field.Text = clip;
		column.AddChild(field);
		var error = new Label { Visible = false };
		error.AddThemeColorOverride("font_color", new Color(1f, 0.6f, 0.5f));
		error.AddThemeFontSizeOverride("font_size", 22);
		column.AddChild(error);
		void Submit()
		{
			string code = field.Text.Trim();
			if (!Invite.LooksLikeCode(code))
			{
				error.Text = "That isn't an invite code. Copy the whole code the host sent (it starts with tc).";
				error.Visible = true;
				return;
			}
			layer.QueueFree();
			done(code);
		}
		field.TextSubmitted += _ => Submit();
		var row = Row(column);
		row.AddChild(Button("Paste", () => field.Text = DisplayServer.ClipboardGet().Trim()));
		row.AddChild(Button("Join", Submit));
		row.AddChild(Button("Cancel", () => { layer.QueueFree(); done(null); }));
		field.CallDeferred(Control.MethodName.GrabFocus);
	}

	static (CanvasLayer, VBoxContainer) Open(string title, string text)
	{
		var layer = new CanvasLayer { Layer = 120, ProcessMode = Node.ProcessModeEnum.Always };
		var dim = new ColorRect { Color = new Color(0, 0, 0, 0.7f) };
		dim.SetAnchorsPreset(Control.LayoutPreset.FullRect);
		layer.AddChild(dim);
		var center = new CenterContainer();
		center.SetAnchorsPreset(Control.LayoutPreset.FullRect);
		layer.AddChild(center);
		var panel = new PanelContainer { CustomMinimumSize = new Vector2(900, 0) };
		var box = new StyleBoxFlat
		{
			BgColor = new Color(0.08f, 0.09f, 0.12f, 0.97f), BorderColor = Gold,
			ContentMarginLeft = 36, ContentMarginRight = 36, ContentMarginTop = 28, ContentMarginBottom = 28,
		};
		box.SetBorderWidthAll(3);
		box.SetCornerRadiusAll(18);
		panel.AddThemeStyleboxOverride("panel", box);
		center.AddChild(panel);
		var column = new VBoxContainer();
		column.AddThemeConstantOverride("separation", 18);
		panel.AddChild(column);
		var heading = new Label { Text = title };
		heading.AddThemeFontSizeOverride("font_size", 36);
		heading.AddThemeColorOverride("font_color", Gold);
		Font(heading);
		column.AddChild(heading);
		var body = new Label { Text = text, AutowrapMode = TextServer.AutowrapMode.WordSmart, CustomMinimumSize = new Vector2(820, 0) };
		body.AddThemeFontSizeOverride("font_size", 24);
		column.AddChild(body);
		((SceneTree)Engine.GetMainLoop()).Root.AddChild(layer);
		return (layer, column);
	}

	static HBoxContainer Row(VBoxContainer column)
	{
		var row = new HBoxContainer { Alignment = BoxContainer.AlignmentMode.End };
		row.AddThemeConstantOverride("separation", 16);
		column.AddChild(row);
		return row;
	}

	static Button Button(string text, Action pressed)
	{
		var b = new Button { Text = text, CustomMinimumSize = new Vector2(180, 60) };
		b.AddThemeFontSizeOverride("font_size", 24);
		foreach (var state in new[] { "normal", "hover", "pressed", "focus" })
		{
			var box = new StyleBoxFlat
			{
				BgColor = state == "pressed" ? new Color(0.3f, 0.26f, 0.14f) : state == "hover" ? new Color(0.22f, 0.22f, 0.28f) : new Color(0.16f, 0.17f, 0.22f),
				BorderColor = new Color(Gold, state == "focus" ? 1f : 0.8f),
				ContentMarginLeft = 18, ContentMarginRight = 18, ContentMarginTop = 8, ContentMarginBottom = 8,
			};
			box.SetBorderWidthAll(state == "focus" ? 3 : 2);
			box.SetCornerRadiusAll(12);
			b.AddThemeStyleboxOverride(state, box);
		}
		Font(b);
		b.Pressed += pressed;
		return b;
	}

	static void Font(Control c)
	{
		if (ResourceLoader.Exists(Overlay.FontPath)) c.AddThemeFontOverride("font", GD.Load<Font>(Overlay.FontPath));
	}
}

// ---- patches ----

[HarmonyPatch(typeof(NMultiplayerSubmenu), "OnHostPressed")]
static class AskHowToHost
{
	static bool Prefix(NMultiplayerSubmenu __instance, object __0)
	{
		if (Invite.Bypass) return true;
		Invite.ChooseHost(() => AccessTools.Method(typeof(NMultiplayerSubmenu), "OnHostPressed").Invoke(__instance, new[] { __0 }), false);
		return false;
	}
}

[HarmonyPatch(typeof(NMultiplayerSubmenu), "StartLoad")]
static class AskHowToLoad
{
	static bool Prefix(NMultiplayerSubmenu __instance, object __0)
	{
		if (Invite.Bypass) return true;
		Invite.ChooseHost(() => AccessTools.Method(typeof(NMultiplayerSubmenu), "StartLoad").Invoke(__instance, new[] { __0 }), true);
		return false;
	}
}

[HarmonyPatch(typeof(NMultiplayerSubmenu), "OpenJoinFriendsScreen")]
static class AskHowToJoin
{
	static bool Prefix(NMultiplayerSubmenu __instance, object __0)
	{
		if (Invite.Bypass) return true;
		Invite.ChooseJoin(() => AccessTools.Method(typeof(NMultiplayerSubmenu), "OpenJoinFriendsScreen").Invoke(__instance, new[] { __0 }));
		return false;
	}
}

// Back on the Multiplayer screen, the next Host, Load or Join asks again; until then the game stays on Steam (e.g.
// for invites accepted in the Steam overlay).
[HarmonyPatch(typeof(NMultiplayerSubmenu), "OnSubmenuShown")]
static class BackToSteam
{
	static void Postfix() => Invite.SetMode(false);
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
