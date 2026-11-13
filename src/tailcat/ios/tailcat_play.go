// Linked into the iOS app by build.sh: multiplayer from anywhere by invite (../relay).
//
// C entry points (src/native/Port/PortTailcat.cs), called on the main thread.
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"sync"
	"time"
	"unsafe"

	"sts2port/tailcat/relay"
)

var (
	mu         sync.Mutex
	host       *relay.Host
	hostRun    int // which port_tailcat_host(1) the current host belongs to
	address    string
	hostStatus = "off"
	join       *relay.Join
	joinState  int32
	joinStatus = "off"
	returned   *C.char
)

func main() {}

// cString returns a C string that stays valid until the next call (main thread only).
func cString(s string) *C.char {
	C.free(unsafe.Pointer(returned))
	returned = C.CString(s)
	return returned
}

//export port_tailcat_status
func port_tailcat_status() *C.char {
	mu.Lock()
	defer mu.Unlock()
	return cString("host " + hostStatus + ", join " + joinStatus)
}

//export port_tailcat_host
func port_tailcat_host(on C.int) {
	mu.Lock()
	defer mu.Unlock()
	if on == 0 {
		if host != nil {
			go host.Close()
		}
		host, address, hostStatus = nil, "", "off"
		hostRun++
		return
	}
	if host != nil || hostStatus == "starting" {
		return
	}
	hostRun++
	run := hostRun
	hostStatus = "starting"
	go func() {
		h, addr, err := relay.StartHost()
		mu.Lock()
		defer mu.Unlock()
		if run != hostRun { // stopped while starting
			if h != nil {
				go h.Close()
			}
			return
		}
		if err != nil {
			hostStatus = "failed: " + err.Error()
			return
		}
		host, address, hostStatus = h, addr, "ready"
	}()
}

// The invite to share: this phone's Tailcat address while hosting, or "" while it's starting.
//
//export port_tailcat_address
func port_tailcat_address() *C.char {
	mu.Lock()
	defer mu.Unlock()
	return cString(address)
}

// Connects to a hosting phone's invite and starts the local relay. Poll port_tailcat_join_state for the result.
//
//export port_tailcat_join
func port_tailcat_join(invite *C.char) {
	port_tailcat_leave()
	j, err := relay.Listen(C.GoString(invite))
	mu.Lock()
	defer mu.Unlock()
	if err != nil {
		joinState, joinStatus = 3, err.Error()
		return
	}
	join, joinState, joinStatus = j, 1, "connecting"
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		err := j.Connect(ctx)
		cancel()
		mu.Lock()
		if join != j {
			mu.Unlock()
			j.Close()
			return
		}
		if err != nil {
			joinState, joinStatus = 3, "couldn't connect: "+err.Error()
			mu.Unlock()
			j.Close()
			return
		}
		joinState, joinStatus = 2, "connected"
		mu.Unlock()
		j.Run()
		mu.Lock()
		if join == j {
			joinState, joinStatus = 3, "disconnected"
		}
		mu.Unlock()
	}()
}

// 0 not joined, 1 connecting, 2 ready (the game can join 127.0.0.1), 3 failed or disconnected.
//
//export port_tailcat_join_state
func port_tailcat_join_state() C.int {
	mu.Lock()
	defer mu.Unlock()
	return C.int(joinState)
}

//export port_tailcat_leave
func port_tailcat_leave() {
	mu.Lock()
	defer mu.Unlock()
	if join != nil {
		join.Close()
		join = nil
	}
	joinState, joinStatus = 0, "off"
}
