package main

import (
	"bytes"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"testing"
	"time"
)

// The tests run the real binary: this test binary re-executed as main(), so
// signals, the notify socket and exit statuses are exercised for real.
func TestMain(m *testing.M) {
	if os.Getenv("CHANDLERY_READY_UNDER_TEST") == "1" {
		main()
		return
	}
	os.Exit(m.Run())
}

func command(t *testing.T, args ...string) *exec.Cmd {
	t.Helper()
	cmd := exec.Command(os.Args[0], args...)
	cmd.Env = append(os.Environ(), "CHANDLERY_READY_UNDER_TEST=1")
	return cmd
}

func listen(t *testing.T) (*net.UnixConn, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "notify")
	conn, err := net.ListenUnixgram("unixgram", &net.UnixAddr{Name: path, Net: "unixgram"})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	return conn, path
}

func receive(t *testing.T, conn *net.UnixConn, within time.Duration) (string, bool) {
	t.Helper()
	conn.SetReadDeadline(time.Now().Add(within))
	buf := make([]byte, 4096)
	n, err := conn.Read(buf)
	if err != nil {
		return "", false
	}
	return string(buf[:n]), true
}

func TestPassesOutputThroughByteForByte(t *testing.T) {
	cmd := command(t, "--", "sh", "-c", `printf 'one\r\ntwo\n\nno newline'; printf 'err\n' >&2`)
	out, err := cmd.Output()
	if err != nil {
		t.Fatal(err)
	}
	if want := "one\r\ntwo\n\nno newlineerr\n"; string(out) != want {
		t.Fatalf("got %q, want %q", out, want)
	}
}

func TestNotifiesOnceAndOnlyOnAMatch(t *testing.T) {
	conn, path := listen(t)
	cmd := command(t, "--pattern", `Server started\.`, "--",
		"sh", "-c", `echo booting; sleep 0.3; echo 'Server started.'; echo 'Server started.'; sleep 0.3`)
	cmd.Env = append(cmd.Env, "NOTIFY_SOCKET="+path)
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	if got, ok := receive(t, conn, 200*time.Millisecond); ok {
		t.Fatalf("notified before the line: %q", got)
	}
	got, ok := receive(t, conn, 5*time.Second)
	if !ok || !strings.HasPrefix(got, "READY=1\n") || !strings.Contains(got, "STATUS=Server started.") {
		t.Fatalf("got %q, %v", got, ok)
	}
	if got, ok := receive(t, conn, 500*time.Millisecond); ok {
		t.Fatalf("notified twice: %q", got)
	}
	if err := cmd.Wait(); err != nil {
		t.Fatal(err)
	}
}

func TestTakesThePatternFromGameEnv(t *testing.T) {
	conn, path := listen(t)
	env := filepath.Join(t.TempDir(), "game.env")
	os.WriteFile(env, []byte("GAME=bedrock\nCHANDLERY_READY='Server started\\.'\n"), 0o644)
	cmd := command(t, "--game-env", env, "--", "sh", "-c", `echo 'Server startedX'; echo 'Server started.'`)
	cmd.Env = append(cmd.Env, "NOTIFY_SOCKET="+path)
	if err := cmd.Run(); err != nil {
		t.Fatal(err)
	}
	if got, ok := receive(t, conn, time.Second); !ok || !strings.Contains(got, "STATUS=Server started.") {
		t.Fatalf("got %q, %v", got, ok)
	}
}

func TestIsAPassThroughWithoutNotifySocket(t *testing.T) {
	cmd := command(t, "--pattern", "up", "--", "sh", "-c", "echo up; exit 0")
	cmd.Env = append(cmd.Env, "NOTIFY_SOCKET=")
	out, err := cmd.Output()
	if err != nil || string(out) != "up\n" {
		t.Fatalf("got %q, %v", out, err)
	}
}

func TestTheChildDoesNotSeeNotifySocket(t *testing.T) {
	_, path := listen(t)
	cmd := command(t, "--", "sh", "-c", `echo "[${NOTIFY_SOCKET-unset}]"`)
	cmd.Env = append(cmd.Env, "NOTIFY_SOCKET="+path)
	out, _ := cmd.Output()
	if string(out) != "[unset]\n" {
		t.Fatalf("got %q", out)
	}
}

func TestExitsWithTheChildsStatus(t *testing.T) {
	for _, c := range []struct {
		script string
		want   int
	}{
		{"exit 0", 0},
		{"exit 3", 3},
		{"kill -KILL $$", 128 + 9},
	} {
		err := command(t, "--", "sh", "-c", c.script).Run()
		got := 0
		if exit, ok := err.(*exec.ExitError); ok {
			got = exit.ExitCode()
		} else if err != nil {
			t.Fatal(err)
		}
		if got != c.want {
			t.Errorf("%q: got %d, want %d", c.script, got, c.want)
		}
	}
}

// systemd's KillSignal goes to the whole cgroup. The wrapper must survive it
// and keep copying until the game, which saves on its own terms, has said its
// last line.
func TestKeepsDrainingAfterSigintAndSigterm(t *testing.T) {
	cmd := command(t, "--", "sh", "-c",
		`trap 'echo got-signal' INT TERM; echo up; sleep 1; echo saving; sleep 0.5; echo 'Quit correctly'`)
	var out bytes.Buffer
	cmd.Stdout = &out
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	time.Sleep(300 * time.Millisecond)
	cmd.Process.Signal(syscall.SIGINT)
	cmd.Process.Signal(syscall.SIGTERM)
	if err := cmd.Wait(); err != nil {
		t.Fatalf("%v; output %q", err, out.String())
	}
	if !strings.HasSuffix(out.String(), "Quit correctly\n") {
		t.Fatalf("lost the last line: %q", out.String())
	}
}

// The signal is caught, not ignored: an ignored disposition would be inherited
// across exec and the game could never be told to stop.
func TestTheChildCanStillBeSignalled(t *testing.T) {
	cmd := command(t, "--", "sh", "-c", `echo $$; exec sleep 30`)
	stdout, _ := cmd.StdoutPipe()
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	var pid int
	buf := make([]byte, 32)
	n, _ := stdout.Read(buf)
	if _, err := fmt.Sscan(string(buf[:n]), &pid); err != nil {
		t.Fatal(err)
	}
	time.Sleep(100 * time.Millisecond)
	syscall.Kill(pid, syscall.SIGTERM)
	err := cmd.Wait()
	if exit, ok := err.(*exec.ExitError); !ok || exit.ExitCode() != 128+int(syscall.SIGTERM) {
		t.Fatalf("got %v", err)
	}
}

func TestHoldsTheLockUntilDrained(t *testing.T) {
	lock := filepath.Join(t.TempDir(), "running")
	cmd := command(t, "--lock", lock, "--", "sh", "-c", "sleep 1; echo done")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	time.Sleep(300 * time.Millisecond)
	f, err := os.Open(lock)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err == nil {
		t.Fatal("lock was free while the server ran")
	}
	start := time.Now()
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil {
		t.Fatal(err)
	}
	if time.Since(start) < 300*time.Millisecond {
		t.Fatal("lock released early")
	}
	cmd.Wait()
}

func TestMatchesLinesSplitAcrossReads(t *testing.T) {
	r, w, _ := os.Pipe()
	var got []string
	done := make(chan struct{})
	go func() {
		copyLines(r, &bytes.Buffer{}, []watch{{regexp.MustCompile(`^Server started\.$`), func(l string) { got = append(got, l) }}})
		close(done)
	}()
	w.Write([]byte("Server st"))
	time.Sleep(50 * time.Millisecond)
	w.Write([]byte("arted.\r\nServer started.\n"))
	w.Close()
	<-done
	if len(got) != 1 || got[0] != "Server started." {
		t.Fatalf("got %q", got)
	}
}

// Bedrock's shape: a console reader the game waits for before it will exit,
// on a console that never reaches end-of-file (the socket unit holds its FIFO
// open). Lines typed before the stop still reach the game; its own stop line
// then gives it end-of-file, and it exits.
func TestEndsTheConsoleWhenTheGameStopsItself(t *testing.T) {
	console, typing, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer typing.Close()
	cmd := command(t, "--stopping", `Server stop requested\.`, "--",
		"sh", "-c", `read -r line; echo "typed: $line"; echo 'Server stop requested.'; cat >/dev/null; echo 'Quit correctly'`)
	cmd.Stdin = console
	var out bytes.Buffer
	cmd.Stdout = &out
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	console.Close()
	typing.Write([]byte("say hello\n"))
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		cmd.Process.Kill()
		t.Fatalf("still running with the console open; output %q", out.String())
	}
	if want := "typed: say hello\nServer stop requested.\nQuit correctly\n"; out.String() != want {
		t.Fatalf("got %q, want %q", out.String(), want)
	}
}

func TestTakesTheStoppingPatternFromGameEnv(t *testing.T) {
	env := filepath.Join(t.TempDir(), "game.env")
	os.WriteFile(env, []byte("CHANDLERY_READY='Server started\\.'\nCHANDLERY_STOPPING='Server stop requested\\.'\n"), 0o644)
	o, err := parseArgs([]string{"--game-env", env, "--", "true"})
	if err != nil {
		t.Fatal(err)
	}
	if o.pattern.String() != `Server started\.` || o.stopping.String() != `Server stop requested\.` {
		t.Fatalf("got %v and %v", o.pattern, o.stopping)
	}
}

func TestRefusesNoCommand(t *testing.T) {
	err := command(t, "--pattern", "x").Run()
	if exit, ok := err.(*exec.ExitError); !ok || exit.ExitCode() != 64 {
		t.Fatalf("got %v", err)
	}
}
