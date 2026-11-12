// Linked into the app by build.sh. Multiplayer from anywhere over Tailcat (github.com/tailscale/tailcat): WireGuard
// tunnels between the phones, set up through Tailscale's DERP relays, with no Tailscale account, app or VPN.
//
// The game plays over UDP (ENet on 33771, plus the port's names and heartbeat on 33772, src/native/Port/PortNames.cs)
// and stays unchanged, as with Wi-Fi Aware (src/ios/nearby_play.swift):
//   - Hosting phone: runs a Tailcat server whose address is the invite the host shares. Each phone that joins gets its
//     own two UDP sockets to 127.0.0.1:33771 and :33772, so the game's host sees it as one more player on this phone.
//   - Joining phone: connects to the invite and opens UDP listeners on 127.0.0.1:33771 and :33772, and the game joins
//     127.0.0.1 as if the host were on this phone.
//
// One TCP connection through the tunnel per joining phone carries both ports, framed like nearby_play.swift:
// [port index][length (2 bytes)][datagram]. Not UDP through the tunnel: its 1280-byte MTU is below ENet's 1392.
//
// C entry points (src/native/Port/PortTailcat.cs), called on the main thread.
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"io"
	"net"
	"strings"
	"sync"
	"time"
	"unsafe"

	"github.com/tailscale/tailcat"
	"tailscale.com/wgengine/filter"
)

const (
	tunnelPort = 33771
	maxJoiners = 8
)

var (
	gamePorts = []int{33771, 33772}
	loopback  = net.IPv4(127, 0, 0, 1)
	quiet     = func(string, ...any) {}
)

var (
	mu         sync.Mutex
	server     *tailcat.Server
	serverUp   bool
	address    string
	hostStatus = "off"
	join       *joinLink
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

// ---- host ----

//export port_tailcat_host
func port_tailcat_host(on C.int) {
	mu.Lock()
	defer mu.Unlock()
	if on == 0 {
		if server != nil && serverUp {
			go server.Close()
		}
		server, serverUp, address, hostStatus = nil, false, "", "off"
		return
	}
	if server != nil {
		return
	}
	slots := make(chan struct{}, maxJoiners)
	s := &tailcat.Server{
		Logf:           quiet,
		ServedTCPPorts: []filter.PortRange{{First: tunnelPort, Last: tunnelPort}},
		OnTCP: func(port uint16) func(net.Conn) {
			if port != tunnelPort {
				return nil
			}
			return func(tunnel net.Conn) {
				select {
				case slots <- struct{}{}:
					defer func() { <-slots }()
					serveJoiner(tunnel)
				default:
					tunnel.Close()
				}
			}
		},
	}
	server, hostStatus = s, "starting"
	go func() {
		err := s.Start()
		mu.Lock()
		defer mu.Unlock()
		if server != s { // stopped while starting
			if err == nil {
				go s.Close()
			}
			return
		}
		if err != nil {
			server, hostStatus = nil, "failed: "+err.Error()
			return
		}
		serverUp, address, hostStatus = true, string(s.TailcatAddr()), "ready"
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

// A joining phone's tunnel connection, relayed to the game on this phone.
func serveJoiner(tunnel net.Conn) {
	defer tunnel.Close()
	var udp []*net.UDPConn
	defer func() {
		for _, u := range udp {
			u.Close()
		}
	}()
	for _, port := range gamePorts {
		u, err := net.DialUDP("udp", nil, &net.UDPAddr{IP: loopback, Port: port})
		if err != nil {
			return
		}
		udp = append(udp, u)
	}
	out := &frameWriter{w: tunnel}
	for i, u := range udp {
		go func() {
			defer tunnel.Close()
			buf := make([]byte, 65535)
			for {
				n, err := u.Read(buf)
				if err != nil || out.send(i, buf[:n]) != nil {
					return
				}
			}
		}()
	}
	readFrames(tunnel, func(port int, data []byte) { udp[port].Write(data) })
}

// ---- join ----

type joinLink struct {
	client *tailcat.Client
	udp    []*net.UDPConn
	once   sync.Once
	mu     sync.Mutex
	tunnel net.Conn
	game   []*net.UDPAddr // the game's own socket for each port (the latest one that sent something)
}

func (j *joinLink) close() {
	j.once.Do(func() {
		for _, u := range j.udp {
			u.Close()
		}
		j.mu.Lock()
		if j.tunnel != nil {
			j.tunnel.Close()
		}
		j.mu.Unlock()
		go j.client.Close()
	})
}

// Connects to a hosting phone's invite and starts the local relay. Poll port_tailcat_join_state for the result.
//
//export port_tailcat_join
func port_tailcat_join(invite *C.char) {
	port_tailcat_leave()
	addr := tailcat.Addr(strings.TrimSpace(C.GoString(invite)))
	mu.Lock()
	defer mu.Unlock()
	if _, err := tailcat.ParseAddr(addr); err != nil {
		joinState, joinStatus = 3, "invalid invite: "+err.Error()
		return
	}
	j := &joinLink{client: &tailcat.Client{Server: addr, Logf: quiet}, game: make([]*net.UDPAddr, len(gamePorts))}
	for _, port := range gamePorts {
		u, err := net.ListenUDP("udp", &net.UDPAddr{IP: loopback, Port: port})
		if err != nil { // e.g. this phone is hosting
			j.close()
			joinState, joinStatus = 3, "listen: "+err.Error()
			return
		}
		j.udp = append(j.udp, u)
	}
	join, joinState, joinStatus = j, 1, "connecting"
	go j.run()
}

func (j *joinLink) run() {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	tunnel, err := j.client.DialTCPPort(ctx, tunnelPort)
	cancel()
	mu.Lock()
	if join != j {
		mu.Unlock()
		if tunnel != nil {
			tunnel.Close()
		}
		return
	}
	if err != nil {
		joinState, joinStatus = 3, "couldn't connect: "+err.Error()
		mu.Unlock()
		j.close()
		return
	}
	j.mu.Lock()
	j.tunnel = tunnel
	j.mu.Unlock()
	joinState, joinStatus = 2, "connected"
	mu.Unlock()

	out := &frameWriter{w: tunnel}
	for i, u := range j.udp {
		go func() {
			defer tunnel.Close()
			buf := make([]byte, 65535)
			for {
				n, from, err := u.ReadFromUDP(buf)
				if err != nil {
					return
				}
				j.mu.Lock()
				j.game[i] = from
				j.mu.Unlock()
				if out.send(i, buf[:n]) != nil {
					return
				}
			}
		}()
	}
	readFrames(tunnel, func(port int, data []byte) {
		j.mu.Lock()
		to := j.game[port]
		j.mu.Unlock()
		if to != nil {
			j.udp[port].WriteToUDP(data, to)
		}
	})
	mu.Lock()
	if join == j {
		joinState, joinStatus = 3, "disconnected"
	}
	mu.Unlock()
	j.close()
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
		join.close()
		join = nil
	}
	joinState, joinStatus = 0, "off"
}

// ---- frames ----

type frameWriter struct {
	mu sync.Mutex
	w  io.Writer
}

func (f *frameWriter) send(port int, payload []byte) error {
	if len(payload) > 0xFFFF {
		return nil
	}
	b := make([]byte, 3+len(payload))
	b[0], b[1], b[2] = byte(port), byte(len(payload)>>8), byte(len(payload))
	copy(b[3:], payload)
	f.mu.Lock()
	defer f.mu.Unlock()
	_, err := f.w.Write(b)
	return err
}

// Reads frames from a tunnel connection until it closes.
func readFrames(r io.Reader, deliver func(port int, data []byte)) {
	head := make([]byte, 3)
	body := make([]byte, 65535)
	for {
		if _, err := io.ReadFull(r, head); err != nil {
			return
		}
		n := int(head[1])<<8 | int(head[2])
		if _, err := io.ReadFull(r, body[:n]); err != nil {
			return
		}
		if int(head[0]) < len(gamePorts) {
			deliver(int(head[0]), body[:n])
		}
	}
}
