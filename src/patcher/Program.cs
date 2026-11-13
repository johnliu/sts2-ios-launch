// IL patches applied to GodotSharp.dll / sts2.dll before the iOS NativeAOT build.
using Mono.Cecil;
using Mono.Cecil.Cil;
using Mono.Cecil.Rocks;

if (args.Length != 2) { Console.Error.WriteLine("usage: patcher <in GodotSharp.dll|sts2.dll> <out dll>"); return 1; }
var resolver = new DefaultAssemblyResolver();
resolver.AddSearchDirectory(Path.GetDirectoryName(Path.GetFullPath(args[0]))!);
var asm = AssemblyDefinition.ReadAssembly(args[0], new ReaderParameters { InMemory = true, AssemblyResolver = resolver });
var module = asm.MainModule;
int patched = 0;

MethodDefinition Method(string typeName, string methodName)
{
	var type = module.GetType(typeName) ?? throw new Exception($"type {typeName} not found");
	return type.Methods.Single(m => m.Name == methodName && m.HasBody);
}

void Stub(string typeName, string methodName, Action<ILProcessor> emit)
{
	var type = module.GetType(typeName) ?? throw new Exception($"type {typeName} not found");
	var methods = type.Methods.Where(m => m.Name == methodName && m.HasBody).ToList();
	if (methods.Count == 0) throw new Exception($"{typeName}::{methodName} not found");
	foreach (var m in methods)
	{
		m.Body = new MethodBody(m);
		emit(m.Body.GetILProcessor());
		patched++;
		Console.WriteLine($"patched {m.FullName}");
	}
}

// Copies a static method (no exception handlers) under a new name in the same type.
MethodDefinition CloneStatic(MethodDefinition m, string name)
{
	if (!m.IsStatic || m.Body.HasExceptionHandlers) throw new Exception($"can't clone {m.FullName}");
	var c = new MethodDefinition(name, m.Attributes, m.ReturnType);
	foreach (var p in m.Parameters) c.Parameters.Add(new ParameterDefinition(p.Name, p.Attributes, p.ParameterType));
	foreach (var v in m.Body.Variables) c.Body.Variables.Add(new VariableDefinition(v.VariableType));
	c.Body.InitLocals = m.Body.InitLocals;
	var map = new Dictionary<Instruction, Instruction>();
	foreach (var ins in m.Body.Instructions)
	{
		var n = Instruction.Create(OpCodes.Nop);
		n.OpCode = ins.OpCode;
		n.Operand = ins.Operand switch
		{
			ParameterDefinition pd => c.Parameters[pd.Index],
			VariableDefinition vd => c.Body.Variables[vd.Index],
			_ => ins.Operand,
		};
		map[ins] = n;
		c.Body.Instructions.Add(n);
	}
	foreach (var n in c.Body.Instructions)
	{
		if (n.Operand is Instruction target) n.Operand = map[target];
		else if (n.Operand is Instruction[] targets) n.Operand = targets.Select(t => map[t]).ToArray();
	}
	m.DeclaringType.Methods.Add(c);
	return c;
}

if (asm.Name.Name == "GodotSharp")
{
	// Every engine warning/error captures a C# backtrace (very slow under NativeAOT) -> skip it.
	Stub("Godot.DebuggingUtils", "GetCurrentStackInfo", il => il.Emit(OpCodes.Ret));
	// iOS has no mouse cursor: these only produce "not supported" warnings, so make them no-ops.
	Stub("Godot.Input", "SetMouseMode", il => il.Emit(OpCodes.Ret));
	Stub("Godot.Input", "GetMouseMode", il => { il.Emit(OpCodes.Ldc_I4_0); il.Emit(OpCodes.Ret); }); // Visible
	Stub("Godot.Input", "SetCustomMouseCursor", il => il.Emit(OpCodes.Ret));

	// Engine.MaxFps: the game's FPS limit. On iOS, Metal enforces it by holding frames back at presentation while
	// the display link keeps running the game loop at 120 Hz, which paces frames unevenly. Remember what the game
	// asks for and let the port apply it (src/native/Port/PortFrameRate.cs: display link rate instead).
	{
		var engine = module.GetType("Godot.Engine") ?? throw new Exception("type Godot.Engine not found");
		var corlib = module.TypeSystem.CoreLibrary;
		var actionOpen = new TypeReference("System", "Action`1", module, corlib);
		actionOpen.GenericParameters.Add(new GenericParameter(actionOpen));
		var actionInt = new GenericInstanceType(actionOpen);
		actionInt.GenericArguments.Add(module.TypeSystem.Int32);
		var invoke = new MethodReference("Invoke", module.TypeSystem.Void, actionInt) { HasThis = true };
		invoke.Parameters.Add(new ParameterDefinition(actionOpen.GenericParameters[0]));
		FieldDefinition Field(string name, TypeReference type)
		{
			var f = new FieldDefinition(name, FieldAttributes.Public | FieldAttributes.Static, type);
			engine.Fields.Add(f);
			return f;
		}
		var hook = Field("PortMaxFpsHook", actionInt);
		var requested = Field("PortRequestedMaxFps", module.TypeSystem.Int32);
		var hasRequest = Field("PortHasMaxFpsRequest", module.TypeSystem.Boolean);
		var setNative = CloneStatic(Method("Godot.Engine", "SetMaxFps"), "PortSetMaxFpsNative");
		var getNative = CloneStatic(Method("Godot.Engine", "GetMaxFps"), "PortGetMaxFpsNative");

		var set = Method("Godot.Engine", "SetMaxFps");
		set.Body = new MethodBody(set);
		var il = set.Body.GetILProcessor();
		var native = il.Create(OpCodes.Ldarg_0);
		il.Emit(OpCodes.Ldarg_0);
		il.Emit(OpCodes.Stsfld, requested);
		il.Emit(OpCodes.Ldc_I4_1);
		il.Emit(OpCodes.Stsfld, hasRequest);
		il.Emit(OpCodes.Ldsfld, hook);
		il.Emit(OpCodes.Brfalse, native);
		il.Emit(OpCodes.Ldsfld, hook);
		il.Emit(OpCodes.Ldarg_0);
		il.Emit(OpCodes.Callvirt, invoke);
		il.Emit(OpCodes.Ret);
		il.Append(native);
		il.Emit(OpCodes.Call, setNative);
		il.Emit(OpCodes.Ret);
		patched++;
		Console.WriteLine("Engine.SetMaxFps records the request and calls PortMaxFpsHook");

		var get = Method("Godot.Engine", "GetMaxFps");
		get.Body = new MethodBody(get);
		il = get.Body.GetILProcessor();
		var fromNative = il.Create(OpCodes.Call, getNative);
		il.Emit(OpCodes.Ldsfld, hasRequest);
		il.Emit(OpCodes.Brfalse, fromNative);
		il.Emit(OpCodes.Ldsfld, requested);
		il.Emit(OpCodes.Ret);
		il.Append(fromNative);
		il.Emit(OpCodes.Ret);
		patched++;
		Console.WriteLine("Engine.GetMaxFps returns the game's requested limit");
	}
}
else if (asm.Name.Name == "sts2")
{
	// Steam Cloud saves without Steamworks: hooks that the port's own assembly (sts2native) fills in.
	var runtime = module.GetTypeReferences().First(t => t.FullName == "System.Threading.Tasks.Task").Scope;
	var taskRef = new TypeReference("System.Threading.Tasks", "Task", module, runtime);
	var saveManager = module.GetType("MegaCrit.Sts2.Core.Saves.SaveManager");

	(GenericInstanceType type, MethodReference invoke) Func(TypeReference result)
	{
		var open = new TypeReference("System", "Func`1", module, runtime);
		open.GenericParameters.Add(new GenericParameter(open));
		var closed = new GenericInstanceType(open);
		closed.GenericArguments.Add(result);
		return (closed, new MethodReference("Invoke", open.GenericParameters[0], closed) { HasThis = true });
	}

	var hooks = new TypeDefinition("MegaCrit.Sts2.Port", "PortHooks",
		TypeAttributes.Public | TypeAttributes.Abstract | TypeAttributes.Sealed | TypeAttributes.BeforeFieldInit, module.TypeSystem.Object);
	module.Types.Add(hooks);
	FieldDefinition Field(string name, TypeReference type)
	{
		var f = new FieldDefinition(name, FieldAttributes.Public | FieldAttributes.Static, type);
		hooks.Fields.Add(f);
		return f;
	}
	var (funcSaveManager, invokeSaveManager) = Func(saveManager);
	var (funcTask, invokeTask) = Func(taskRef);
	var constructHook = Field("ConstructSaveManager", funcSaveManager);
	var cloudSyncHook = Field("CloudSync", funcTask);
	var steamId = Field("SteamId", module.TypeSystem.UInt64);
	var personaName = Field("PersonaName", module.TypeSystem.String);

	// if (hook != null) return hook();
	void Prefix(MethodDefinition m, FieldDefinition hook, MethodReference invoke)
	{
		var il = m.Body.GetILProcessor();
		var first = m.Body.Instructions[0];
		il.InsertBefore(first, il.Create(OpCodes.Ldsfld, hook));
		il.InsertBefore(first, il.Create(OpCodes.Brfalse, first));
		il.InsertBefore(first, il.Create(OpCodes.Ldsfld, hook));
		il.InsertBefore(first, il.Create(OpCodes.Callvirt, invoke));
		il.InsertBefore(first, il.Create(OpCodes.Ret));
		patched++;
		Console.WriteLine($"hooked {m.FullName}");
	}
	Prefix(Method("MegaCrit.Sts2.Core.Saves.SaveManager", "ConstructDefault"), constructHook, invokeSaveManager);
	Prefix(Method("MegaCrit.Sts2.Core.Nodes.NGame", "DoCloudSync"), cloudSyncHook, invokeTask);

	// GameStartup only waits for the cloud sync while Steamworks is initialized; always wait instead.
	var ngame = module.GetType("MegaCrit.Sts2.Core.Nodes.NGame");
	var startup = ngame.NestedTypes.Single(t => t.Name.StartsWith("<GameStartup>d__"));
	int replaced = 0;
	foreach (var ins in startup.Methods.Single(m => m.Name == "MoveNext").Body.Instructions)
		if (ins.OpCode == OpCodes.Call && ins.Operand is MethodReference mr && mr.Name == "get_Initialized" && mr.DeclaringType.Name == "SteamInitializer")
		{
			ins.OpCode = OpCodes.Ldc_I4_1;
			ins.Operand = null;
			replaced++;
		}
	if (replaced != 1) throw new Exception($"expected 1 SteamInitializer.Initialized check in GameStartup, found {replaced}");
	patched++;
	Console.WriteLine("GameStartup waits for cloud sync without Steamworks");

	// PrewarmJit reflects over every packet type to RuntimeHelpers.PrepareMethod them: pointless (and ~30 ms at
	// startup) when the whole game is compiled ahead of time.
	Stub("MegaCrit.Sts2.Core.Helpers.OneTimeInitialization", "PrewarmJit", il => il.Emit(OpCodes.Ret));

	// Saves made on PC are tagged with the Steam platform; answer those lookups without Steamworks.
	Stub("MegaCrit.Sts2.Core.Platform.Steam.SteamPlatformUtilStrategy", "GetLocalPlayerId", il =>
	{
		il.Emit(OpCodes.Ldsfld, steamId);
		il.Emit(OpCodes.Ret);
	});
	Stub("MegaCrit.Sts2.Core.Platform.Steam.SteamPlatformUtilStrategy", "GetPlayerName", il =>
	{
		var other = il.Create(OpCodes.Ldarga_S, il.Body.Method.Parameters[0]);
		var ret = il.Create(OpCodes.Ret);
		il.Emit(OpCodes.Ldarg_1);
		il.Emit(OpCodes.Ldsfld, steamId);
		il.Emit(OpCodes.Bne_Un, other);
		il.Emit(OpCodes.Ldsfld, personaName);
		il.Emit(OpCodes.Dup);
		il.Emit(OpCodes.Brtrue, ret);
		il.Emit(OpCodes.Pop);
		il.Append(other);
		il.Emit(OpCodes.Call, new MethodReference("ToString", module.TypeSystem.String, module.TypeSystem.UInt64) { HasThis = true });
		il.Append(ret);
	});

	// ---- multiplayer over ENet (direct IP) without Steamworks; see aot/Port/PortMultiplayer.cs ----
	GenericInstanceType Generic(string name, params TypeReference[] args)
	{
		var open = new TypeReference("System", $"{name}`{args.Length}", module, runtime);
		foreach (var _ in args) open.GenericParameters.Add(new GenericParameter(open));
		var closed = new GenericInstanceType(open);
		foreach (var a in args) closed.GenericArguments.Add(a);
		return closed;
	}
	MethodReference Invoke(GenericInstanceType closed, bool returnsValue)
	{
		var gp = closed.ElementType.GenericParameters;
		var r = new MethodReference("Invoke", returnsValue ? gp[gp.Count - 1] : module.TypeSystem.Void, closed) { HasThis = true };
		for (int i = 0; i < gp.Count - (returnsValue ? 1 : 0); i++) r.Parameters.Add(new ParameterDefinition(gp[i]));
		return r;
	}
	// Inserts "if (hook != null) { <body> }" at the start of m; body ends in ret unless it falls through.
	void Guard(MethodDefinition m, FieldDefinition hook, params Instruction[] body)
	{
		var il = m.Body.GetILProcessor();
		var first = m.Body.Instructions[0];
		il.InsertBefore(first, il.Create(OpCodes.Ldsfld, hook));
		il.InsertBefore(first, il.Create(OpCodes.Brfalse, first));
		foreach (var ins in body) il.InsertBefore(first, ins);
		patched++;
		Console.WriteLine($"hooked {m.FullName}");
	}
	var joinScreen = module.GetType("MegaCrit.Sts2.Core.Nodes.Screens.MainMenu.NJoinFriendScreen");
	var hostService = module.GetType("MegaCrit.Sts2.Core.Multiplayer.NetHostGameService");
	const string nullStrategy = "MegaCrit.Sts2.Core.Platform.Null.NullPlatformUtilStrategy";

	// Join screen without Steam: the game connects straight to 127.0.0.1; ask for the host's IP instead.
	var funcJoin = Generic("Func", joinScreen, taskRef);
	var mpJoin = Field("MpJoin", funcJoin);
	Guard(Method(joinScreen.FullName, "FastMpJoin"), mpJoin,
		Instruction.Create(OpCodes.Ldsfld, mpJoin), Instruction.Create(OpCodes.Ldarg_0),
		Instruction.Create(OpCodes.Callvirt, Invoke(funcJoin, true)), Instruction.Create(OpCodes.Ret));

	// Tell the port when this device starts hosting over ENet (shows the address to join).
	var actionHost = Generic("Action", hostService);
	var onHost = Field("OnENetHost", actionHost);
	Guard(Method(hostService.FullName, "StartENetHost"), onHost,
		Instruction.Create(OpCodes.Ldsfld, onHost), Instruction.Create(OpCodes.Ldarg_0),
		Instruction.Create(OpCodes.Callvirt, Invoke(actionHost, false)));

	// Host and Load first ask how others join (nearby and on the Wi-Fi, or with an invite code): "if (hook(this,
	// button)) return;". Public, so the port can run them once the player has chosen.
	{
		var submenu = module.GetType("MegaCrit.Sts2.Core.Nodes.Screens.MainMenu.NMultiplayerSubmenu")
			?? throw new Exception("NMultiplayerSubmenu not found");
		foreach (var (name, field) in new[] { ("OnHostPressed", "MpHostPressed"), ("StartLoad", "MpLoadPressed") })
		{
			var m = Method(submenu.FullName, name);
			var func = Generic("Func", submenu, m.Parameters[0].ParameterType, module.TypeSystem.Boolean);
			var hook = Field(field, func);
			var first = m.Body.Instructions[0];
			Guard(m, hook,
				Instruction.Create(OpCodes.Ldsfld, hook), Instruction.Create(OpCodes.Ldarg_0), Instruction.Create(OpCodes.Ldarg_1),
				Instruction.Create(OpCodes.Callvirt, Invoke(func, true)), Instruction.Create(OpCodes.Brfalse, first),
				Instruction.Create(OpCodes.Ret));
			m.IsPrivate = false;
			m.IsPublic = true;
		}
	}

	// Remember the client service each join creates, so the port can keep the app running while it's connected
	// (src/native/Port/PortKeepAlive.cs). The game's connection interface changed shape in v0.113.0, so wrapping it
	// would need a different port build per game version.
	{
		var clientService = module.GetType("MegaCrit.Sts2.Core.Multiplayer.NetClientGameService")
			?? throw new Exception("NetClientGameService not found");
		var latest = Field("ClientService", clientService);
		var ctors = clientService.Methods.Where(m => m.IsConstructor && !m.IsStatic && m.HasBody).ToList();
		if (ctors.Count == 0) throw new Exception("NetClientGameService has no constructor");
		foreach (var ctor in ctors)
		{
			var il = ctor.Body.GetILProcessor();
			foreach (var ret in ctor.Body.Instructions.Where(i => i.OpCode == OpCodes.Ret).ToList())
			{
				// Branches to the ret now land on the store.
				var load = il.Create(OpCodes.Ldarg_0);
				il.InsertBefore(ret, load);
				il.InsertBefore(ret, il.Create(OpCodes.Stsfld, latest));
				foreach (var i in ctor.Body.Instructions.Where(i => i.Operand == ret && i != load)) i.Operand = load;
			}
		}
		patched++;
		Console.WriteLine($"NetClientGameService constructors set PortHooks.ClientService ({ctors.Count})");
	}

	// The null platform reports player id 1 (the ENet host's id) even on a joining client, so the end-of-run
	// progress update would credit the host's character to this device. Report the id this device joined with.
	var nullPlayerId = Field("NullPlayerId", module.TypeSystem.UInt64);
	Guard(Method(nullStrategy, "GetLocalPlayerId"), nullPlayerId,
		Instruction.Create(OpCodes.Ldsfld, nullPlayerId), Instruction.Create(OpCodes.Ret));
	var funcName = Generic("Func", module.TypeSystem.UInt64, module.TypeSystem.String);
	var nullName = Field("NullPlayerName", funcName);
	Guard(Method(nullStrategy, "GetPlayerName"), nullName,
		Instruction.Create(OpCodes.Ldsfld, nullName), Instruction.Create(OpCodes.Ldarg_1),
		Instruction.Create(OpCodes.Callvirt, Invoke(funcName, true)), Instruction.Create(OpCodes.Ret));

	// Save paths (user://default/<id>) keep the fixed null-platform id 1 whatever the multiplayer id is.
	var getLocal = module.GetType("MegaCrit.Sts2.Core.Platform.PlatformUtil").Methods.Single(m => m.Name == "GetLocalPlayerId");
	var savePathId = new MethodDefinition("SavePathPlayerId", MethodAttributes.Public | MethodAttributes.Static | MethodAttributes.HideBySig, module.TypeSystem.UInt64);
	savePathId.Parameters.Add(new ParameterDefinition("platform", ParameterAttributes.None, getLocal.Parameters[0].ParameterType));
	hooks.Methods.Add(savePathId);
	{
		var il = savePathId.Body.GetILProcessor();
		var steam = il.Create(OpCodes.Ldarg_0);
		il.Emit(OpCodes.Ldarg_0);
		il.Emit(OpCodes.Brtrue, steam); // PlatformType.None == 0
		il.Emit(OpCodes.Ldc_I4_1);
		il.Emit(OpCodes.Conv_U8);
		il.Emit(OpCodes.Ret);
		il.Append(steam);
		il.Emit(OpCodes.Call, getLocal);
		il.Emit(OpCodes.Ret);
	}
	int pathCalls = 0;
	foreach (var m in module.GetType("MegaCrit.Sts2.Core.Saves.UserDataPathProvider").Methods.Where(m => m.HasBody))
		foreach (var ins in m.Body.Instructions)
			if (ins.OpCode == OpCodes.Call && ins.Operand is MethodReference r && r.Name == "GetLocalPlayerId" && r.DeclaringType.Name == "PlatformUtil")
			{
				ins.Operand = savePathId;
				pathCalls++;
			}
	if (pathCalls != 3) throw new Exception($"expected 3 GetLocalPlayerId calls in UserDataPathProvider, found {pathCalls}");
	patched++;
	Console.WriteLine("save paths pinned to null-platform id 1");

	// Inserts seq after anchor, in order. Short branches that now span too far are widened.
	void InsertAfter(MethodDefinition m, Instruction anchor, params Instruction[] seq)
	{
		m.Body.SimplifyMacros();
		var il = m.Body.GetILProcessor();
		foreach (var ins in seq) { il.InsertAfter(anchor, ins); anchor = ins; }
		m.Body.OptimizeMacros();
	}

	// ---- up to 6 players when an iOS device hosts (src/native/Port/PortMultiplayer.cs) ----
	// Hosting passes a literal 4 for the ENet peer count and the lobby size; route those through
	// PortHooks.LanMaxPlayers(4), which returns PortHooks.LanPlayerCap once the port sets it.
	var lanCap = Field("LanPlayerCap", module.TypeSystem.Int32);
	var lanMax = new MethodDefinition("LanMaxPlayers", MethodAttributes.Public | MethodAttributes.Static | MethodAttributes.HideBySig, module.TypeSystem.Int32);
	lanMax.Parameters.Add(new ParameterDefinition("vanilla", ParameterAttributes.None, module.TypeSystem.Int32));
	hooks.Methods.Add(lanMax);
	{
		var il = lanMax.Body.GetILProcessor();
		var vanilla = il.Create(OpCodes.Ldarg_0);
		il.Emit(OpCodes.Ldsfld, lanCap);
		il.Emit(OpCodes.Ldc_I4_0);
		il.Emit(OpCodes.Ble, vanilla);
		il.Emit(OpCodes.Ldsfld, lanCap);
		il.Emit(OpCodes.Ret);
		il.Append(vanilla);
		il.Emit(OpCodes.Ret);
		var sites = new List<(MethodDefinition Method, Instruction Four)>();
		var siteNames = new List<string>();
		foreach (var t in module.GetTypes().Where(t => !t.FullName.Contains("NMultiplayerTest")))
			foreach (var m in t.Methods.Where(m => m.HasBody))
			{
				var list = m.Body.Instructions;
				for (int i = 0; i + 1 < list.Count; i++)
					if (list[i].OpCode == OpCodes.Ldc_I4_4 && list[i + 1].Operand is MethodReference r
						&& (r.Name is "StartENetHost" or "InitializeMultiplayerAsHost" || (r.Name == ".ctor" && r.DeclaringType.Name == "StartRunLobby"))
						&& r.Parameters.Count > 0 && r.Parameters[^1].ParameterType.MetadataType == MetadataType.Int32)
					{
						sites.Add((m, list[i]));
						siteNames.Add($"{t.Name}.{m.Name} -> {r.DeclaringType.Name}.{r.Name}");
					}
			}
		foreach (var (m, four) in sites)
			InsertAfter(m, four, Instruction.Create(OpCodes.Call, lanMax));
		int caps = sites.Count;
		// StartENetHost x2 (new / loaded run), the Daily lobby x1, and InitializeMultiplayerAsHost per host screen:
		// standard and custom runs (v0.107.1), plus Blitz and Dread (v0.113.0).
		int Count(string target) => siteNames.Count(n => n.EndsWith(" -> " + target) || n.EndsWith("." + target));
		int hostScreens = Count("InitializeMultiplayerAsHost");
		if (Count("NetHostGameService.StartENetHost") != 2 || Count("StartRunLobby..ctor") != 1 || (hostScreens != 2 && hostScreens != 4)
				|| caps != 3 + hostScreens)
			throw new Exception($"unexpected hard-coded host player caps ({caps}): " + string.Join("; ", siteNames));
		patched++;
		Console.WriteLine($"host player caps go through PortHooks.LanMaxPlayers ({caps} sites)");
	}


	// The lobby player's slotId goes over the wire in 2 bits (slots 0-3). Slots 4-5 carry their high bit in an unused
	// bit of an ascension level (0-20) that's sent next to it, so slots 0-3 serialize exactly as before and a PC (which
	// can host for iOS but never join an iOS host) sees the same bytes. v0.107.1: LobbyPlayer, 32-bit
	// maxMultiplayerAscensionUnlocked, bit 24. v0.113.0: StartRunLobbyPlayer, 8-bit maxStandardAscension, bit 7.
	{
		var lp = module.GetType("MegaCrit.Sts2.Core.Entities.Multiplayer.LobbyPlayer")
			?? module.GetType("MegaCrit.Sts2.Core.Entities.Multiplayer.StartRunLobbyPlayer")
			?? throw new Exception("lobby player type not found");
		var slot = lp.Fields.Single(f => f.Name == "slotId");
		var asc = lp.Fields.SingleOrDefault(f => f.Name == "maxMultiplayerAscensionUnlocked")
			?? lp.Fields.Single(f => f.Name == "maxStandardAscension");
		bool wide = asc.Name == "maxMultiplayerAscensionUnlocked";
		sbyte bit = wide ? (sbyte)24 : (sbyte)7;
		int mask = wide ? 0xFFFFFF : 0x7F;
		Instruction Load(MethodDefinition m, FieldDefinition f) =>
			m.Body.Instructions.Single(i => i.OpCode == OpCodes.Ldfld && i.Operand == f);

		var ser = Method(lp.FullName, "Serialize");
		// writer.WriteInt(slotId & 3, 2)
		InsertAfter(ser, Load(ser, slot), Instruction.Create(OpCodes.Ldc_I4_3), Instruction.Create(OpCodes.And));
		// writer.WriteInt(ascension | (slotId >> 2) << bit)
		InsertAfter(ser, Load(ser, asc),
			Instruction.Create(OpCodes.Ldarg_0), Instruction.Create(OpCodes.Ldfld, slot),
			Instruction.Create(OpCodes.Ldc_I4_2), Instruction.Create(OpCodes.Shr),
			Instruction.Create(OpCodes.Ldc_I4_S, bit), Instruction.Create(OpCodes.Shl),
			Instruction.Create(OpCodes.Or));

		var de = Method(lp.FullName, "Deserialize");
		var storeAsc = de.Body.Instructions.Single(i => i.OpCode == OpCodes.Stfld && i.Operand == asc);
		InsertAfter(de, storeAsc,
			// slotId |= (ascension >> bit) << 2
			Instruction.Create(OpCodes.Ldarg_0),
			Instruction.Create(OpCodes.Ldarg_0), Instruction.Create(OpCodes.Ldfld, slot),
			Instruction.Create(OpCodes.Ldarg_0), Instruction.Create(OpCodes.Ldfld, asc),
			Instruction.Create(OpCodes.Ldc_I4_S, bit), Instruction.Create(OpCodes.Shr),
			Instruction.Create(OpCodes.Ldc_I4_2), Instruction.Create(OpCodes.Shl),
			Instruction.Create(OpCodes.Or), Instruction.Create(OpCodes.Stfld, slot),
			// ascension &= mask
			Instruction.Create(OpCodes.Ldarg_0),
			Instruction.Create(OpCodes.Ldarg_0), Instruction.Create(OpCodes.Ldfld, asc),
			Instruction.Create(OpCodes.Ldc_I4, mask), Instruction.Create(OpCodes.And),
			Instruction.Create(OpCodes.Stfld, asc));
		patched += 2;
		Console.WriteLine($"{lp.Name} slots 4-5 carry their high bit in bit {bit} of {asc.Name}");
	}

	// The rest site scene has four character seats and the treasure room four multiplayer relic holders (one relic
	// per player); both index them by player slot. Let the port add seats/holders for players 5 and 6.
	{
		var room = module.GetType("MegaCrit.Sts2.Core.Nodes.Rooms.NRestSiteRoom");
		var seats = room.Fields.Single(f => f.Name == "_characterContainers");
		var ready = Method(room.FullName, "_Ready");
		var last = ready.Body.Instructions.Single(i => i.OpCode == OpCodes.Ldstr && (string)i.Operand == "BgContainer/Character_4");
		while (!(last.OpCode == OpCodes.Callvirt && last.Operand is MethodReference r && r.Name == "Add")) last = last.Next;
		var act = Generic("Action", room, seats.FieldType);
		var hook = Field("RestSiteSeats", act);
		InsertAfter(ready, last,
			Instruction.Create(OpCodes.Ldsfld, hook), Instruction.Create(OpCodes.Brfalse, last.Next),
			Instruction.Create(OpCodes.Ldsfld, hook), Instruction.Create(OpCodes.Ldarg_0),
			Instruction.Create(OpCodes.Ldarg_0), Instruction.Create(OpCodes.Ldfld, seats),
			Instruction.Create(OpCodes.Callvirt, Invoke(act, false)));
		patched++;
		Console.WriteLine("NRestSiteRoom._Ready calls PortHooks.RestSiteSeats after its four seats");
	}
	{
		var coll = module.GetType("MegaCrit.Sts2.Core.Nodes.Screens.TreasureRoomRelic.NTreasureRoomRelicCollection");
		var ready = Method(coll.FullName, "_Ready");
		var set = ready.Body.Instructions.SingleOrDefault(i => i.OpCode == OpCodes.Call && i.Operand is MethodReference r && r.Name == "set_SingleplayerRelicHolder");
		if (set == null && coll.Fields.Any(f => f.Name == "_holderLayouts"))
		{
			// v0.113.0: the scene has a layout per relic count, up to 6, so players 5 and 6 need nothing extra.
			// The hook stays (unused) because src/native sets it.
			Field("TreasureRelicHolders", Generic("Action", coll.Fields.Single(f => f.Name == "_relicContainer").FieldType));
			Console.WriteLine("treasure room has its own layouts for up to 6 relics");
			goto treasureDone;
		}
		if (set == null) throw new Exception("NTreasureRoomRelicCollection._Ready changed");
		// Next: "ldloc.0; GetChildren()" collects the multiplayer holders from the "Container" node held in local 0.
		if (set.Next.OpCode != OpCodes.Ldloc_0) throw new Exception("NTreasureRoomRelicCollection._Ready changed");
		var act = Generic("Action", ready.Body.Variables[0].VariableType);
		var hook = Field("TreasureRelicHolders", act);
		InsertAfter(ready, set,
			Instruction.Create(OpCodes.Ldsfld, hook), Instruction.Create(OpCodes.Brfalse, set.Next),
			Instruction.Create(OpCodes.Ldsfld, hook), Instruction.Create(OpCodes.Ldloc_0),
			Instruction.Create(OpCodes.Callvirt, Invoke(act, false)));
		patched++;
		Console.WriteLine("NTreasureRoomRelicCollection._Ready calls PortHooks.TreasureRelicHolders before collecting holders");
	}
	treasureDone:

	// Network error popups offer only "Report bug" (a feedback form sent to Mega Crit) for errors like timeouts,
	// with no way to just close them. An unofficial port shouldn't file reports: always show OK.
	{
		var ready = Method("MegaCrit.Sts2.Core.Nodes.CommonUi.NErrorPopup", "_Ready");
		var load = ready.Body.Instructions.Single(i => i.OpCode == OpCodes.Ldfld && i.Operand is FieldReference f && f.Name == "_showReportBugButton");
		var il = ready.Body.GetILProcessor();
		il.InsertAfter(load, il.Create(OpCodes.Ldc_I4_0));
		load.OpCode = OpCodes.Pop;
		load.Operand = null;
		patched++;
		Console.WriteLine("error popups always offer OK");
	}

	// The game reads its version (release_info.json, compared when joining multiplayer) from next to the executable,
	// which an iOS app bundle doesn't have: read the copy build.sh puts in the pck instead. Without it the version is
	// "UNKNOWN" and joining a PC host fails with a version mismatch.
	{
		const string rim = "MegaCrit.Sts2.Core.Debug.ReleaseInfoManager";
		Stub(rim, "GetPossibleReleaseInfoPaths", il =>
		{
			il.Emit(OpCodes.Ldc_I4_1);
			il.Emit(OpCodes.Newarr, module.TypeSystem.String);
			il.Emit(OpCodes.Dup);
			il.Emit(OpCodes.Ldc_I4_0);
			il.Emit(OpCodes.Ldstr, "res://port/release_info.json");
			il.Emit(OpCodes.Stelem_Ref);
			il.Emit(OpCodes.Ret);
		});
		// LoadConfig globalizes each path to an OS path; a res:// path must stay as is to be read from the pck.
		var load = Method(rim, "LoadConfig");
		var globalize = load.Body.Instructions.Single(i => i.OpCode == OpCodes.Call && i.Operand is MethodReference r && r.Name == "GlobalizePath");
		globalize.OpCode = OpCodes.Nop;
		globalize.Operand = null;
		patched++;
		Console.WriteLine("release_info.json read from res://port");
	}

	// FPS limit: the game defaults to 60 (new settings and Settings > Reset graphics). iPhones with ProMotion show
	// 120 Hz, so default to 120 there; a 60 Hz display still runs at 60 (src/native/Port/PortFrameRate.cs).
	{
		int defaults = 0;
		var owners = new[] { "MegaCrit.Sts2.Core.Saves.SettingsSave", "MegaCrit.Sts2.Core.Nodes.Screens.Settings.NResetGraphicsButton" };
		foreach (var t in module.GetTypes().Where(t => owners.Any(o => t.FullName == o || t.FullName.StartsWith(o + "/"))))
			foreach (var m in t.Methods.Where(m => m.HasBody))
				foreach (var ins in m.Body.Instructions)
					if (ins.OpCode == OpCodes.Ldc_I4_S && (sbyte)ins.Operand == 60 && ins.Next?.Operand is MemberReference target
						&& target.Name is "set_FpsLimit" or "<FpsLimit>k__BackingField")
					{
						ins.Operand = (sbyte)120;
						defaults++;
					}
		if (defaults != 2) throw new Exception($"expected 2 FpsLimit = 60 defaults, found {defaults}");
		patched++;
		Console.WriteLine("default FPS limit 120");
	}

	// ---- port content (src/native/Port/PerfectedDeck.cs) ----
	// Called once models and localization are loaded, before any save is read: register extra models there.
	var actionOpen0 = new TypeReference("System", "Action", module, runtime);
	var afterEssential = Field("AfterEssentialInit", actionOpen0);
	{
		var m = Method("MegaCrit.Sts2.Core.Helpers.OneTimeInitialization", "ExecuteEssential");
		var invoke = new MethodReference("Invoke", module.TypeSystem.Void, actionOpen0) { HasThis = true };
		var il = m.Body.GetILProcessor();
		// Turn every "ret" into "if (hook != null) hook(); ret" (the ret stays the branch target).
		foreach (var ret in m.Body.Instructions.Where(i => i.OpCode == OpCodes.Ret).ToList())
		{
			var newRet = il.Create(OpCodes.Ret);
			ret.OpCode = OpCodes.Ldsfld;
			ret.Operand = afterEssential;
			il.InsertAfter(ret, newRet);
			il.InsertBefore(newRet, il.Create(OpCodes.Brfalse, newRet));
			il.InsertBefore(newRet, il.Create(OpCodes.Ldsfld, afterEssential));
			il.InsertBefore(newRet, il.Create(OpCodes.Callvirt, invoke));
		}
		patched++;
		Console.WriteLine("OneTimeInitialization.ExecuteEssential calls PortHooks.AfterEssentialInit");
	}

	// The custom run screen lists ModelDb.GoodModifiers then BadModifiers (the Daily run draws from the same lists, so
	// those stay untouched): let the port append to the list this screen shows (applied in list order).
	{
		var modelDb = module.GetType("MegaCrit.Sts2.Core.Models.ModelDb");
		var badGetter = modelDb.Methods.Single(m => m.Name == "get_BadModifiers");
		var listType = badGetter.ReturnType;
		var funcList = Generic("Func", listType, listType);
		var listHook = Field("CustomRunModifiers", funcList);
		var wrapper = new MethodDefinition("CustomRunBadModifiers", MethodAttributes.Public | MethodAttributes.Static | MethodAttributes.HideBySig, listType);
		hooks.Methods.Add(wrapper);
		var il = wrapper.Body.GetILProcessor();
		var plain = il.Create(OpCodes.Call, badGetter);
		il.Emit(OpCodes.Ldsfld, listHook);
		il.Emit(OpCodes.Brfalse, plain);
		il.Emit(OpCodes.Ldsfld, listHook);
		il.Emit(OpCodes.Call, badGetter);
		il.Emit(OpCodes.Callvirt, Invoke(funcList, true));
		il.Emit(OpCodes.Ret);
		il.Append(plain);
		il.Emit(OpCodes.Ret);
		var listUi = module.GetType("MegaCrit.Sts2.Core.Nodes.Screens.MainMenu.NCustomRunModifiersList");
		int calls = 0;
		foreach (var t in new[] { listUi }.Concat(listUi.NestedTypes))
			foreach (var m in t.Methods.Where(m => m.HasBody))
				foreach (var ins in m.Body.Instructions)
					if (ins.OpCode == OpCodes.Call && ins.Operand is MethodReference r && r.Name == "get_BadModifiers" && r.DeclaringType.Name == "ModelDb")
					{
						ins.Operand = wrapper;
						calls++;
					}
		if (calls == 0) throw new Exception("NCustomRunModifiersList no longer reads ModelDb.BadModifiers");
		patched++;
		Console.WriteLine($"custom run modifier list goes through PortHooks.CustomRunModifiers ({calls} call sites)");

		// Lets the port hide its modifiers when the screen is used for multiplayer (other players wouldn't know them).
		var init = listUi.Methods.Single(m => m.Name == "Initialize" && m.Parameters.Count == 1);
		var actionInit = Generic("Action", listUi, init.Parameters[0].ParameterType);
		var initHook = Field("CustomRunModifiersInitialize", actionInit);
		Guard(init, initHook,
			Instruction.Create(OpCodes.Ldsfld, initHook), Instruction.Create(OpCodes.Ldarg_0), Instruction.Create(OpCodes.Ldarg_1),
			Instruction.Create(OpCodes.Callvirt, Invoke(actionInit, false)));
	}
}
else
{
	throw new Exception("unknown assembly " + asm.Name.Name);
}

asm.Write(args[1]);
Console.WriteLine($"{patched} patches -> {args[1]}");
// Game API generation for src/native (build.sh passes it as a compile-time symbol): v0.113.0 renamed the lobby
// player type and moved the profile save path into a method.
string api = module.GetType("MegaCrit.Sts2.Core.Entities.Multiplayer.StartRunLobbyPlayer") != null ? "STS2_V0113" : "STS2_V0107";
File.WriteAllText(Path.Combine(Path.GetDirectoryName(Path.GetFullPath(args[1]))!, "game-api.txt"), api);
Console.WriteLine("game API: " + api);
return 0;
