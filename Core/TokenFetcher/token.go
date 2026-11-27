package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// tokenFile mirrors the on-disk contract with the Rust backend
// (Backend/Desktop/src/vk.rs): "Token" is read first, lowercase "token" is
// accepted as a fallback when reading an existing file.
type tokenFile struct {
	Token   string `json:"Token"`
	SavedAt string `json:"SavedAt"`
}

// buildTokenJSON renders the content of token.json. SavedAt is always UTC in
// RFC3339 form, matching the value the Rust backend writes.
func buildTokenJSON(token string, now time.Time) ([]byte, error) {
	trimmed := strings.TrimSpace(token)
	if trimmed == "" {
		return nil, fmt.Errorf("пустой токен")
	}

	payload := tokenFile{
		Token:   trimmed,
		SavedAt: now.UTC().Format(time.RFC3339),
	}
	data, err := json.MarshalIndent(payload, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("сериализация token.json: %w", err)
	}
	return append(data, '\n'), nil
}

// saveToken writes token.json to path, creating parent directories. The file
// is written through a temporary file in the same directory and renamed into
// place, so an interrupted run never leaves a half-written token.json behind.
// On Linux the file gets 0600 permissions (owner read/write only).
func saveToken(path string, token string, now time.Time) (string, error) {
	if strings.TrimSpace(path) == "" {
		return "", fmt.Errorf("пустой путь к token.json")
	}

	data, err := buildTokenJSON(token, now)
	if err != nil {
		return "", err
	}

	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", fmt.Errorf("создание каталога %s: %w", dir, err)
	}

	tmp, err := os.CreateTemp(dir, ".token-*.json")
	if err != nil {
		return "", fmt.Errorf("создание временного файла в %s: %w", dir, err)
	}
	tmpName := tmp.Name()
	// Remove the temporary file on every failure path; after a successful
	// rename this is a no-op.
	defer func() { _ = os.Remove(tmpName) }()

	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		return "", fmt.Errorf("запись token.json: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return "", fmt.Errorf("закрытие временного файла token.json: %w", err)
	}
	if err := os.Rename(tmpName, path); err != nil {
		return "", fmt.Errorf("перемещение token.json в %s: %w", path, err)
	}
	if err := os.Chmod(path, 0o600); err != nil {
		return "", fmt.Errorf("установка прав 0600 на %s: %w", path, err)
	}

	return path, nil
}
