package main

import (
	"bytes"
	"encoding/binary"
	"net"
	"testing"
	"time"
)

// A fake Steam query server. reply decides what to send for each request, so a
// test can make it challenge first, answer outright, or return nonsense.
func serve(t *testing.T, reply func(req []byte, seq int) []byte) string {
	t.Helper()
	conn, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { conn.Close() })

	go func() {
		buf := make([]byte, 2048)
		for seq := 0; ; seq++ {
			n, addr, err := conn.ReadFrom(buf)
			if err != nil {
				return
			}
			if out := reply(append([]byte{}, buf[:n]...), seq); out != nil {
				conn.WriteTo(out, addr)
			}
		}
	}()
	return conn.LocalAddr().String()
}

func infoReply() []byte {
	var b bytes.Buffer
	b.Write(singlePacket)
	b.WriteByte(a2sInfoResponse)
	b.WriteByte(17)                      // protocol
	b.WriteString("Chandlery Test\x00")  // name
	b.WriteString("Dedicated\x00")       // map (Valheim reports the world)
	b.WriteString("valheim\x00")         // folder
	b.WriteString("Valheim\x00")         // game
	// The app-id field is two bytes, so large ids arrive truncated. Valheim's
	// 892970 is exactly such a case, which is why nothing reads this field.
	binary.Write(&b, binary.LittleEndian, uint16(892970&0xffff))
	b.WriteByte(3)  // players
	b.WriteByte(10) // max
	b.WriteByte(0)  // bots
	b.WriteByte('d')
	b.WriteByte('l')
	b.WriteByte(0) // visibility
	b.WriteByte(0) // VAC
	b.WriteString("0.220.3\x00")
	return b.Bytes()
}

func challengeReply(challenge uint32) []byte {
	var b bytes.Buffer
	b.Write(singlePacket)
	b.WriteByte(a2sChallenge)
	binary.Write(&b, binary.LittleEndian, challenge)
	return b.Bytes()
}

func TestAnswersOutright(t *testing.T) {
	addr := serve(t, func([]byte, int) []byte { return infoReply() })

	got, err := query(addr, time.Second)
	if err != nil {
		t.Fatalf("query: %v", err)
	}
	if got.Name != "Chandlery Test" || got.Map != "Dedicated" {
		t.Errorf("name/map = %q/%q", got.Name, got.Map)
	}
	if got.Players != 3 || got.MaxPlayers != 10 {
		t.Errorf("players = %d/%d, want 3/10", got.Players, got.MaxPlayers)
	}
	if got.Version != "0.220.3" {
		t.Errorf("version = %q", got.Version)
	}
}

func TestEchoesTheChallenge(t *testing.T) {
	const challenge = uint32(0xdeadbeef)
	var second []byte

	addr := serve(t, func(req []byte, seq int) []byte {
		if seq == 0 {
			return challengeReply(challenge)
		}
		second = req
		return infoReply()
	})

	if _, err := query(addr, 2*time.Second); err != nil {
		t.Fatalf("query: %v", err)
	}
	want := make([]byte, 4)
	binary.LittleEndian.PutUint32(want, challenge)
	if len(second) < 4 || !bytes.Equal(second[len(second)-4:], want) {
		t.Errorf("challenge not echoed back; tail = % x", second)
	}
}

func TestGivesUpOnEndlessChallenges(t *testing.T) {
	addr := serve(t, func([]byte, int) []byte { return challengeReply(1) })

	if _, err := query(addr, 2*time.Second); err == nil {
		t.Fatal("expected an error, got a healthy result")
	}
}

func TestRejectsTruncatedReply(t *testing.T) {
	// A reply that ends mid-string must fail, not report a half-parsed server.
	addr := serve(t, func([]byte, int) []byte {
		return append(append([]byte{}, singlePacket...), a2sInfoResponse, 17, 'a', 'b')
	})

	if _, err := query(addr, time.Second); err == nil {
		t.Fatal("expected an error for a truncated reply")
	}
}

func TestFailsWhenNothingListens(t *testing.T) {
	// The case that matters: a dead server must read as unhealthy.
	if _, err := query("127.0.0.1:1", 500*time.Millisecond); err == nil {
		t.Fatal("expected an error against a closed port")
	}
}
