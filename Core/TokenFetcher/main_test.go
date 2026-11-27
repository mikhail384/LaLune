package main

import (
	"bytes"
	"errors"
	"flag"
	"strings"
	"testing"
	"time"
)

func TestParseFlagsDefaults(t *testing.T) {
	var out bytes.Buffer
	opts, err := parseFlags(nil, &out, pathEnv{GOOS: "linux", Home: "/home/user"})
	if err != nil {
		t.Fatalf("parseFlags() error: %v", err)
	}
	if opts.tokenPath != "" || opts.userDataDir != "" || opts.browsersPath != "" {
		t.Fatalf("default path flags must stay empty so they can be resolved from the OS: %+v", opts)
	}
	if opts.timeout != defaultTimeout {
		t.Fatalf("default timeout = %v, want %v", opts.timeout, defaultTimeout)
	}
	if opts.headless {
		t.Fatal("headless must default to false: VK login needs a visible browser")
	}
}

func TestParseFlagsOverrides(t *testing.T) {
	var out bytes.Buffer
	args := []string{
		"--token-path", "/tmp/token.json",
		"--user-data-dir", "/tmp/userdata",
		"--browsers-path", "/tmp/browsers",
		"--timeout", "90s",
		"--headless",
	}

	opts, err := parseFlags(args, &out, pathEnv{GOOS: "linux", Home: "/home/user"})
	if err != nil {
		t.Fatalf("parseFlags() error: %v", err)
	}
	if opts.tokenPath != "/tmp/token.json" {
		t.Fatalf("tokenPath = %q", opts.tokenPath)
	}
	if opts.userDataDir != "/tmp/userdata" {
		t.Fatalf("userDataDir = %q", opts.userDataDir)
	}
	if opts.browsersPath != "/tmp/browsers" {
		t.Fatalf("browsersPath = %q", opts.browsersPath)
	}
	if opts.timeout != 90*time.Second {
		t.Fatalf("timeout = %v, want 90s", opts.timeout)
	}
	if !opts.headless {
		t.Fatal("headless = false, want true")
	}
}

func TestParseFlagsHelp(t *testing.T) {
	var out bytes.Buffer
	_, err := parseFlags([]string{"--help"}, &out, pathEnv{GOOS: "linux", Home: "/home/user"})
	if !errors.Is(err, flag.ErrHelp) {
		t.Fatalf("parseFlags(--help) error = %v, want flag.ErrHelp", err)
	}
	help := out.String()
	for _, flagName := range []string{"--token-path", "--user-data-dir", "--browsers-path", "--timeout", "--headless"} {
		if !strings.Contains(help, flagName) {
			t.Fatalf("help output does not mention %s:\n%s", flagName, help)
		}
	}
}

func TestParseFlagsRejectsBadValues(t *testing.T) {
	var out bytes.Buffer

	if _, err := parseFlags([]string{"--timeout", "0s"}, &out, pathEnv{GOOS: "linux", Home: "/home/user"}); err == nil {
		t.Fatal("parseFlags(--timeout 0s) error = nil, want an error")
	}
	if _, err := parseFlags([]string{"positional"}, &out, pathEnv{GOOS: "linux", Home: "/home/user"}); err == nil {
		t.Fatal("parseFlags(positional) error = nil, want an error")
	}
	if _, err := parseFlags([]string{"--unknown"}, &out, pathEnv{GOOS: "linux", Home: "/home/user"}); err == nil {
		t.Fatal("parseFlags(--unknown) error = nil, want an error")
	}
}

func TestResolvePathsUsesEnvironmentDefaults(t *testing.T) {
	opts := options{timeout: defaultTimeout}
	env := pathEnv{GOOS: "linux", Home: "/home/user"}

	if err := resolvePaths(&opts, env); err != nil {
		t.Fatalf("resolvePaths() error: %v", err)
	}
	if want := "/home/user/.la-lune/token.json"; opts.tokenPath != want {
		t.Fatalf("tokenPath = %q, want %q", opts.tokenPath, want)
	}
	if want := "/home/user/.la-lune/vk-token-fetcher/userdata"; opts.userDataDir != want {
		t.Fatalf("userDataDir = %q, want %q", opts.userDataDir, want)
	}
	if want := "/home/user/.la-lune/vk-token-fetcher/browsers"; opts.browsersPath != want {
		t.Fatalf("browsersPath = %q, want %q", opts.browsersPath, want)
	}
}

func TestResolvePathsKeepsExplicitValues(t *testing.T) {
	opts := options{
		tokenPath:    "/custom/token.json",
		userDataDir:  "/custom/userdata",
		browsersPath: "/custom/browsers",
		timeout:      defaultTimeout,
	}

	if err := resolvePaths(&opts, pathEnv{GOOS: "linux", Home: "/home/user"}); err != nil {
		t.Fatalf("resolvePaths() error: %v", err)
	}
	if opts.tokenPath != "/custom/token.json" || opts.userDataDir != "/custom/userdata" || opts.browsersPath != "/custom/browsers" {
		t.Fatalf("explicit paths were overwritten: %+v", opts)
	}
}
