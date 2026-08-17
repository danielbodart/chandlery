// chandlery-a2s: an A2S_INFO query, used as Valheim's health check.
//
// Steam's query protocol answers with the server's name, map and player counts.
// That is the point: it proves the server is answering queries, which a
// port-bound check cannot. Bedrock gets the same guarantee from mc-monitor;
// there is no equivalent single-purpose binary for A2S, so this is ours.
//
// Exit 0 and one line of status when the server answers; non-zero otherwise.
package main

import (
	"bytes"
	"encoding/binary"
	"errors"
	"flag"
	"fmt"
	"net"
	"os"
	"time"
)

// Every query and reply is prefixed with this, marking a single (unsplit) packet.
var singlePacket = []byte{0xff, 0xff, 0xff, 0xff}

const (
	a2sInfoRequest  = 0x54 // 'T'
	a2sInfoResponse = 0x49 // 'I'
	a2sChallenge    = 0x41 // 'A'
	splitPacket     = 0xfe

	payload = "Source Engine Query\x00"
)

type info struct {
	Name       string
	Map        string
	Players    byte
	MaxPlayers byte
	Version    string
}

func main() {
	host := flag.String("host", "127.0.0.1", "server address")
	port := flag.Int("port", 2457, "A2S query port (Valheim: game port + 1)")
	timeout := flag.Duration("timeout", 5*time.Second, "give up after this long")
	flag.Parse()

	addr := net.JoinHostPort(*host, fmt.Sprint(*port))
	got, err := query(addr, *timeout)
	if err != nil {
		fmt.Fprintf(os.Stderr, "chandlery-a2s: %s: %v\n", addr, err)
		os.Exit(1)
	}
	fmt.Printf("%s : name=%q map=%q players=%d/%d version=%s\n",
		addr, got.Name, got.Map, got.Players, got.MaxPlayers, got.Version)
}

func query(addr string, timeout time.Duration) (*info, error) {
	conn, err := net.Dial("udp", addr)
	if err != nil {
		return nil, err
	}
	defer conn.Close()

	deadline := time.Now().Add(timeout)
	if err := conn.SetDeadline(deadline); err != nil {
		return nil, err
	}

	request := append(append([]byte{}, singlePacket...), a2sInfoRequest)
	request = append(request, payload...)

	// Modern Steam servers answer the first A2S_INFO with a challenge and
	// expect it echoed back. Older ones reply outright, so handle both, and
	// allow one re-challenge rather than looping on a server that keeps asking.
	for attempt := 0; attempt < 2; attempt++ {
		if _, err := conn.Write(request); err != nil {
			return nil, err
		}

		buf := make([]byte, 4096)
		n, err := conn.Read(buf)
		if err != nil {
			return nil, err
		}
		reply := buf[:n]

		if len(reply) < 5 {
			return nil, fmt.Errorf("reply too short (%d bytes)", n)
		}
		if reply[0] == splitPacket {
			return nil, errors.New("split reply, which A2S_INFO should not need")
		}
		if !bytes.Equal(reply[:4], singlePacket) {
			return nil, fmt.Errorf("not a query reply (header % x)", reply[:4])
		}

		switch reply[4] {
		case a2sInfoResponse:
			return parseInfo(reply[5:])
		case a2sChallenge:
			if len(reply) < 9 {
				return nil, errors.New("truncated challenge")
			}
			request = append(append([]byte{}, singlePacket...), a2sInfoRequest)
			request = append(request, payload...)
			request = append(request, reply[5:9]...)
		default:
			return nil, fmt.Errorf("unexpected reply type 0x%02x", reply[4])
		}
	}
	return nil, errors.New("server kept issuing challenges")
}

// The reply is a packed struct of null-terminated strings and single bytes,
// in this order. We read as far as the fields a health check cares about.
func parseInfo(b []byte) (*info, error) {
	r := &reader{b: b}
	var got info

	r.byte()                  // protocol version
	got.Name = r.string()     //
	got.Map = r.string()      //
	r.string()                // folder
	r.string()                // game
	r.uint16()                // Steam app id
	got.Players = r.byte()    //
	got.MaxPlayers = r.byte() //
	r.byte()                  // bots
	r.byte()                  // server type
	r.byte()                  // environment
	r.byte()                  // visibility
	r.byte()                  // VAC
	got.Version = r.string()  //

	if r.err != nil {
		return nil, r.err
	}
	return &got, nil
}

// A cursor that stops at the first short read, so callers check once at the end.
type reader struct {
	b   []byte
	i   int
	err error
}

func (r *reader) byte() byte {
	if r.err != nil || r.i >= len(r.b) {
		r.fail()
		return 0
	}
	v := r.b[r.i]
	r.i++
	return v
}

func (r *reader) uint16() uint16 {
	if r.err != nil || r.i+2 > len(r.b) {
		r.fail()
		return 0
	}
	v := binary.LittleEndian.Uint16(r.b[r.i:])
	r.i += 2
	return v
}

func (r *reader) string() string {
	if r.err != nil {
		return ""
	}
	end := bytes.IndexByte(r.b[r.i:], 0)
	if end < 0 {
		r.fail()
		return ""
	}
	v := string(r.b[r.i : r.i+end])
	r.i += end + 1
	return v
}

func (r *reader) fail() {
	if r.err == nil {
		r.err = errors.New("reply ended mid-field")
	}
}
