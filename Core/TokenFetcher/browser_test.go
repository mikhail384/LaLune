package main

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/mxschmitt/playwright-go"
)

func TestChromiumExecutablePresent(t *testing.T) {
	dir := t.TempDir()

	executable := filepath.Join(dir, "chrome")
	if err := os.WriteFile(executable, []byte("binary"), 0o755); err != nil {
		t.Fatalf("preparing fake Chromium executable: %v", err)
	}
	subdir := filepath.Join(dir, "profile")
	if err := os.Mkdir(subdir, 0o755); err != nil {
		t.Fatalf("preparing directory: %v", err)
	}

	tests := []struct {
		name string
		path string
		want bool
	}{
		{name: "existing file", path: executable, want: true},
		{name: "empty path", path: "", want: false},
		{name: "blank path", path: "   ", want: false},
		{name: "missing file", path: filepath.Join(dir, "absent"), want: false},
		{name: "directory", path: subdir, want: false},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := chromiumExecutablePresent(test.path); got != test.want {
				t.Fatalf("chromiumExecutablePresent(%q) = %v, want %v", test.path, got, test.want)
			}
		})
	}
}

func TestChromiumExecutablePathIsPanicSafe(t *testing.T) {
	// The playwright-go driver panics when no executable path was reported
	// (e.g. a broken driver bundle); ensureChromium must not crash on that.
	if got := chromiumExecutablePath(&playwright.Playwright{}); got != "" {
		t.Fatalf("chromiumExecutablePath() = %q, want an empty path", got)
	}
}
