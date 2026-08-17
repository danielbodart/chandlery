// A stand-in Valheim server: it answers A2S queries, prints the arguments it
// was given, and saves only on SIGINT — flatly ignoring SIGTERM, the way the
// real one effectively does. That makes the stop hook's choice of signal
// testable without a 1 GB download.
package main

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"net"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"
)

var singlePacket = []byte{0xff, 0xff, 0xff, 0xff}

const (
	a2sInfoRequest  = 0x54
	a2sInfoResponse = 0x49
	a2sChallenge    = 0x41
)

func main() {
	fmt.Printf("fake-valheim: args %s\n", strings.Join(os.Args[1:], " "))

	gamePort := 2456
	for i, a := range os.Args {
		if a == "-port" && i+1 < len(os.Args) {
			if p, err := strconv.Atoi(os.Args[i+1]); err == nil {
				gamePort = p
			}
		}
	}
	// Valheim answers queries on the game port plus one.
	queryPort := gamePort + 1

	conn, err := net.ListenPacket("udp4", fmt.Sprintf(":%d", queryPort))
	if err != nil {
		fmt.Printf("fake-valheim: listen: %v\n", err)
		os.Exit(1)
	}
	go answerQueries(conn)

	fmt.Printf("fake-valheim: listening on udp/%d (query udp/%d)\n", gamePort, queryPort)

	// SIGTERM is deliberately swallowed: if the stop hook sends the wrong
	// signal, the test should see a container that had to be killed.
	sigint := make(chan os.Signal, 1)
	signal.Notify(sigint, syscall.SIGINT)
	ignored := make(chan os.Signal, 1)
	signal.Notify(ignored, syscall.SIGTERM)
	go func() {
		for range ignored {
			fmt.Println("fake-valheim: ignoring SIGTERM")
		}
	}()

	<-sigint
	fmt.Println("fake-valheim: saving world")
	time.Sleep(time.Second)
	fmt.Println("fake-valheim: world saved")
}

func answerQueries(conn net.PacketConn) {
	buf := make([]byte, 2048)
	// The first query gets a challenge, as a modern Steam server would, so the
	// probe's challenge handling is exercised rather than assumed.
	challenged := false
	for {
		n, addr, err := conn.ReadFrom(buf)
		if err != nil {
			return
		}
		if n < 5 || !bytes.Equal(buf[:4], singlePacket) || buf[4] != a2sInfoRequest {
			continue
		}
		var out bytes.Buffer
		out.Write(singlePacket)
		if !challenged {
			challenged = true
			out.WriteByte(a2sChallenge)
			binary.Write(&out, binary.LittleEndian, uint32(0x0badc0de))
		} else {
			out.WriteByte(a2sInfoResponse)
			out.WriteByte(17)
			out.WriteString("Chandlery Fake\x00")
			out.WriteString("Dedicated\x00")
			out.WriteString("valheim\x00")
			out.WriteString("Valheim\x00")
			binary.Write(&out, binary.LittleEndian, uint16(892970&0xffff))
			out.Write([]byte{0, 10, 0, 'd', 'l', 0, 0})
			out.WriteString("0.220.3\x00")
		}
		conn.WriteTo(out.Bytes(), addr)
	}
}
