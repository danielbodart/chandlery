// chandlery-notify: tell people when players join or leave a native server.
//
//	chandlery-notify --config FILE
//
// The native counterpart of loggifly's keyword labels. It follows one unit's
// journal, matches each line against the rules in order, and for every match
// runs the apprise CLI with the rule's message. The rules are loggifly's own:
// Python-style (?P<name>...) groups, which RE2 accepts, and {{ name }}
// templates in the title and message, so a compose file's labels carry over
// verbatim.
//
// It runs as its own unit, beside the game's, so a slow or failing Apprise can
// never back-pressure the game's output. The Apprise URL (a webhook, i.e. a
// secret) never touches argv: it is read from a file — by default systemd's
// credential "apprise-url" — and handed to apprise as APPRISE_URLS.
//
// FILE is JSON:
//
//	{ "unit": "chandlery-wrlin.service", "title": "WRLIN Survival",
//	  "rules": [ { "regex": "Player connected: (?P<player>.+?), xuid:", "message": "🟢 {{ player }} joined" } ],
//	  "urlFile": "",        // default $CREDENTIALS_DIRECTORY/apprise-url
//	  "apprise": "apprise", "appriseArgs": [], "journalctl": "journalctl" }
package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
)

type rule struct {
	Regex   string `json:"regex"`
	Message string `json:"message"`
	re      *regexp.Regexp
}

type config struct {
	Unit        string   `json:"unit"`
	Title       string   `json:"title"`
	Rules       []rule   `json:"rules"`
	URLFile     string   `json:"urlFile"`
	Apprise     string   `json:"apprise"`
	AppriseArgs []string `json:"appriseArgs"`
	Journalctl  string   `json:"journalctl"`
}

type notification struct{ title, body string }

func main() {
	path := flag.String("config", "", "the JSON config (see the source)")
	flag.Parse()
	if *path == "" {
		fmt.Fprintln(os.Stderr, "usage: chandlery-notify --config FILE")
		os.Exit(64)
	}
	cfg, err := load(*path)
	if err != nil {
		logf("%v", err)
		os.Exit(78)
	}
	url, err := readURL(cfg.URLFile)
	if err != nil {
		logf("%v", err)
		os.Exit(78)
	}
	if err := follow(cfg, url); err != nil {
		logf("%v", err)
		os.Exit(1)
	}
}

func load(path string) (*config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	cfg := &config{Apprise: "apprise", Journalctl: "journalctl"}
	if err := json.Unmarshal(data, cfg); err != nil {
		return nil, fmt.Errorf("%s: %v", path, err)
	}
	if cfg.Unit == "" {
		return nil, fmt.Errorf("%s: no unit", path)
	}
	for i := range cfg.Rules {
		re, err := regexp.Compile(cfg.Rules[i].Regex)
		if err != nil {
			return nil, fmt.Errorf("%s: rule %d: %v", path, i, err)
		}
		cfg.Rules[i].re = re
	}
	return cfg, nil
}

func readURL(path string) (string, error) {
	if path == "" {
		dir := os.Getenv("CREDENTIALS_DIRECTORY")
		if dir == "" {
			return "", errors.New("no urlFile and no $CREDENTIALS_DIRECTORY (LoadCredential=apprise-url:...)")
		}
		path = filepath.Join(dir, "apprise-url")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	url := strings.TrimSpace(string(data))
	if url == "" {
		return "", fmt.Errorf("%s is empty", path)
	}
	return url, nil
}

func follow(cfg *config, url string) error {
	journal := exec.Command(cfg.Journalctl, "--follow", "--lines=0", "--output=cat", "--unit="+cfg.Unit)
	journal.Stderr = os.Stderr
	out, err := journal.StdoutPipe()
	if err != nil {
		return err
	}
	if err := journal.Start(); err != nil {
		return err
	}
	logf("following %s", cfg.Unit)

	// Sending happens off the reading path: a slow Apprise queues, and a full
	// queue drops (and says so) rather than stalls the journal.
	queue := make(chan notification, 64)
	sent := make(chan struct{})
	go func() {
		for n := range queue {
			send(cfg, url, n)
		}
		close(sent)
	}()

	scan(out, cfg.Title, cfg.Rules, func(n notification) {
		select {
		case queue <- n:
		default:
			logf("dropping %q: too many notifications queued", n.body)
		}
	})
	close(queue)
	<-sent
	return fmt.Errorf("journalctl ended: %v", journal.Wait())
}

// scan calls emit for every rule that matches each line of r, in rule order.
func scan(r io.Reader, title string, rules []rule, emit func(notification)) {
	s := bufio.NewScanner(r)
	s.Buffer(make([]byte, 64*1024), 1024*1024)
	for s.Scan() {
		line := s.Text()
		for _, rl := range rules {
			if groups, ok := match(rl.re, line); ok {
				emit(notification{render(title, groups), render(rl.Message, groups)})
			}
		}
	}
}

func match(re *regexp.Regexp, line string) (map[string]string, bool) {
	m := re.FindStringSubmatch(line)
	if m == nil {
		return nil, false
	}
	groups := map[string]string{}
	for i, name := range re.SubexpNames() {
		if name != "" {
			groups[name] = m[i]
		}
	}
	return groups, true
}

var placeholder = regexp.MustCompile(`\{\{\s*(\w+)\s*\}\}`)

// render fills loggifly's {{ name }} placeholders; an unknown name renders
// empty, as it does in loggifly's templates.
func render(template string, groups map[string]string) string {
	return placeholder.ReplaceAllStringFunc(template, func(p string) string {
		return groups[placeholder.FindStringSubmatch(p)[1]]
	})
}

func send(cfg *config, url string, n notification) {
	args := append(append([]string{}, cfg.AppriseArgs...), "--title", n.title, "--body", n.body)
	cmd := exec.Command(cfg.Apprise, args...)
	cmd.Env = append(os.Environ(), "APPRISE_URLS="+url)
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		logf("apprise failed for %q: %v", n.body, err)
		return
	}
	logf("sent %q", n.body)
}

func logf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "[chandlery-notify] "+format+"\n", args...)
}
