package main

import (
	"fmt"
	"os"
	"path"
	"runtime"
	"strings"
)

// Layout of the LaLune application directory shared with the Rust backend
// (Backend/Desktop/src/state.rs):
//
//	<appDir>                                  token.json
//	<appDir>/vk-token-fetcher/userdata        persistent Chromium profile
//	<appDir>/vk-token-fetcher/browsers        Playwright browser cache
const (
	appDirName      = ".la-lune"
	tokenFileName   = "token.json"
	fetcherDirName  = "vk-token-fetcher"
	userDataDirName = "userdata"
	browsersDirName = "browsers"
)

// pathEnv carries the OS-specific values that path resolution depends on.
// Keeping them explicit makes the resolution testable on any host.
type pathEnv struct {
	// GOOS is the target operating system, e.g. "windows" or "linux".
	GOOS string
	// AppData is %APPDATA% (Windows only).
	AppData string
	// Home is the user profile directory (%USERPROFILE% on Windows, $HOME elsewhere).
	Home string
}

// currentPathEnv reads the values of the running process.
func currentPathEnv() pathEnv {
	env := pathEnv{GOOS: runtime.GOOS, AppData: os.Getenv("APPDATA")}
	if runtime.GOOS == "windows" {
		env.Home = os.Getenv("USERPROFILE")
	} else {
		env.Home = os.Getenv("HOME")
	}
	return env
}

// joinFor joins path elements with the separator of the target OS, so path
// resolution can be verified for Windows while tests run on Linux.
func joinFor(goos string, elems ...string) string {
	joined := path.Join(elems...)
	if goos == "windows" {
		return strings.ReplaceAll(joined, "/", `\`)
	}
	return joined
}

// appDir returns the LaLune application directory:
// %APPDATA%\.la-lune on Windows, ~/.la-lune elsewhere.
func (env pathEnv) appDir() (string, error) {
	if env.GOOS == "windows" {
		if strings.TrimSpace(env.AppData) != "" {
			return joinFor(env.GOOS, env.AppData, appDirName), nil
		}
		if strings.TrimSpace(env.Home) != "" {
			return joinFor(env.GOOS, env.Home, appDirName), nil
		}
		return "", fmt.Errorf("не удалось определить каталог приложения: переменные APPDATA и USERPROFILE не заданы")
	}

	if strings.TrimSpace(env.Home) == "" {
		return "", fmt.Errorf("не удалось определить каталог приложения: переменная HOME не задана")
	}
	return joinFor(env.GOOS, env.Home, appDirName), nil
}

// defaultTokenPath returns <appDir>/token.json.
func (env pathEnv) defaultTokenPath() (string, error) {
	dir, err := env.appDir()
	if err != nil {
		return "", err
	}
	return joinFor(env.GOOS, dir, tokenFileName), nil
}

// defaultUserDataDir returns <appDir>/vk-token-fetcher/userdata.
func (env pathEnv) defaultUserDataDir() (string, error) {
	dir, err := env.appDir()
	if err != nil {
		return "", err
	}
	return joinFor(env.GOOS, dir, fetcherDirName, userDataDirName), nil
}

// defaultBrowsersPath returns <appDir>/vk-token-fetcher/browsers.
func (env pathEnv) defaultBrowsersPath() (string, error) {
	dir, err := env.appDir()
	if err != nil {
		return "", err
	}
	return joinFor(env.GOOS, dir, fetcherDirName, browsersDirName), nil
}

// ensureDir creates dir (and its parents) if needed.
func ensureDir(dir string) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("создание каталога %s: %w", dir, err)
	}
	return nil
}
