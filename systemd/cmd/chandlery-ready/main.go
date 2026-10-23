// chandlery-ready: run a game server under systemd's Type=notify.
//
//	chandlery-ready [--pattern REGEX | --game-env FILE] [--lock FILE] -- COMMAND [ARGS...]
//
// systemd can only call a server "started" when something tells it so, and a
// game never does. This stands between the two: it starts COMMAND as its child,
// copies everything the child prints to its own stdout (the journal) unchanged,
// and sends READY=1 to $NOTIFY_SOCKET on the first line matching the pattern —
// the line the game prints when players can actually join. Without
// NOTIFY_SOCKET, or without a pattern, it is a transparent pass-through.
//
// It stays the unit's main process for the child's whole life rather than
// exec'ing the game, because with PrivatePIDs=yes the main process is PID 1 of
// its namespace, and when PID 1 exits the kernel kills everything left in it: a
// reader left behind would die with the game's last lines ("Quit correctly")
// still unread in the pipe. So it ignores SIGINT/SIGTERM itself — systemd's
// KillSignal reaches the game directly through the cgroup — keeps draining until
// the child is gone, reaps orphans as PID 1 must, and exits with the child's
// status (128+n for a signal).
//
// --lock holds an exclusive flock on FILE until the child has exited and its
// output is in the journal: what chandlery-stop waits on, since with
// PrivatePIDs an ExecStop cannot see the game's PID to wait for it.
package main

import (
	"bufio"
	"bytes"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"regexp"
	"strings"
	"syscall"
	"time"
)

// How long to keep draining after the child exits, in case something it left
// behind still holds the pipe open. The child's own output is already in the
// pipe by then; this only bounds a stray grandchild.
const drainGrace = 5 * time.Second

// A line longer than this is still copied in full; only matching looks at no
// more than its first maxLine bytes.
const maxLine = 64 * 1024

const prSetChildSubreaper = 36

type options struct {
	pattern *regexp.Regexp
	lock    string
	argv    []string
}

func main() {
	opts, err := parseArgs(os.Args[1:])
	if err != nil {
		logf("%v", err)
		fmt.Fprintln(os.Stderr, "usage: chandlery-ready [--pattern REGEX | --game-env FILE] [--lock FILE] -- COMMAND [ARGS...]")
		os.Exit(64)
	}
	os.Exit(run(opts, os.Stdout))
}

func parseArgs(args []string) (options, error) {
	var o options
	fs := flag.NewFlagSet("chandlery-ready", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	pattern := fs.String("pattern", "", "RE2 matching the line the game prints when it is up")
	gameEnv := fs.String("game-env", "", "a package's lib/chandlery/game.env, whose CHANDLERY_READY is the pattern")
	fs.StringVar(&o.lock, "lock", "", "hold an exclusive flock on this file until the child has exited")
	if err := fs.Parse(args); err != nil {
		return o, err
	}
	o.argv = fs.Args()
	if len(o.argv) == 0 {
		return o, errors.New("no command given")
	}

	expr := *pattern
	if expr == "" && *gameEnv != "" {
		env, err := readEnvFile(*gameEnv)
		if err != nil {
			return o, err
		}
		expr = env["CHANDLERY_READY"]
	}
	if expr != "" {
		re, err := regexp.Compile(expr)
		if err != nil {
			return o, fmt.Errorf("bad pattern %q: %v", expr, err)
		}
		o.pattern = re
	}
	return o, nil
}

func run(o options, out io.Writer) int {
	if o.lock != "" {
		f, err := os.OpenFile(o.lock, os.O_CREATE|os.O_RDWR, 0o600)
		if err != nil {
			logf("cannot open lock: %v", err)
			return 71
		}
		defer f.Close()
		if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil {
			logf("cannot lock %s: %v", o.lock, err)
			return 71
		}
	}

	// Orphans come to us whether or not we are PID 1 of a namespace.
	syscall.RawSyscall(syscall.SYS_PRCTL, prSetChildSubreaper, 1, 0)

	// Caught, not ignored: an ignored disposition would be inherited across exec
	// and the game would never hear the KillSignal systemd sends it.
	sigs := make(chan os.Signal, 8)
	signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP)
	go func() {
		for range sigs {
		}
	}()

	path, err := exec.LookPath(o.argv[0])
	if err != nil {
		logf("%v", err)
		return 127
	}
	r, w, err := os.Pipe()
	if err != nil {
		logf("%v", err)
		return 71
	}
	child, err := os.StartProcess(path, o.argv, &os.ProcAttr{
		Env:   childEnv(),
		Files: []*os.File{os.Stdin, w, w},
	})
	w.Close()
	if err != nil {
		logf("cannot start %s: %v", o.argv[0], err)
		return 126
	}

	drained := make(chan struct{})
	go func() {
		copyLines(r, out, o.pattern, ready)
		close(drained)
	}()

	status := reap(child.Pid)

	select {
	case <-drained:
	case <-time.After(drainGrace):
		logf("output still open %s after the server exited; leaving it", drainGrace)
	}
	return status
}

// The child is not the one to talk to systemd: with NotifyAccess=main it could
// not anyway, and a game that did would race our READY=1.
func childEnv() []string {
	var env []string
	for _, kv := range os.Environ() {
		if !strings.HasPrefix(kv, "NOTIFY_SOCKET=") {
			env = append(env, kv)
		}
	}
	return env
}

// reap waits for every child, ours and inherited orphans alike, until the one
// we started exits, and returns its status the way a shell reports it.
func reap(pid int) int {
	for {
		var ws syscall.WaitStatus
		got, err := syscall.Wait4(-1, &ws, 0, nil)
		if err == syscall.EINTR {
			continue
		}
		if err != nil {
			logf("wait: %v", err)
			return 71
		}
		if got != pid {
			continue
		}
		switch {
		case ws.Exited():
			return ws.ExitStatus()
		case ws.Signaled():
			return 128 + int(ws.Signal())
		}
	}
}

// copyLines copies r to out byte for byte and calls onMatch once, with the
// line, the first time a complete line matches pattern.
func copyLines(r io.Reader, out io.Writer, pattern *regexp.Regexp, onMatch func(string)) {
	matched := pattern == nil
	var line []byte
	buf := make([]byte, 32*1024)
	for {
		n, err := r.Read(buf)
		if n > 0 {
			chunk := buf[:n]
			out.Write(chunk)
			for !matched && len(chunk) > 0 {
				i := bytes.IndexByte(chunk, '\n')
				if i < 0 {
					line = appendCapped(line, chunk)
					break
				}
				line = appendCapped(line, chunk[:i])
				chunk = chunk[i+1:]
				text := strings.TrimRight(string(line), "\r")
				line = line[:0]
				if pattern.MatchString(text) {
					matched = true
					onMatch(text)
				}
			}
		}
		if err != nil {
			return
		}
	}
}

func appendCapped(line, more []byte) []byte {
	if room := maxLine - len(line); room < len(more) {
		more = more[:max(room, 0)]
	}
	return append(line, more...)
}

func ready(line string) {
	status := line
	if len(status) > 200 {
		status = status[:200]
	}
	if err := notify("READY=1\nSTATUS=" + status); err != nil {
		logf("cannot notify systemd: %v", err)
	}
}

// notify sends one sd_notify(3) datagram. No NOTIFY_SOCKET means nobody asked.
func notify(state string) error {
	addr := os.Getenv("NOTIFY_SOCKET")
	if addr == "" {
		return nil
	}
	// Go maps a leading '@' to the abstract namespace itself.
	conn, err := net.DialUnix("unixgram", nil, &net.UnixAddr{Name: addr, Net: "unixgram"})
	if err != nil {
		return err
	}
	defer conn.Close()
	_, err = conn.Write([]byte(state))
	return err
}

// readEnvFile reads KEY=VALUE lines, the subset of sh that game.env uses: a
// value may be wrapped in single quotes, comments and blank lines are skipped.
func readEnvFile(path string) (map[string]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	env := map[string]string{}
	s := bufio.NewScanner(f)
	for s.Scan() {
		text := strings.TrimSpace(s.Text())
		if text == "" || strings.HasPrefix(text, "#") {
			continue
		}
		key, value, ok := strings.Cut(text, "=")
		if !ok {
			continue
		}
		if len(value) >= 2 && value[0] == '\'' && value[len(value)-1] == '\'' {
			value = value[1 : len(value)-1]
		}
		env[key] = value
	}
	return env, s.Err()
}

func logf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "[chandlery-ready] "+format+"\n", args...)
}
