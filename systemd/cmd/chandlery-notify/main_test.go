package main

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// loggifly's rules, verbatim from the compose labels they replace.
var bedrock = []rule{
	{Regex: `Player connected: (?P<player>.+?), xuid:`, Message: "🟢 {{ player }} joined"},
	{Regex: `Player disconnected: (?P<player>.+?), xuid:`, Message: "🔴 {{ player }} left"},
}

var hytale = []rule{
	{Regex: `Player '(?P<player>[^']+)' joined world`, Message: "🟢 {{ player }} joined"},
	{Regex: `\[Universe\|P\] Removing player '(?P<player>[^']+)'`, Message: "🔴 {{ player }} left"},
}

func compiled(t *testing.T, rules []rule) []rule {
	t.Helper()
	out := make([]rule, len(rules))
	for i, r := range rules {
		r.re = regexp.MustCompile(r.Regex)
		out[i] = r
	}
	return out
}

func collect(t *testing.T, log string, title string, rules []rule) []notification {
	t.Helper()
	var got []notification
	scan(strings.NewReader(log), title, compiled(t, rules), func(n notification) { got = append(got, n) })
	return got
}

func TestBedrockJoinAndLeave(t *testing.T) {
	log := strings.Join([]string{
		"[2026-10-01 18:00:00:001 INFO] Server started.",
		"[2026-10-01 18:01:02:345 INFO] Player connected: Steve The Great, xuid: 2535412345678901",
		"[2026-10-01 18:01:05:000 INFO] Player Spawned: Steve The Great xuid: 2535412345678901, pfid: abc",
		"[2026-10-01 18:30:00:000 INFO] Player disconnected: Steve The Great, xuid: 2535412345678901, pfid: abc",
	}, "\n")
	got := collect(t, log, "WRLIN Survival", bedrock)
	want := []notification{
		{"WRLIN Survival", "🟢 Steve The Great joined"},
		{"WRLIN Survival", "🔴 Steve The Great left"},
	}
	if len(got) != len(want) || got[0] != want[0] || got[1] != want[1] {
		t.Fatalf("got %q, want %q", got, want)
	}
}

func TestHytaleJoinAndLeave(t *testing.T) {
	log := strings.Join([]string{
		"[2026/10/01 18:01:02   INFO]   [World|default] Player 'Dan' joined world 'default' at location Vector3d{x=1, y=2, z=3}",
		"[2026/10/01 18:20:00   INFO]   [PlayerSystems] Removing player 'Dan' from world 'default'",
		"[2026/10/01 18:20:00   INFO]   [Universe|P] Removing player 'Dan' (0e2f-uuid)",
	}, "\n")
	got := collect(t, log, "Hytale Eldermarch", hytale)
	if len(got) != 2 || got[0].body != "🟢 Dan joined" || got[1].body != "🔴 Dan left" {
		t.Fatalf("got %q", got)
	}
}

func TestRenderFillsLoggiflysPlaceholders(t *testing.T) {
	groups := map[string]string{"player": "Alex"}
	for template, want := range map[string]string{
		"{{ player }} joined":           "Alex joined",
		"{{player}} joined":             "Alex joined",
		"{{ nobody }}!":                 "!",
		"no placeholders":               "no placeholders",
		"{{ player }} and {{ player }}": "Alex and Alex",
	} {
		if got := render(template, groups); got != want {
			t.Errorf("render(%q) = %q, want %q", template, got, want)
		}
	}
}

func TestTitleIsATemplateToo(t *testing.T) {
	got := collect(t, "Player connected: Alex, xuid: 1", "{{ player }} on WRLIN", bedrock)
	if len(got) != 1 || got[0].title != "Alex on WRLIN" {
		t.Fatalf("got %q", got)
	}
}

// End to end through the real follow(): a fake journalctl and a fake apprise
// that records its argv and the URL it was given.
func TestSendsThroughAppriseWithTheURLOutOfArgv(t *testing.T) {
	dir := t.TempDir()
	journal := filepath.Join(dir, "journalctl")
	apprise := filepath.Join(dir, "apprise")
	record := filepath.Join(dir, "record")
	os.WriteFile(journal, []byte("#!/bin/sh\necho \"$*\" > "+record+".journal\nprintf '%s\\n' 'nothing' 'Player connected: Alex, xuid: 1'\n"), 0o755)
	os.WriteFile(apprise, []byte("#!/bin/sh\n{ echo \"argv: $*\"; echo \"url: $APPRISE_URLS\"; } >> "+record+"\n"), 0o755)
	urlFile := filepath.Join(dir, "url")
	os.WriteFile(urlFile, []byte("json://secret.example/hook\n"), 0o600)

	cfg := &config{Unit: "chandlery-wrlin.service", Title: "WRLIN", Rules: compiled(t, bedrock),
		URLFile: urlFile, Apprise: apprise, AppriseArgs: []string{"--storage-mode=memory"}, Journalctl: journal}
	url, err := readURL(cfg.URLFile)
	if err != nil {
		t.Fatal(err)
	}
	follow(cfg, url)

	got, _ := os.ReadFile(record)
	want := "argv: --storage-mode=memory --title WRLIN --body 🟢 Alex joined\nurl: json://secret.example/hook\n"
	if string(got) != want {
		t.Fatalf("got %q, want %q", got, want)
	}
	args, _ := os.ReadFile(record + ".journal")
	if string(args) != "--follow --lines=0 --output=cat --unit=chandlery-wrlin.service\n" {
		t.Fatalf("journalctl got %q", args)
	}
}

func TestReadsTheCredentialByDefault(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "apprise-url"), []byte("discord://x/y\n"), 0o600)
	t.Setenv("CREDENTIALS_DIRECTORY", dir)
	if url, err := readURL(""); err != nil || url != "discord://x/y" {
		t.Fatalf("got %q, %v", url, err)
	}
	t.Setenv("CREDENTIALS_DIRECTORY", "")
	if _, err := readURL(""); err == nil {
		t.Fatal("no credential and no file should be an error")
	}
}

func TestLoadRejectsABadRegex(t *testing.T) {
	path := filepath.Join(t.TempDir(), "c.json")
	os.WriteFile(path, []byte(`{"unit":"u","rules":[{"regex":"(","message":"m"}]}`), 0o644)
	if _, err := load(path); err == nil {
		t.Fatal("want an error")
	}
}
