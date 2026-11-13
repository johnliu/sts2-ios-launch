#nullable enable
using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Runtime.CompilerServices;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using Godot;
using MegaCrit.Sts2.Core.Entities.Multiplayer;
using MegaCrit.Sts2.Core.Models;
using MegaCrit.Sts2.Core.Models.Characters;
using MegaCrit.Sts2.Core.Multiplayer;
using MegaCrit.Sts2.Core.Multiplayer.Connection;
using MegaCrit.Sts2.Core.Multiplayer.Serialization;
using MegaCrit.Sts2.Core.Nodes;
using MegaCrit.Sts2.Core.Nodes.GodotExtensions;
using MegaCrit.Sts2.Core.Nodes.Multiplayer;
using MegaCrit.Sts2.Core.Nodes.Rooms;
using MegaCrit.Sts2.Core.Nodes.Screens.CharacterSelect;
using MegaCrit.Sts2.Core.Nodes.Screens.MainMenu;
using MegaCrit.Sts2.Core.Unlocks;
using MegaCrit.Sts2.Port;
#if STS2_V0113
using LobbyPlayer = MegaCrit.Sts2.Core.Entities.Multiplayer.StartRunLobbyPlayer;
#endif

namespace PortMultiplayer;

// iOS port: multiplayer over the game's ENet (direct IP) transport, which it uses whenever Steamworks isn't
// running. sts2.dll is IL-patched (tools/patcher) so the Join screen asks for the host's IP (the game joins
// 127.0.0.1), hosting reports this device's addresses, and a joining device uses its own player id.
// An iOS host takes up to 6 players (the game's limit is 4): see the "six players" section below.
static class PortMp
{
	const ushort Port = 33771; // NMultiplayerSubmenu.StartENetHost / ENetClientConnectionInitializer
	const string ConfigPath = "user://port_mp.cfg";
	const int MaxPlayers = 6;
	// Testing: with this file present, the next hosted lobby also lists that many fake players (UI preview only;
	// the file is deleted once used).
	const string PreviewFlag = "user://port_mp_preview";
	static readonly Regex Ipv4 = new(@"^\d{1,3}(\.\d{1,3}){3}$");

	static Node? _ui;
	static TaskCompletionSource<(string Kind, string Arg)>? _choice;
	static int _hostGeneration;
	// Join dialog lists: games found on the Wi-Fi (PortDiscovery) and paired phones hosting nearby (PortNearby).
	static List<PortDiscovery.Host> _lanHosts = new();
	static List<(ulong Id, string Name)> _nearbyHosts = new();
	static int _browseGeneration;
	static long _inviteCopiedAt = long.MinValue / 2;
	static bool _hostChosen, _hostByInvite;
	const string NearbyPrefix = "nearby:";

	[ModuleInitializer]
	internal static void Init()
	{
		PortHooks.MpJoin = JoinAsync;
		PortHooks.MpHostPressed = (menu, button) => AskHowToHost(menu, button, false);
		PortHooks.MpLoadPressed = (menu, button) => AskHowToHost(menu, button, true);
		PortHooks.OnENetHost = OnHost;
		PortHooks.NullPlayerName = PlayerName;
		PortHooks.RestSiteSeats = AddRestSiteSeats;
		PortHooks.TreasureRelicHolders = AddTreasureRelicHolders;
		PortHooks.AfterEssentialInit += EnableSixPlayers;
		PortHooks.AfterEssentialInit += PortKeepAlive.Install;
	}

	static void Log(string msg) => GD.Print("[MP] " + msg);

	static ulong LocalId => PortHooks.NullPlayerId != 0 ? PortHooks.NullPlayerId : 1;

	static string PlayerName(ulong id)
	{
		if (id == LocalId && PortNames.MyName is { } me) return me;
		return PortNames.Lookup(id) ?? PortNames.Fallback(id);
	}

	static ConfigFile Config()
	{
		var cfg = new ConfigFile();
		cfg.Load(ConfigPath);
		return cfg;
	}

	// Stable per-device id when joining (the host is always 1; the game's default client id 1000 would collide
	// when two port devices join the same host).
	static ulong ClientId()
	{
		var cfg = Config();
		long id = cfg.GetValue("mp", "client_id", 0L).AsInt64();
		if (id <= 1000)
		{
			id = Random.Shared.Next(1001, 1_000_000);
			cfg.SetValue("mp", "client_id", id);
			cfg.Save(ConfigPath);
		}
		return (ulong)id;
	}

	// ---- join ----

	static async Task JoinAsync(NJoinFriendScreen screen)
	{
		var cfg = Config();
		string ip = cfg.GetValue("mp", "last_ip", "").AsString();
		var recent = cfg.GetValue("mp", "recent_ips", new string[0]).AsStringArray();
		var (wifi, tailscale) = Addresses();
		string error = "";
		var ui = EnsureUi();
		bool nearby = false; // whether the chosen game is a nearby one
		string nearbyName = "";
		bool invite = false; // or one joined with an invite code, over Tailcat
		if (PortTailcat.Supported)
		{
			ui.Call("show_choice", "Join a multiplayer game",
				"Pick a game nearby or on your Wi-Fi, or enter the invite code the host sent you. With a code, you can be anywhere.",
				new Godot.Collections.Array { "Nearby or on Wi-Fi", "With an invite code" });
			var (kind, arg) = await NextChoice();
			if (kind != "choice" || arg == "-1")
			{
				LeaveJoinScreen(screen);
				return;
			}
			while (arg == "1" && !invite)
			{
				ui.Call("show_code", error);
				var (k, code) = await NextChoice();
				if (k != "code")
				{
					LeaveJoinScreen(screen);
					return;
				}
				(invite, error) = await ConnectInvite(code.Trim());
			}
		}
		if (!invite)
		{
			PokeLocalNetwork(wifi); // brings up iOS's Local Network prompt while the IP is being typed
			_lanHosts = new();
			_nearbyHosts = new();
			ui.Call("set_hosts", new Godot.Collections.Array());
			PortDiscovery.Start(recent.Append(ip), hosts => Callable.From(() => ShowHosts(hosts)).CallDeferred());
			bool browsing = PortNearby.Supported;
			int browse = ++_browseGeneration;
			ui.Call("set_nearby", browsing, PortNearby.PairedCount);
			if (browsing)
			{
				PortNearby.Browse(true);
				_ = PollNearbyHosts(browse);
			}
			try
			{
				while (true)
				{
					ui.Call("show_join", ip, error);
					var (kind, arg) = await NextChoice();
					if (kind != "join")
					{
						LeaveJoinScreen(screen);
						return;
					}
					string choice = arg.Trim();
					if (choice.StartsWith(NearbyPrefix, StringComparison.Ordinal))
					{
						(nearby, nearbyName, error) = await ConnectNearby(choice);
						if (nearby) break;
						continue;
					}
					ip = choice;
					if (Ipv4.IsMatch(ip) && IPAddress.TryParse(ip, out _)) break;
					error = "That isn't an IP address. It looks like 192.168.1.20.";
				}
			}
			finally
			{
				PortDiscovery.Stop();
				_browseGeneration++;
				PortNearby.Browse(false);
			}
		}
		if (nearby || invite)
		{
			ip = "127.0.0.1"; // the relay to the host (src/ios/nearby_play.swift, src/tailcat/ios/tailcat_play.go)
		}
		else
		{
			cfg.SetValue("mp", "last_ip", ip);
			cfg.SetValue("mp", "recent_ips", new[] { ip }.Concat(recent.Where(r => r != ip)).Take(6).ToArray());
			cfg.Save(ConfigPath);
		}
		CloseUi();
		ulong id = ClientId();
		PortHooks.NullPlayerId = id;
		Log(nearby ? $"joining {nearbyName} nearby over Wi-Fi Aware as player {id} ({PortNearby.Status})"
			: invite ? $"joining by invite over Tailcat as player {id} ({PortTailcat.Status})"
			: $"joining {ip}:{Port} as player {id} (this device: {wifi ?? "no Wi-Fi"}{(tailscale != null ? ", Tailscale " + tailscale : "")})");
		await PortNames.StartClient(ip, id);
		var previous = PortHooks.ClientService;
		var join = screen.JoinGameAsync(new ENetClientConnectionInitializer(id, ip, Port));
		// The join makes its client service before it first waits; keep the app running while that's connected.
		var tracked = PortHooks.ClientService;
		if (tracked != null && tracked != previous) PortKeepAlive.Track(() => tracked.IsConnected);
		await join;
		var joined = PortHooks.ClientService;
		if (joined != null && joined != previous && joined != tracked) PortKeepAlive.Track(() => joined.IsConnected);
		if (nearby) _ = CloseNearbyWhenDone(joined ?? tracked);
		if (invite) _ = CloseInviteWhenDone(joined ?? tracked);
	}

	// Leaves the (empty) join screen as if its back button was pressed.
	static void LeaveJoinScreen(NJoinFriendScreen screen)
	{
		CloseUi();
		var back = screen.GetNodeOrNull<Control>("BackButton");
		back?.EmitSignal("Released", back);
	}

	// ---- nearby (Wi-Fi Aware, src/native/Port/PortNearby.cs) ----

	static SignalAwaiter Wait(double seconds)
	{
		var tree = (SceneTree)Engine.GetMainLoop();
		return tree.ToSignal(tree.CreateTimer(seconds, true, false, true), SceneTreeTimer.SignalName.Timeout);
	}

	// Refreshes the nearby games in the join dialog while it's open.
	static async Task PollNearbyHosts(int generation)
	{
		while (generation == _browseGeneration)
		{
			var hosts = PortNearby.Hosts();
			if (!hosts.SequenceEqual(_nearbyHosts))
			{
				_nearbyHosts = hosts;
				RenderHosts();
			}
			if (_ui != null && GodotObject.IsInstanceValid(_ui)) _ui.Call("set_nearby", true, PortNearby.PairedCount);
			await Wait(0.5);
		}
	}

	// Opens the Wi-Fi Aware relay to a nearby host. Returns whether it's ready, the host's name, and an error to show.
	static async Task<(bool Ok, string Name, string Error)> ConnectNearby(string choice)
	{
		ulong.TryParse(choice.AsSpan(NearbyPrefix.Length), out ulong device);
		string name = _nearbyHosts.FirstOrDefault(h => h.Id == device).Name ?? "the other phone";
		EnsureUi().Call("show_note", $"Connecting to {name}…");
		PortNearby.Join(device);
		for (int i = 0; i < 100; i++) // 20 s
		{
			int state = PortNearby.JoinState;
			if (state == 2) return (true, name, "");
			if (state != 1) break;
			await Wait(0.2);
		}
		string why = PortNearby.Status;
		PortNearby.Leave();
		Log($"nearby: couldn't connect to {name} ({why})");
		return (false, name, $"Couldn't connect to {name}. Keep the phones close, check it's still hosting, and try again.");
	}

	// Closes the relay once the game has left the nearby host's session.
	static async Task CloseNearbyWhenDone(NetClientGameService? service)
	{
		while (PortNearby.JoinState == 2 && service != null && service.IsConnected) await Wait(2);
		Log($"nearby: left the host's game ({PortNearby.Status})");
		PortNearby.Leave();
	}

	// Offers this phone's game to paired phones nearby until it stops hosting.
	static async Task OfferNearby(NetHostGameService service, int generation)
	{
		PortNearby.Host(true);
		Log($"nearby: hosting for paired phones ({PortNearby.Status})");
		while (generation == _hostGeneration && service.IsConnected) await Wait(1);
		if (generation == _hostGeneration) PortNearby.Host(false); // a newer host keeps offering
		Log($"nearby: stopped hosting ({PortNearby.Status})");
	}

	// ---- invite (Tailcat, src/native/Port/PortTailcat.cs) ----

	// Opens the Tailcat relay to the host whose invite was pasted. Returns whether it's ready, and an error to show.
	static async Task<(bool Ok, string Error)> ConnectInvite(string invite)
	{
		EnsureUi().Call("show_note", "Connecting to the host…");
		PortTailcat.Join(invite);
		for (int i = 0; i < 125; i++) // 25 s
		{
			int state = PortTailcat.JoinState;
			if (state == 2) return (true, "");
			if (state != 1) break;
			await Wait(0.2);
		}
		string why = PortTailcat.Status;
		PortTailcat.Leave();
		Log($"tailcat: couldn't connect ({why})");
		return (false, "Couldn't connect with that invite. Check the host is still hosting, or ask for a new invite.");
	}

	static async Task CloseInviteWhenDone(NetClientGameService? service)
	{
		while (PortTailcat.JoinState == 2 && service != null && service.IsConnected) await Wait(2);
		Log($"tailcat: left the host's game ({PortTailcat.Status})");
		PortTailcat.Leave();
	}

	// Offers this phone's game by invite until it stops hosting.
	static async Task OfferInvite(NetHostGameService service, int generation)
	{
		PortTailcat.Host(true);
		while (generation == _hostGeneration && service.IsConnected) await Wait(1);
		if (generation == _hostGeneration) PortTailcat.Host(false); // a newer host keeps offering
		Log($"tailcat: stopped hosting ({PortTailcat.Status})");
	}

	static void CopyInvite()
	{
		string invite = PortTailcat.Address;
		if (invite == "") return;
		DisplayServer.ClipboardSet(invite);
		_inviteCopiedAt = System.Environment.TickCount64;
	}

	// Join dialog list (main thread).
	static void ShowHosts(List<PortDiscovery.Host> hosts)
	{
		_lanHosts = hosts;
		RenderHosts();
	}

	static void RenderHosts()
	{
		if (_ui == null || !GodotObject.IsInstanceValid(_ui)) return;
		string mine = PortNames.GameVersion;
		var list = new Godot.Collections.Array();
		foreach (var (id, name) in _nearbyHosts)
			list.Add(new Godot.Collections.Dictionary
			{
				["ip"] = NearbyPrefix + id,
				["title"] = $"{name}, nearby",
				["detail"] = "Wi-Fi Aware: no Wi-Fi network needed",
				["joinable"] = true,
			});
		foreach (var h in _lanHosts)
		{
			bool sameVersion = h.Version == "" || mine == "" || h.Version == mine;
			string detail = !sameVersion ? $"different game version ({h.Version}, you have {mine})"
				: h.InRun ? "run in progress, can't join"
				: h.Players >= h.Max ? $"full ({h.Players} of {h.Max} players)"
				: $"{h.Players} of {h.Max} player{(h.Max == 1 ? "" : "s")} · {h.Ip}";
			list.Add(new Godot.Collections.Dictionary
			{
				["ip"] = h.Ip,
				["title"] = h.Name.Length > 0 ? $"{h.Name}'s game" : $"Game at {h.Ip}",
				["detail"] = detail,
				["joinable"] = sameVersion && !h.InRun && h.Players < h.Max,
			});
		}
		_ui.Call("set_hosts", list);
	}

	// ---- host ----

	static void OnHost(NetHostGameService service)
	{
		PortHooks.NullPlayerId = 0; // the ENet host is player 1, which is also the null platform's own id
		PortNames.StartHost(service);
		PortKeepAlive.Track(() => service.IsConnected);
		int generation = ++_hostGeneration;
		_ = HostBannerLoop(service, generation);
		if (PortNearby.Supported) _ = OfferNearby(service, generation);
		if (_hostByInvite && PortTailcat.Supported) _ = OfferInvite(service, generation);
	}

	// Host and Load (patched: src/patcher) first ask how others join. Returns whether the game's own handler waits.
	static bool AskHowToHost(NMultiplayerSubmenu menu, NButton button, bool load)
	{
		if (_hostChosen) return false;
		_hostByInvite = false;
		if (!PortTailcat.Supported) return false;
		_ = ChooseHost(menu, button, load);
		return true;
	}

	static async Task ChooseHost(NMultiplayerSubmenu menu, NButton button, bool load)
	{
		var ui = EnsureUi();
		ui.Call("show_choice", load ? "Continue the multiplayer run" : "Host a multiplayer game",
			"Others join nearby or on your Wi-Fi, or from anywhere with an invite code you send them.",
			new Godot.Collections.Array { "Nearby or on Wi-Fi", "With an invite code" });
		var (kind, arg) = await NextChoice();
		CloseUi();
		if (kind != "choice" || arg == "-1") return;
		_hostByInvite = arg == "1";
		_hostChosen = true;
		try
		{
			if (load) menu.StartLoad(button);
			else menu.OnHostPressed(button);
		}
		finally { _hostChosen = false; }
	}

	static async Task HostBannerLoop(NetHostGameService service, int generation)
	{
		var tree = (SceneTree)Engine.GetMainLoop();
		await tree.ToSignal(tree, SceneTree.SignalName.ProcessFrame); // StartENetHost is still running
		var (wifi, tailscale) = Addresses();
		PokeLocalNetwork(wifi);
		var where = new List<string>();
		if (wifi != null) where.Add(wifi);
		if (tailscale != null) where.Add($"{tailscale} (Tailscale)");
		string address = where.Count > 0 ? string.Join(" or ", where) : "this device's IP address";
		bool nearby = PortNearby.Supported;
		if (nearby) address += " or nearby";
		Log($"hosting on {address}, port {Port}");
		// The lobby (character select) is part of the main menu; hide once the run starts or hosting stops.
		bool byInvite = _hostByInvite && PortTailcat.Supported;
		bool previewed = false, inviteLogged = false;
		while (generation == _hostGeneration && service.IsConnected && NGame.Instance?.MainMenu != null)
		{
			int players = service.ConnectedPeers.Count + 1;
			int cap = PortHooks.LanMaxPlayers(4);
			string here = $"{players} of {cap} players here";
			if (byInvite)
			{
				bool ready = PortTailcat.Address != "";
				if (ready && !inviteLogged) Log($"tailcat: invite ready ({PortTailcat.Status})");
				inviteLogged |= ready;
				EnsureUi().Call("show_banner",
					ready ? $"Hosting with an invite code · send it to the others · {here}" : $"Hosting with an invite code · getting a code… · {here}",
					"", !ready ? "" : System.Environment.TickCount64 - _inviteCopiedAt < 3000 ? "Copied" : "Copy invite code");
			}
			else EnsureUi().Call("show_banner", $"Hosting · others join at {address} · {here}", nearby ? "Pair a phone" : "");
			if (!previewed) previewed = PreviewLobby(tree);
			await tree.ToSignal(tree.CreateTimer(1.0, true, false, true), SceneTreeTimer.SignalName.Timeout);
		}
		if (generation == _hostGeneration && _ui != null && GodotObject.IsInstanceValid(_ui)) _ui.Call("hide_banner");
	}

	// ---- six players ----
	// The game hosts at most 4. Raising the cap (PortHooks.LanPlayerCap, read where the game passed 4) needs:
	//  - LobbyPlayer.slotId: 2 bits on the wire; slots 4-5 carry the extra bit (patched Serialize/Deserialize),
	//  - rest site seats and treasure relic holders for players 5-6 (the scenes have four of each).
	// A PC can't join an iOS host (its Join is localhost-only), so only patched devices see slots 4-5.

	// Checks the patched LobbyPlayer encoding before allowing more than 4 players: slots 0-5 must round-trip and
	// slots 0-3 must produce exactly the game's original bytes.
	static void EnableSixPlayers()
	{
		try
		{
			var character = ModelDb.Character<Ironclad>();
			var writer = new PacketWriter { WarnOnGrow = false };
			var vanilla = new PacketWriter { WarnOnGrow = false };
			var reader = new PacketReader();
			for (int slot = 0; slot < MaxPlayers; slot++)
			{
				var p = new LobbyPlayer
				{
					id = 1001UL + (ulong)slot, slotId = slot, character = character, unlockState = new SerializableUnlockState(),
#if STS2_V0113
					maxStandardAscension = 3 * slot, maxBlitzAscension = slot, isRotatingDread = slot % 3 == 0, isModded = false,
#else
					maxMultiplayerAscensionUnlocked = 3 * slot,
#endif
					isReady = slot % 2 == 1,
				};
				writer.Reset();
				p.Serialize(writer);
				byte[] bytes = writer.Buffer.AsSpan(0, writer.BytePosition).ToArray();
				reader.Reset(bytes);
				var q = new LobbyPlayer();
				q.Deserialize(reader);
#if STS2_V0113
				int pAsc = p.maxStandardAscension, qAsc = q.maxStandardAscension;
				bool same = q.maxBlitzAscension == p.maxBlitzAscension && q.isRotatingDread == p.isRotatingDread && q.isModded == p.isModded;
#else
				int pAsc = p.maxMultiplayerAscensionUnlocked, qAsc = q.maxMultiplayerAscensionUnlocked;
				bool same = true;
#endif
				if (q.id != p.id || q.slotId != p.slotId || qAsc != pAsc || !same || q.isReady != p.isReady || q.character != p.character)
					throw new Exception($"slot {slot} read back as slot {q.slotId}, ascension {qAsc}");
				if (slot < 4)
				{
					vanilla.Reset();
					vanilla.WriteULong(p.id);
					vanilla.WriteInt(p.slotId, 2);
					vanilla.WriteModel(p.character);
					vanilla.Write(p.unlockState);
#if STS2_V0113
					vanilla.WriteInt(p.maxStandardAscension, 8);
					vanilla.WriteInt(p.maxBlitzAscension, 8);
					vanilla.WriteBool(p.isRotatingDread);
					vanilla.WriteBool(p.isModded);
#else
					vanilla.WriteInt(p.maxMultiplayerAscensionUnlocked);
#endif
					vanilla.WriteBool(p.isReady);
					if (!vanilla.Buffer.AsSpan(0, vanilla.BytePosition).SequenceEqual(bytes))
						throw new Exception($"slot {slot} no longer matches the game's own encoding");
				}
			}
			PortHooks.LanPlayerCap = MaxPlayers;
			Log($"hosting allows up to {MaxPlayers} players (lobby encoding checked)");
		}
		catch (Exception e)
		{
			PortHooks.LanPlayerCap = 0;
			Log("hosting stays at 4 players: lobby encoding check failed: " + e.Message);
		}
	}

	// Rest site: two seats on each log around the fire; players 5 and 6 sit on the grass just beyond the logs
	// (BgContainer coordinates, like the scene's Character_1..4 at (625,642) (1239,649) (750,585) (1092,583)).
	static readonly Vector2[] ExtraSeats = { new(445, 712), new(1420, 716) };

	static void AddRestSiteSeats(NRestSiteRoom room, List<Control> seats)
	{
		var template = seats[^1];
		var parent = template.GetParent();
		for (int i = seats.Count; i < MaxPlayers && i - 4 < ExtraSeats.Length; i++)
		{
			var seat = (Control)template.Duplicate();
			seat.Name = $"Character_{i + 1}";
			var at = ExtraSeats[i - 4];
			seat.OffsetLeft = seat.OffsetRight = at.X;
			seat.OffsetTop = seat.OffsetBottom = at.Y;
			parent.AddChild(seat); // last = drawn in front, as they're nearer than the log seats
			seats.Add(seat);
		}
	}

	// Treasure: one relic per player on holders around the chest. The scene's four (136 px) fill a diamond:
	// top-left and bottom-right of the centre, far left, far right. Players 5 and 6 get the two free centre corners.
	static readonly Vector2[] ExtraHolders = { new(-148, 44), new(12, -180) };
	const string HolderScene = "res://scenes/ui/treasure_relic_holder.tscn";

	static void AddTreasureRelicHolders(Control container)
	{
		if (container.GetNodeOrNull("MultiplayerRelicHolder4") == null || container.HasNode("MultiplayerRelicHolder5")) return;
		var scene = GD.Load<PackedScene>(HolderScene);
		for (int i = 0; i < ExtraHolders.Length; i++)
		{
			var holder = scene.Instantiate<Control>();
			holder.Name = $"MultiplayerRelicHolder{5 + i}";
			holder.Visible = false;
			holder.SetAnchorsPreset(Control.LayoutPreset.Center);
			holder.GrowHorizontal = holder.GrowVertical = Control.GrowDirection.Both;
			var at = ExtraHolders[i];
			holder.OffsetLeft = at.X;
			holder.OffsetTop = at.Y;
			holder.OffsetRight = at.X + 136;
			holder.OffsetBottom = at.Y + 136;
			container.AddChild(holder); // after holders 1-4: the game numbers holders in child order
		}
	}

	// UI preview: adds fake players to a hosted lobby's player list so a full lobby can be checked on one device.
	static bool PreviewLobby(SceneTree tree)
	{
		if (!FileAccess.FileExists(PreviewFlag)) return true;
		var screen = tree.Root.FindChildren("*", "", true, false)
			.OfType<NCharacterSelectScreen>().FirstOrDefault(s => s.IsVisibleInTree());
		if (screen == null) return false;
		var list = screen.Get("_remotePlayerContainer").As<NRemoteLobbyPlayerContainer>();
		if (list == null) return false;
		int fakes = Math.Min(FileAccess.GetFileAsString(PreviewFlag).Trim().ToInt(), MaxPlayers - 1);
		DirAccess.RemoveAbsolute(ProjectSettings.GlobalizePath(PreviewFlag)); // one-shot
		for (int i = 0; i < fakes; i++)
			list.OnPlayerConnected(new LobbyPlayer
			{
				id = 900001UL + (ulong)i, slotId = i + 1, character = ModelDb.Character<Ironclad>(),
				unlockState = new SerializableUnlockState(),
			});
		Log($"lobby preview: added {Math.Max(fakes, 0)} fake player(s)");
		return true;
	}

	// ---- network helpers ----

	// Wi-Fi (en0) and Tailscale (utun, 100.64.0.0/10) IPv4 addresses.
	static (string? Wifi, string? Tailscale) Addresses()
	{
		string? wifi = null, tailscale = null;
		foreach (var iface in IP.GetLocalInterfaces())
		{
			string name = iface["name"].AsString();
			foreach (var v in iface["addresses"].AsGodotArray())
			{
				string a = v.AsString();
				if (!IPAddress.TryParse(a, out var addr) || addr.AddressFamily != AddressFamily.InterNetwork) continue;
				var b = addr.GetAddressBytes();
				if (name == "en0" && b[0] != 169) wifi ??= a;
				else if (name.StartsWith("utun") && b[0] == 100 && b[1] >= 64 && b[1] < 128) tailscale ??= a;
			}
		}
		return (wifi, tailscale);
	}

	// iOS asks for Local Network access on the first LAN packet; send a harmless one (UDP discard port on
	// the router) so the prompt appears up front instead of dropping the first connection attempt.
	static void PokeLocalNetwork(string? wifi)
	{
		if (wifi == null) return;
		try
		{
			var parts = wifi.Split('.');
			var udp = new PacketPeerUdp();
			udp.SetDestAddress($"{parts[0]}.{parts[1]}.{parts[2]}.1", 9);
			udp.PutPacket(new byte[] { 0 });
			udp.Close();
		}
		catch (Exception e) { Log("local network probe failed: " + e.Message); }
	}

	// ---- UI (res://port/mp_ui.gd) ----

	static Node EnsureUi()
	{
		if (_ui != null && GodotObject.IsInstanceValid(_ui)) return _ui;
		var script = GD.Load<GDScript>("res://port/mp_ui.gd");
		_ui = (Node)script.New().AsGodotObject();
		_ui.Connect("join_submitted", Callable.From<string>(ip => _choice?.TrySetResult(("join", ip))));
		_ui.Connect("cancelled", Callable.From(() => { _choice?.TrySetResult(("cancel", "")); }));
		_ui.Connect("choice_made", Callable.From<int>(i => { _choice?.TrySetResult(("choice", i.ToString())); }));
		_ui.Connect("code_submitted", Callable.From<string>(code => { _choice?.TrySetResult(("code", code)); }));
		_ui.Connect("pair_requested", Callable.From(PortNearby.Pair));
		_ui.Connect("banner_action", Callable.From(PortNearby.Pair));
		_ui.Connect("banner_invite", Callable.From(CopyInvite));
		((SceneTree)Engine.GetMainLoop()).Root.CallDeferred(Node.MethodName.AddChild, _ui);
		return _ui;
	}

	static Task<(string Kind, string Arg)> NextChoice()
	{
		_choice = new TaskCompletionSource<(string, string)>(TaskCreationOptions.RunContinuationsAsynchronously);
		return _choice.Task;
	}

	static void CloseUi()
	{
		if (_ui != null && GodotObject.IsInstanceValid(_ui)) _ui.Call("close_join");
	}
}
