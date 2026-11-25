#nullable enable
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text.Json;

namespace PortMultiplayer;

// Wi-Fi Aware multiplayer between phones in the same room (src/ios/nearby_play.swift, compiled into the app
// executable): the hosting phone offers its game to paired phones nearby, and a joining phone relays the game's UDP
// ports to it, so the game joins 127.0.0.1. Call only on the main thread.
static unsafe class PortNearby
{
	static bool _loaded;
	static delegate* unmanaged<int> _supported, _joinState, _pairedCount;
	static delegate* unmanaged<IntPtr> _status, _hosts, _events;
	static delegate* unmanaged<int, void> _host, _browse;
	static delegate* unmanaged<ulong, void> _join;
	static delegate* unmanaged<void> _leave, _pair;

	static void Load()
	{
		if (_loaded) return;
		_loaded = true;
		var app = NativeLibrary.GetMainProgramHandle();
		IntPtr F(string name) => NativeLibrary.TryGetExport(app, name, out var p) ? p : IntPtr.Zero;
		_supported = (delegate* unmanaged<int>)F("port_nearby_supported");
		_joinState = (delegate* unmanaged<int>)F("port_nearby_join_state");
		_pairedCount = (delegate* unmanaged<int>)F("port_nearby_paired_count");
		_status = (delegate* unmanaged<IntPtr>)F("port_nearby_status");
		_hosts = (delegate* unmanaged<IntPtr>)F("port_nearby_hosts");
		_events = (delegate* unmanaged<IntPtr>)F("port_nearby_events");
		_host = (delegate* unmanaged<int, void>)F("port_nearby_host");
		_browse = (delegate* unmanaged<int, void>)F("port_nearby_browse");
		_join = (delegate* unmanaged<ulong, void>)F("port_nearby_join");
		_leave = (delegate* unmanaged<void>)F("port_nearby_leave");
		_pair = (delegate* unmanaged<void>)F("port_nearby_pair");
	}

	/// This device runs Wi-Fi Aware (iOS 26, iPhone 12 or later) and the build has its entitlement.
	public static bool Supported
	{
		get
		{
			Load();
			return _supported != null && _supported() != 0 && _host != null && _join != null;
		}
	}

	public static string Status
	{
		get
		{
			Load();
			return _status == null ? "not in this build" : Marshal.PtrToStringUTF8(_status()) ?? "";
		}
	}

	/// Phones paired with this one (-1 before it's known).
	public static int PairedCount => Supported ? _pairedCount() : 0;

	public static void Host(bool on) { if (Supported) _host(on ? 1 : 0); }

	public static void Browse(bool on) { if (Supported) _browse(on ? 1 : 0); }

	/// Paired phones that are hosting now.
	public static List<(ulong Id, string Name)> Hosts()
	{
		var list = new List<(ulong, string)>();
		if (!Supported) return list;
		try
		{
			using var doc = JsonDocument.Parse(Marshal.PtrToStringUTF8(_hosts()) ?? "[]");
			foreach (var e in doc.RootElement.EnumerateArray())
				if (ulong.TryParse(e.GetProperty("id").GetString(), out ulong id))
					list.Add((id, e.GetProperty("name").GetString() ?? "Nearby phone"));
		}
		catch (Exception e) { Godot.GD.Print("[NEARBY] hosts: " + e.Message); }
		return list;
	}

	public static void Join(ulong device) { if (Supported) _join(device); }

	/// 0 not joined, 1 connecting, 2 ready (join 127.0.0.1; also while reconnecting a dropped link), 3 failed or
	/// disconnected.
	public static int JoinState => Supported ? _joinState() : 0;

	public static void Leave() { if (Supported) _leave(); }

	/// Relay events since the last call: links dropping, reconnecting or giving up.
	public static string[] DrainEvents()
	{
		if (!Supported || _events == null) return Array.Empty<string>();
		string s = Marshal.PtrToStringUTF8(_events()) ?? "";
		return s.Length == 0 ? Array.Empty<string>() : s.Split('\n');
	}

	/// Shows Apple's pairing screens.
	public static void Pair() { if (Supported) _pair(); }
}
