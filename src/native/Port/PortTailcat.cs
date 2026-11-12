#nullable enable
using System;
using System.Runtime.InteropServices;

namespace PortMultiplayer;

// Multiplayer from anywhere over Tailcat (src/ios/tailcat/tailcat_play.go, linked into the app executable): the
// hosting phone shares an invite, and a joining phone relays the game's UDP ports to it through a WireGuard tunnel,
// so the game joins 127.0.0.1. No Tailscale account, app or VPN. Call only on the main thread.
static unsafe class PortTailcat
{
	static bool _loaded;
	static delegate* unmanaged<int> _joinState;
	static delegate* unmanaged<IntPtr> _status, _address;
	static delegate* unmanaged<int, void> _host;
	static delegate* unmanaged<IntPtr, void> _join;
	static delegate* unmanaged<void> _leave;

	static void Load()
	{
		if (_loaded) return;
		_loaded = true;
		var app = NativeLibrary.GetMainProgramHandle();
		IntPtr F(string name) => NativeLibrary.TryGetExport(app, name, out var p) ? p : IntPtr.Zero;
		_joinState = (delegate* unmanaged<int>)F("port_tailcat_join_state");
		_status = (delegate* unmanaged<IntPtr>)F("port_tailcat_status");
		_address = (delegate* unmanaged<IntPtr>)F("port_tailcat_address");
		_host = (delegate* unmanaged<int, void>)F("port_tailcat_host");
		_join = (delegate* unmanaged<IntPtr, void>)F("port_tailcat_join");
		_leave = (delegate* unmanaged<void>)F("port_tailcat_leave");
	}

	public static bool Supported
	{
		get
		{
			Load();
			return _joinState != null && _status != null && _address != null && _host != null && _join != null && _leave != null;
		}
	}

	/// Whether text looks like an invite (a Tailcat address) rather than an IP address.
	public static bool IsInvite(string text) => text.StartsWith("tc", StringComparison.Ordinal) && text.Length > 20;

	public static string Status => Supported ? Marshal.PtrToStringUTF8(_status()) ?? "" : "not in this build";

	public static void Host(bool on) { if (Supported) _host(on ? 1 : 0); }

	/// The invite to share while hosting ("" while it's starting).
	public static string Address => Supported ? Marshal.PtrToStringUTF8(_address()) ?? "" : "";

	public static void Join(string invite)
	{
		if (!Supported) return;
		IntPtr s = Marshal.StringToCoTaskMemUTF8(invite);
		try { _join(s); }
		finally { Marshal.FreeCoTaskMem(s); }
	}

	/// 0 not joined, 1 connecting, 2 ready (join 127.0.0.1), 3 failed or disconnected.
	public static int JoinState => Supported ? _joinState() : 0;

	public static void Leave() { if (Supported) _leave(); }
}
