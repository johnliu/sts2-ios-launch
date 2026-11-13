// Keeps the C entry points through the app's dead stripping: only PortTailcat.cs uses them, by name at run time.
#include "_cgo_export.h"

__attribute__((used)) static void *const keep[] = {
	port_tailcat_status, port_tailcat_host, port_tailcat_address,
	port_tailcat_join, port_tailcat_join_state, port_tailcat_leave,
};
