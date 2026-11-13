// The Steam mod's helper (src/pcmod): multiplayer by invite (../../relay) for Slay the Spire 2 on a PC or Mac.
//
//	sts2-tailcat host           prints {"event":"ready","invite":"tc…"} once others can join
//	sts2-tailcat join <invite>  prints {"event":"ready"} once the game can join 127.0.0.1
//
// Then {"event":"error","message":…} if it fails or the connection ends. It exits when its standard input closes,
// so it never outlives the game.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"time"

	"sts2port/tailcat/relay"
)

type event struct {
	Event   string `json:"event"`
	Invite  string `json:"invite,omitempty"`
	Message string `json:"message,omitempty"`
}

var out = json.NewEncoder(os.Stdout)

func main() {
	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		io.Copy(io.Discard, os.Stdin)
		cancel()
	}()
	var err error
	switch {
	case len(os.Args) == 2 && os.Args[1] == "host":
		err = host(ctx)
	case len(os.Args) == 3 && os.Args[1] == "join":
		err = join(ctx, os.Args[2])
	default:
		err = errors.New("usage: sts2-tailcat host | join <invite>")
	}
	if err != nil && ctx.Err() == nil {
		out.Encode(event{Event: "error", Message: err.Error()})
		os.Exit(1)
	}
}

func host(ctx context.Context) error {
	h, invite, err := relay.StartHost()
	if err != nil {
		return err
	}
	defer h.Close()
	out.Encode(event{Event: "ready", Invite: invite})
	<-ctx.Done()
	return nil
}

func join(ctx context.Context, invite string) error {
	j, err := relay.Listen(invite)
	if err != nil {
		return err
	}
	defer j.Close()
	go func() {
		<-ctx.Done()
		j.Close()
	}()
	dial, cancel := context.WithTimeout(ctx, 20*time.Second)
	err = j.Connect(dial)
	cancel()
	if err != nil {
		return err
	}
	out.Encode(event{Event: "ready"})
	j.Run()
	return errors.New("disconnected from the host")
}
