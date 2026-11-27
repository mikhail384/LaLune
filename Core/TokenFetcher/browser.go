package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/mxschmitt/playwright-go"
)

// chromiumInstallBrowsers restricts the automatic download to Chromium; the
// default playwright-go install would also fetch Firefox and WebKit (~300 MB
// extra) that this tool never uses.
var chromiumInstallBrowsers = []string{"chromium"}

// errChromiumMissing signals that Chromium is still unavailable after the
// automatic installation attempt. Maps to exit code 4.
var errChromiumMissing = errors.New("Chromium недоступен после автоматической установки")

// chromiumExecutablePresent reports whether Playwright resolved an existing
// Chromium executable. A directory or an empty path counts as missing.
func chromiumExecutablePresent(executablePath string) bool {
	if strings.TrimSpace(executablePath) == "" {
		return false
	}
	info, err := os.Stat(executablePath)
	if err != nil {
		return false
	}
	return !info.IsDir()
}

// chromiumExecutablePath wraps BrowserType.ExecutablePath, which panics when
// the driver reports no path (e.g. an incomplete driver bundle) instead of
// returning an empty string.
func chromiumExecutablePath(pw *playwright.Playwright) (executablePath string) {
	defer func() {
		if recovered := recover(); recovered != nil {
			executablePath = ""
		}
	}()
	return pw.Chromium.ExecutablePath()
}

// ensureChromium starts Playwright and makes sure Chromium is really present,
// installing the driver and the browser when needed. Only the playwright-go
// API is used: no npm or node commands are invoked.
//
// PLAYWRIGHT_BROWSERS_PATH must already be set by the caller, because the
// driver reads it when it downloads browsers.
func ensureChromium(logf func(format string, args ...any), out io.Writer) (*playwright.Playwright, error) {
	pw, err := playwright.Run()
	if err != nil {
		// A fresh machine has no driver bundle: Run fails until Install has
		// downloaded both the driver and the browser.
		logf("[LaLune] Драйвер Playwright не установлен: %v", err)
		if installErr := installChromium(logf, out); installErr != nil {
			return nil, fmt.Errorf("установка Playwright (драйвер и Chromium): %w", installErr)
		}
		pw, err = playwright.Run()
		if err != nil {
			return nil, fmt.Errorf("запуск Playwright после установки: %w", err)
		}
		if !chromiumExecutablePresent(chromiumExecutablePath(pw)) {
			_ = pw.Stop()
			return nil, fmt.Errorf("%w: исполняемый файл Chromium не найден после установки", errChromiumMissing)
		}
		logf("[LaLune] Playwright Chromium установлен.")
		return pw, nil
	}

	if chromiumExecutablePresent(chromiumExecutablePath(pw)) {
		logf("[LaLune] Playwright Chromium найден.")
		return pw, nil
	}

	if err := installChromium(logf, out); err != nil {
		_ = pw.Stop()
		return nil, fmt.Errorf("установка Chromium: %w", err)
	}
	if !chromiumExecutablePresent(chromiumExecutablePath(pw)) {
		_ = pw.Stop()
		return nil, fmt.Errorf("%w: исполняемый файл Chromium не найден после установки", errChromiumMissing)
	}

	logf("[LaLune] Playwright Chromium установлен.")
	return pw, nil
}

// installChromium downloads the driver and the Chromium build through the
// playwright-go installer.
func installChromium(logf func(format string, args ...any), out io.Writer) error {
	logf("[LaLune] Playwright Chromium не найден. Устанавливаю автоматически...")
	err := playwright.Install(&playwright.RunOptions{
		Browsers: chromiumInstallBrowsers,
		Stdout:   out,
		Stderr:   out,
	})
	if err != nil {
		return fmt.Errorf("playwright install chromium: %w", err)
	}
	return nil
}
