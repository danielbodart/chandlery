// A stand-in Bedrock server that answers RakNet unconnected pings and does
// nothing else. It exists so the health probe can be tested for real: that it
// finds the right port, speaks the right protocol, and reports the right exit
// status — without needing a 200 MB game server that cannot run in CI.
package main

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"log"
	"net"
	"os"
)

// The RakNet "offline message" magic, sent in every unconnected ping and pong.
var magic = []byte{
	0x00, 0xff, 0xff, 0x00, 0xfe, 0xfe, 0xfe, 0xfe,
	0xfd, 0xfd, 0xfd, 0xfd, 0x12, 0x34, 0x56, 0x78,
}

const (
	idUnconnectedPing = 0x01
	idUnconnectedPong = 0x1c
	serverGUID        = uint64(0x0123456789abcdef)
)

// Semicolon-separated, in the order Bedrock clients expect:
// edition;motd;protocol;version;online;max;guid;sub-motd;gamemode;gamemode-num;portv4;portv6
const motd = "MCPE;Chandlery Test;800;1.26.44;0;10;13639654882369196525;chandlery;Survival;1;19132;19133;"

func main() {
	port := "19132"
	if len(os.Args) > 1 {
		port = os.Args[1]
	}

	conn, err := net.ListenPacket("udp4", ":"+port)
	if err != nil {
		log.Fatalf("raknet-pong: listen: %v", err)
	}
	defer conn.Close()
	fmt.Printf("raknet-pong: listening on udp/%s\n", port)

	buf := make([]byte, 1500)
	for {
		n, addr, err := conn.ReadFrom(buf)
		if err != nil {
			log.Fatalf("raknet-pong: read: %v", err)
		}
		// A ping is: id(1) + client time(8) + magic(16) + client guid(8).
		if n < 33 || buf[0] != idUnconnectedPing || !bytes.Equal(buf[9:25], magic) {
			continue
		}

		var pong bytes.Buffer
		pong.WriteByte(idUnconnectedPong)
		pong.Write(buf[1:9]) // echo the client's timestamp back
		binary.Write(&pong, binary.BigEndian, serverGUID)
		pong.Write(magic)
		binary.Write(&pong, binary.BigEndian, uint16(len(motd)))
		pong.WriteString(motd)

		if _, err := conn.WriteTo(pong.Bytes(), addr); err != nil {
			log.Printf("raknet-pong: write: %v", err)
		}
	}
}
