// Package relay carries Slay the Spire 2's multiplayer between two machines over Tailcat
// (github.com/tailscale/tailcat): WireGuard tunnels set up through Tailscale's DERP relays, with no Tailscale
// account, app or VPN. The iOS port links it into the app (../ios); a PC runs it as a helper next to the game
// (../cmd/sts2-tailcat, used by the Steam mod in src/pcmod).
//
// The game plays over UDP (ENet on 33771, plus the iOS port's names and heartbeat on 33772) and stays unchanged:
//   - Host: a Tailcat server whose address is the invite the host shares. Each joining machine gets its own two UDP
//     sockets to 127.0.0.1:33771 and :33772, so the game's host sees it as one more player on this machine.
//   - Join: UDP listeners on 127.0.0.1:33771 and :33772 relayed to the invite, and the game joins 127.0.0.1 as if
//     the host were on this machine.
//
// One TCP connection through the tunnel per joining machine carries both ports, framed like the iOS port's Wi-Fi
// Aware relay (src/ios/nearby_play.swift): [port index][length (2 bytes)][datagram]. Not UDP through the tunnel:
// its 1280-byte MTU is below ENet's 1392.
package relay

import (
	"context"
	"errors"
	"io"
	"net"
	"strings"
	"sync"

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
)

// Logf receives Tailcat's own diagnostics; set it before starting a host or join.
var Logf = func(string, ...any) {}

// ---- host ----

// Host offers this machine's game to whoever has its invite.
type Host struct {
	server *tailcat.Server
}

// StartHost connects to a DERP relay and returns the host and its invite.
func StartHost() (*Host, string, error) {
	slots := make(chan struct{}, maxJoiners)
	s := &tailcat.Server{
		Logf:           Logf,
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
	if err := s.Start(); err != nil {
		s.Close()
		return nil, "", err
	}
	return &Host{server: s}, string(s.TailcatAddr()), nil
}

func (h *Host) Close() { h.server.Close() }

// A joining machine's tunnel connection, relayed to the game on this machine.
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
				n, _, err := u.ReadFromUDP(buf)
				if closed(err) {
					return
				}
				if err == nil && out.send(i, buf[:n]) != nil {
					return
				}
			}
		}()
	}
	readFrames(tunnel, func(port int, data []byte) { udp[port].Write(data) })
}

// ---- join ----

// Join relays the game's ports on this machine to a host's invite.
type Join struct {
	client *tailcat.Client
	udp    []*net.UDPConn
	once   sync.Once
	mu     sync.Mutex
	tunnel net.Conn
	game   []*net.UDPAddr // the game's own socket for each port (the latest one that sent something)
}

// Listen checks the invite and opens the game's ports on 127.0.0.1. It fails if a port is taken, e.g. because
// this machine is hosting.
func Listen(invite string) (*Join, error) {
	addr := tailcat.Addr(strings.TrimSpace(invite))
	if _, err := tailcat.ParseAddr(addr); err != nil {
		return nil, errors.New("not an invite: " + err.Error())
	}
	j := &Join{client: &tailcat.Client{Server: addr, Logf: Logf}, game: make([]*net.UDPAddr, len(gamePorts))}
	for _, port := range gamePorts {
		u, err := net.ListenUDP("udp", &net.UDPAddr{IP: loopback, Port: port})
		if err != nil {
			j.Close()
			return nil, err
		}
		j.udp = append(j.udp, u)
	}
	return j, nil
}

// Connect opens the tunnel to the host.
func (j *Join) Connect(ctx context.Context) error {
	tunnel, err := j.client.DialTCPPort(ctx, tunnelPort)
	if err != nil {
		return err
	}
	j.mu.Lock()
	defer j.mu.Unlock()
	if j.udp == nil {
		tunnel.Close()
		return net.ErrClosed
	}
	j.tunnel = tunnel
	return nil
}

// Run relays the game's datagrams until the tunnel or the join closes. Call after Connect.
func (j *Join) Run() {
	defer j.Close()
	j.mu.Lock()
	tunnel, udp := j.tunnel, j.udp
	j.mu.Unlock()
	if tunnel == nil {
		return
	}
	out := &frameWriter{w: tunnel}
	for i, u := range udp {
		go func() {
			defer tunnel.Close()
			buf := make([]byte, 65535)
			for {
				n, from, err := u.ReadFromUDP(buf)
				if closed(err) {
					return
				}
				if err != nil {
					continue
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
			udp[port].WriteToUDP(data, to)
		}
	})
}

func (j *Join) Close() {
	j.once.Do(func() {
		j.mu.Lock()
		for _, u := range j.udp {
			u.Close()
		}
		j.udp = nil
		if j.tunnel != nil {
			j.tunnel.Close()
		}
		j.mu.Unlock()
		go j.client.Close()
	})
}

// A UDP read error that ends the relay. Others are a port with nothing listening (ICMP port unreachable, e.g.
// 33772 on a PC host, which doesn't run the iOS port's names service) and pass.
func closed(err error) bool { return err != nil && errors.Is(err, net.ErrClosed) }

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
