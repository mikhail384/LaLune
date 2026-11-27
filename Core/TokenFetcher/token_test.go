package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

func TestBuildTokenJSONFormat(t *testing.T) {
	now := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)

	data, err := buildTokenJSON("  abc123  ", now)
	if err != nil {
		t.Fatalf("buildTokenJSON() error: %v", err)
	}

	var payload map[string]any
	if err := json.Unmarshal(data, &payload); err != nil {
		t.Fatalf("token.json is not valid JSON: %v", err)
	}

	if got := payload["Token"]; got != "abc123" {
		t.Fatalf(`payload["Token"] = %v, want "abc123" (token must be trimmed)`, got)
	}
	if _, ok := payload["token"]; ok {
		t.Fatal(`payload contains lowercase "token"; the Rust backend expects the capitalized key`)
	}
	if got := payload["SavedAt"]; got != "2026-01-02T03:04:05Z" {
		t.Fatalf(`payload["SavedAt"] = %v, want RFC3339 UTC timestamp`, got)
	}
	if _, err := time.Parse(time.RFC3339, payload["SavedAt"].(string)); err != nil {
		t.Fatalf("SavedAt is not RFC3339: %v", err)
	}
	if !strings.HasSuffix(string(data), "\n") {
		t.Fatal("token.json should end with a newline")
	}
}

func TestBuildTokenJSONRejectsEmptyToken(t *testing.T) {
	if _, err := buildTokenJSON("   ", time.Now()); err == nil {
		t.Fatal("buildTokenJSON() error = nil, want an error for an empty token")
	}
}

func TestSaveTokenCreatesDirectoryAndFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "nested", "appdir", "token.json")

	savedPath, err := saveToken(path, "token-value", time.Now())
	if err != nil {
		t.Fatalf("saveToken() error: %v", err)
	}
	if savedPath != path {
		t.Fatalf("saveToken() = %q, want %q", savedPath, path)
	}

	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("token.json was not created: %v", err)
	}
	if runtime.GOOS != "windows" {
		if got, want := info.Mode().Perm(), os.FileMode(0o600); got != want {
			t.Fatalf("token.json permissions = %o, want %o", got, want)
		}
	}

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("reading token.json: %v", err)
	}
	if !strings.Contains(string(data), `"Token": "token-value"`) {
		t.Fatalf("token.json content = %s, want the capitalized Token key", data)
	}
}

func TestSaveTokenOverwritesExistingFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "token.json")
	if err := os.WriteFile(path, []byte(`{"Token":"old"}`), 0o644); err != nil {
		t.Fatalf("preparing token.json: %v", err)
	}

	if _, err := saveToken(path, "new-token", time.Now()); err != nil {
		t.Fatalf("saveToken() error: %v", err)
	}

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("reading token.json: %v", err)
	}
	if strings.Contains(string(data), "old") {
		t.Fatalf("token.json still contains the old token: %s", data)
	}
	if !strings.Contains(string(data), `"Token": "new-token"`) {
		t.Fatalf("token.json = %s, want the new token", data)
	}
}

func TestSaveTokenRejectsEmptyPath(t *testing.T) {
	if _, err := saveToken("", "token", time.Now()); err == nil {
		t.Fatal("saveToken() error = nil, want an error for an empty path")
	}
}
