// ---- Appended to the exported Xcode project's dummy.cpp by build.sh ----
// UIScene support. Apps built with the iOS 27 SDK must use scenes (else UIKit stops them at launch), and only
// scene-based apps built with the iOS 27.1 SDK fill both screens of an iPhone Duo and resize when it opens or
// closes; older ones get a fixed iPhone-sized window. Godot 4.5 creates its window without a scene in
// application:didFinishLaunchingWithOptions:, so this scene delegate (named in Info.plist's
// UIApplicationSceneManifest by build.sh) moves that window onto the scene, keeps it the scene's size, and passes
// the scene's lifecycle on to Godot's app delegate, which UIKit no longer calls for it.
// Written against the Objective-C runtime because this file is compiled as C++.
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <dispatch/dispatch.h>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <ctime>
#include <objc/message.h>
#include <objc/runtime.h>

namespace port_scene {

static id send(id obj, const char *sel) {
	return ((id(*)(id, SEL))objc_msgSend)(obj, sel_registerName(sel));
}

static void send_obj(id obj, const char *sel, id arg) {
	((void (*)(id, SEL, id))objc_msgSend)(obj, sel_registerName(sel), arg);
}

static id app() {
	return send((id)objc_getClass("UIApplication"), "sharedApplication");
}

static const void *window_key = &window_key;

static id get_window(id self, SEL) {
	return objc_getAssociatedObject(self, window_key);
}

static void set_window(id self, SEL, id window) {
	objc_setAssociatedObject(self, window_key, window, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void fit_window(id window, id scene) {
	id space = send(scene, "coordinateSpace");
	CGRect bounds = ((CGRect(*)(id, SEL))objc_msgSend)(space, sel_registerName("bounds"));
	CGRect frame = ((CGRect(*)(id, SEL))objc_msgSend)(window, sel_registerName("frame"));
	if (!CGRectEqualToRect(frame, bounds)) {
		((void (*)(id, SEL, CGRect))objc_msgSend)(window, sel_registerName("setFrame:"), bounds);
	}
}

// Landscape only. Info.plist allows only landscape, which keeps the game landscape on iPhones and in every pose of the
// iPhone Duo Simulator (iOS 27.1 and 27.2). A real iPhone Duo (iOS 27.2) still turns it upright, in the background
// (folded and held upright in another app) and in front while folding or opening it: like an iPad, the Duo can ignore
// an app's orientation list. So on the Duo (a phone with a hinge, UIHingeInteraction) the game also uses iOS 26's
// orientation lock, prefersInterfaceOrientationLocked, added to Godot's view controller:
// - while the game is landscape it's locked, so holding the phone upright can't turn it;
// - folded, turning the phone to the other landscape side unlocks it until iOS has turned the game round. This only
//   follows the phone's own turn notification, once it has held for 0.4 s on the same screen: open, and for a moment
//   after folding or opening, the phone's reported orientation doesn't match the screen's, so open it stays locked;
// - whenever the game is upright anyway (folding can still start the outer screen upright), it unlocks, so turning the
//   phone sideways turns it back, and asks iOS to turn it to landscape (iOS 16's geometry request).
// Each change is recorded in a short list that PortPerf.cs prints to godot.log as "[PORT] orientation".
static id root_controller = nil;
static bool orientation_locked = false;
static long last_orientation = -1;
static bool saw_hinge = false;
static long hinge_status = 0; // UIHingeStatus: 0 unknown or none, 1 closed, 2 partly open, 3 open
static int landscape_requests = 0, flips = 0, upright_count = 0;
static uint64_t launch_ns = 0;
static const char *ios_lock = "not checked";
static char orientation_events[6][128];
static int orientation_event_count = 0;
static char orientation_status[900] = "no changes";

static BOOL responds(id obj, const char *sel) {
	return obj != nil && ((BOOL(*)(id, SEL, SEL))objc_msgSend)(obj, sel_registerName("respondsToSelector:"), sel_registerName(sel));
}

static const char *orientation_name(long orientation) {
	switch (orientation) {
		case 1: return "upright";
		case 2: return "upside down";
		case 3: return "landscape right";
		case 4: return "landscape left";
		default: return "unknown";
	}
}

static const char *hinge_name() {
	if (!saw_hinge) {
		return "no hinge";
	}
	switch (hinge_status) {
		case 1: return "folded";
		case 2: return "half open";
		case 3: return "open";
		default: return "hinge unknown";
	}
}

static id effective_geometry(id scene) {
	return responds(scene, "effectiveGeometry") ? send(scene, "effectiveGeometry") : nil;
}

static long interface_orientation(id scene) {
	id geometry = effective_geometry(scene);
	id source = geometry != nil ? geometry : scene;
	return source == nil ? 0 : ((long (*)(id, SEL))objc_msgSend)(source, sel_registerName("interfaceOrientation"));
}

// UIDeviceOrientation: 1 upright, 2 upside down, 3/4 landscape, 5/6 flat. On an iPhone (and the folded Duo) the
// matching UIInterfaceOrientation has the same value for 3 and 4 (device landscape left = interface landscape right).
static long device_orientation() {
	return ((long (*)(id, SEL))objc_msgSend)(send((id)objc_getClass("UIDevice"), "currentDevice"), sel_registerName("orientation"));
}

static CGSize scene_size(id scene) {
	return scene == nil ? CGSizeZero : ((CGRect(*)(id, SEL))objc_msgSend)(send(scene, "coordinateSpace"), sel_registerName("bounds")).size;
}

static void update_status() {
	int n = orientation_event_count < 6 ? orientation_event_count : 6;
	int used = snprintf(orientation_status, sizeof(orientation_status), "%s, %s (iOS lock %s), %d flip(s), upright %d time(s), %d landscape request(s);",
			hinge_name(), orientation_locked ? "locked" : "unlocked", ios_lock, flips, upright_count, landscape_requests);
	for (int i = orientation_event_count - n; i < orientation_event_count && used > 0 && used < (int)sizeof(orientation_status); i++) {
		used += snprintf(orientation_status + used, sizeof(orientation_status) - used, " | %s", orientation_events[i % 6]);
	}
}

__attribute__((format(printf, 2, 3))) static void orientation_event(id scene, const char *format, ...) {
	char text[96];
	va_list args;
	va_start(args, format);
	vsnprintf(text, sizeof(text), format, args);
	va_end(args);
	char *event = orientation_events[orientation_event_count % 6];
	int used = snprintf(event, sizeof(orientation_events[0]), "%.0fs %s", (double)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - launch_ns) / 1e9, text);
	if (scene != nil && used > 0 && used < (int)sizeof(orientation_events[0])) {
		CGSize size = scene_size(scene);
		snprintf(event + used, sizeof(orientation_events[0]) - used, " (%.0fx%.0f, %s)", size.width, size.height, hinge_name());
	}
	orientation_event_count++;
	update_status();
}

static BOOL prefers_orientation_locked(id, SEL) {
	return orientation_locked;
}

static id no_child_controller(id, SEL) {
	return nil;
}

static void install_lock(id controller) {
	if (controller == nil || root_controller != nil) {
		return;
	}
	root_controller = controller;
	Class cls = object_getClass(controller);
	class_replaceMethod(cls, sel_registerName("prefersInterfaceOrientationLocked"), (IMP)prefers_orientation_locked, "B@:");
	class_replaceMethod(cls, sel_registerName("childViewControllerForInterfaceOrientationLock"), (IMP)no_child_controller, "@@:");
}

// A second after the lock changes, record whether iOS applied it (it updates the scene asynchronously).
static void check_ios_lock(void *scene) {
	id geometry = effective_geometry((id)scene);
	if (geometry == nil || !responds(geometry, "isInterfaceOrientationLocked")) {
		ios_lock = "unavailable";
	} else {
		bool on = ((BOOL(*)(id, SEL))objc_msgSend)(geometry, sel_registerName("isInterfaceOrientationLocked"));
		const char *was = ios_lock;
		ios_lock = on ? "on" : "off";
		if (on != orientation_locked && was != ios_lock) {
			orientation_event((id)scene, "iOS lock is %s but the game asked for %s", ios_lock, orientation_locked ? "on" : "off");
		}
	}
	update_status();
}

static void set_locked(id scene, bool locked) {
	if (orientation_locked == locked || root_controller == nil) {
		return;
	}
	orientation_locked = locked;
	if (responds(root_controller, "setNeedsUpdateOfPrefersInterfaceOrientationLocked")) {
		send(root_controller, "setNeedsUpdateOfPrefersInterfaceOrientationLocked");
	}
	if (!locked) {
		send(root_controller, "setNeedsUpdateOfSupportedInterfaceOrientations");
	}
	dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), (void *)scene, check_ios_lock);
}

static void request_landscape(id scene) {
	Class prefs_class = objc_getClass("UIWindowSceneGeometryPreferencesIOS");
	if (prefs_class == nil) {
		return;
	}
	const unsigned long landscape_mask = (1 << 3) | (1 << 4); // UIInterfaceOrientationMaskLandscape
	id prefs = ((id(*)(id, SEL, unsigned long))objc_msgSend)(send((id)prefs_class, "alloc"), sel_registerName("initWithInterfaceOrientations:"), landscape_mask);
	void (^refused)(id) = ^(id error) {
		id text = error == nil ? nil : send(error, "localizedDescription");
		const char *reason = text == nil ? "no reason" : ((const char *(*)(id, SEL))objc_msgSend)(text, sel_registerName("UTF8String"));
		orientation_event(nil, "iOS refused landscape: %.60s", reason);
	};
	((void (*)(id, SEL, id, void (^)(id)))objc_msgSend)(scene, sel_registerName("requestGeometryUpdateWithPreferences:errorHandler:"), prefs, refused);
	send(prefs, "release");
	landscape_requests++;
	update_status();
}

static void keep_landscape(id scene, const char *when, bool may_flip) {
	if (scene == nil) {
		return;
	}
	long orientation = interface_orientation(scene);
	bool was_locked = orientation_locked;
	if (orientation == 3 || orientation == 4) {
		const char *state = "no lock needed";
		if (saw_hinge) {
			long device = device_orientation();
			bool turned_round = may_flip && hinge_status == 1 && (device == 3 || device == 4) && device != orientation;
			if (turned_round && orientation_locked) {
				flips++;
			}
			set_locked(scene, !turned_round);
			state = turned_round ? "phone turned round, unlocked" : orientation_locked ? "locked" : "not locked yet";
		}
		if (orientation != last_orientation || orientation_locked != was_locked) {
			orientation_event(scene, "%s %s, %s", when, orientation_name(orientation), state);
		}
	} else if (orientation == 1 || orientation == 2) {
		set_locked(scene, false);
		if (orientation != last_orientation) {
			upright_count++;
			orientation_event(scene, "%s %s, asking for landscape", when, orientation_name(orientation));
		}
		request_landscape(scene);
	}
	last_orientation = orientation;
}

static id scene_of(id delegate) {
	id window = delegate == nil ? nil : get_window(delegate, nullptr);
	return window == nil ? nil : send(window, "windowScene");
}

static id hinge_delegate = nil;

static void watch_hinge(id delegate, id window) {
	Class interaction_class = objc_getClass("UIHingeInteraction");
	if (interaction_class == nil) {
		return;
	}
	hinge_delegate = delegate;
	void (^changed)(id, id) = ^(id, id update) {
		id hinge = update == nil ? nil : send(update, "hinge");
		long status = hinge == nil ? 0 : ((long (*)(id, SEL))objc_msgSend)(hinge, sel_registerName("status"));
		bool first = hinge != nil && !saw_hinge;
		saw_hinge = saw_hinge || hinge != nil;
		if (status != hinge_status || first) {
			hinge_status = status;
			id scene = scene_of(hinge_delegate);
			orientation_event(scene, "hinge: %s", hinge_name());
			keep_landscape(scene, "hinge moved:", false);
		}
	};
	id interaction = ((id(*)(id, SEL, void (^)(id, id)))objc_msgSend)(send((id)interaction_class, "alloc"), sel_registerName("initWithUpdateHandler:"), changed);
	send_obj(window, "addInteraction:", interaction);
	send(interaction, "release");
}

// Folded only (see above): unlock for a turn to the other landscape side once it has held for 0.4 s on the same screen.
static long turn_device = 0;
static CGSize turn_size = CGSizeZero;
static uintptr_t turn_count = 0;
static id turn_delegate = nil;

static void confirm_turn(void *context) {
	id scene = scene_of(turn_delegate);
	if (scene == nil || (uintptr_t)context != turn_count) {
		return;
	}
	bool settled = device_orientation() == turn_device && CGSizeEqualToSize(scene_size(scene), turn_size);
	keep_landscape(scene, "phone turned:", settled);
}

static void device_orientation_changed(id self, SEL, id) {
	turn_delegate = self;
	turn_device = device_orientation();
	turn_size = scene_size(scene_of(self));
	turn_count++;
	dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, 400 * NSEC_PER_MSEC), dispatch_get_main_queue(), (void *)turn_count, confirm_turn);
}

static void will_connect(id self, SEL, id scene, id, id) {
	id window = send(send(app(), "delegate"), "window");
	if (window == nil) {
		return;
	}
	send_obj(window, "setWindowScene:", scene);
	fit_window(window, scene);
	set_window(self, nullptr, window);
	send(window, "makeKeyAndVisible");
	install_lock(send(window, "rootViewController"));
	watch_hinge(self, window);
	send(send((id)objc_getClass("UIDevice"), "currentDevice"), "beginGeneratingDeviceOrientationNotifications");
	((void (*)(id, SEL, id, SEL, id, id))objc_msgSend)(send((id)objc_getClass("NSNotificationCenter"), "defaultCenter"),
			sel_registerName("addObserver:selector:name:object:"), self, sel_registerName("portDeviceOrientationChanged:"),
			(id)CFSTR("UIDeviceOrientationDidChangeNotification"), nil);
	keep_landscape(scene, "launched:", false);
}

static void did_update_coordinate_space(id self, SEL, id scene, id, long, id) {
	id window = get_window(self, nullptr);
	if (window != nil) {
		fit_window(window, scene);
	}
	keep_landscape(scene, "resized:", false);
}

// Scene lifecycle -> the app delegate methods Godot implements.
static void forward(const char *app_sel) {
	id delegate = send(app(), "delegate");
	SEL sel = sel_registerName(app_sel);
	if (((BOOL(*)(id, SEL, SEL))objc_msgSend)(delegate, sel_registerName("respondsToSelector:"), sel)) {
		((void (*)(id, SEL, id))objc_msgSend)(delegate, sel, app());
	}
}

static void did_become_active(id, SEL, id) { forward("applicationDidBecomeActive:"); }
static void will_resign_active(id, SEL, id) { forward("applicationWillResignActive:"); }
static void did_enter_background(id, SEL, id) { forward("applicationDidEnterBackground:"); }
static void will_enter_foreground(id, SEL, id scene) {
	keep_landscape(scene, "back in front:", false);
	forward("applicationWillEnterForeground:");
}

__attribute__((constructor)) static void register_scene_delegate() {
	launch_ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
	Class cls = objc_allocateClassPair(objc_getClass("UIResponder"), "PortSceneDelegate", 0);
	if (cls == nil) {
		return;
	}
	Protocol *proto = objc_getProtocol("UIWindowSceneDelegate");
	if (proto != nullptr) {
		class_addProtocol(cls, proto);
	}
	class_addMethod(cls, sel_registerName("window"), (IMP)get_window, "@@:");
	class_addMethod(cls, sel_registerName("setWindow:"), (IMP)set_window, "v@:@");
	class_addMethod(cls, sel_registerName("scene:willConnectToSession:options:"), (IMP)will_connect, "v@:@@@");
	class_addMethod(cls, sel_registerName("windowScene:didUpdateCoordinateSpace:interfaceOrientation:traitCollection:"),
			(IMP)did_update_coordinate_space, "v@:@@q@");
	class_addMethod(cls, sel_registerName("sceneDidBecomeActive:"), (IMP)did_become_active, "v@:@");
	class_addMethod(cls, sel_registerName("sceneWillResignActive:"), (IMP)will_resign_active, "v@:@");
	class_addMethod(cls, sel_registerName("sceneDidEnterBackground:"), (IMP)did_enter_background, "v@:@");
	class_addMethod(cls, sel_registerName("sceneWillEnterForeground:"), (IMP)will_enter_foreground, "v@:@");
	class_addMethod(cls, sel_registerName("portDeviceOrientationChanged:"), (IMP)device_orientation_changed, "v@:@");
	objc_registerClassPair(cls);
}

} // namespace port_scene

extern "C" __attribute__((visibility("default"))) __attribute__((used)) const char *port_orientation_status() {
	return port_scene::orientation_status;
}
