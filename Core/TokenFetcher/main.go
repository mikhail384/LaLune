package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

// Exit codes shared with the launcher and the Rust backend.
const (
	exitOK               = 0
	exitError            = 1
	exitTokenNotReceived = 3
	exitChromiumMissing  = 4
)

// chromiumMissingMarker is grepped by older launcher versions to tell "browser
// could not be installed" apart from generic failures.
const chromiumMissingMarker = "LALUNE_CHROMIUM_MISSING"

// defaultTimeout is the overall time budget for the OAuth flow.
const defaultTimeout = 5 * time.Minute

// options holds the parsed command line.
type options struct {
	tokenPath    string
	userDataDir  string
	browsersPath string
	timeout      time.Duration
	headless     bool
}

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

// run executes the fetcher and returns the process exit code.
func run(args []string, stdout, stderr io.Writer) int {
	env := currentPathEnv()

	opts, err := parseFlags(args, stdout, env)
	if err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return exitOK
		}
		fmt.Fprintf(stderr, "[LaLune] Ошибка аргументов: %v\n", err)
		return exitError
	}

	if err := resolvePaths(&opts, env); err != nil {
		fmt.Fprintf(stderr, "[LaLune] %v\n", err)
		return exitError
	}

	// Must be set before the first playwright call: the driver reads it both
	// when it installs browsers and when it resolves the Chromium executable.
	if err := os.Setenv("PLAYWRIGHT_BROWSERS_PATH", opts.browsersPath); err != nil {
		fmt.Fprintf(stderr, "[LaLune] Не удалось задать PLAYWRIGHT_BROWSERS_PATH: %v\n", err)
		return exitError
	}

	logf := func(format string, args ...any) {
		fmt.Fprintf(stdout, format+"\n", args...)
	}
	logf("[LaLune] Браузеры Playwright: %s", opts.browsersPath)

	pw, err := ensureChromium(logf, stdout)
	if err != nil {
		fmt.Fprintf(stderr, "[LaLune] %s: %v\n", chromiumMissingMarker, err)
		return exitChromiumMissing
	}
	defer func() {
		if stopErr := pw.Stop(); stopErr != nil {
			fmt.Fprintf(stderr, "[LaLune] Предупреждение: остановка Playwright: %v\n", stopErr)
		}
	}()

	ctx, cancel := context.WithTimeout(context.Background(), opts.timeout)
	defer cancel()
	ctx, stopSignals := signal.NotifyContext(ctx, os.Interrupt, syscall.SIGTERM)
	defer stopSignals()

	token, err := fetchToken(ctx, pw, opts.userDataDir, opts.headless, logf)
	if err != nil {
		if errors.Is(err, errTokenNotReceived) {
			fmt.Fprintln(stderr, "[LaLune] Токен не получен (тайм-аут, отмена, ошибка VK или silent_token без access_token).")
			return exitTokenNotReceived
		}
		fmt.Fprintf(stderr, "[LaLune] Ошибка получения токена: %v\n", err)
		return exitError
	}
	if strings.TrimSpace(token) == "" {
		fmt.Fprintln(stderr, "[LaLune] Токен не получен: VK вернул пустой access_token.")
		return exitTokenNotReceived
	}

	savedPath, err := saveToken(opts.tokenPath, token, time.Now())
	if err != nil {
		fmt.Fprintf(stderr, "[LaLune] Не удалось сохранить token.json: %v\n", err)
		return exitError
	}
	logf("[LaLune] Токен сохранён: %s", savedPath)
	return exitOK
}

// parseFlags parses the command line. --help is reported as flag.ErrHelp after
// the usage text has been printed to out.
func parseFlags(args []string, out io.Writer, env pathEnv) (options, error) {
	fs := flag.NewFlagSet("token-fetcher", flag.ContinueOnError)
	fs.SetOutput(out)
	fs.Usage = func() {
		fmt.Fprint(out, helpText(env))
	}

	var opts options
	fs.StringVar(&opts.tokenPath, "token-path", "", "куда записать token.json")
	fs.StringVar(&opts.userDataDir, "user-data-dir", "", "каталог профиля Chromium")
	fs.StringVar(&opts.browsersPath, "browsers-path", "", "каталог для браузеров Playwright")
	fs.DurationVar(&opts.timeout, "timeout", defaultTimeout, "общий таймаут ожидания токена")
	fs.BoolVar(&opts.headless, "headless", false, "запускать Chromium без окна")

	if err := fs.Parse(args); err != nil {
		return options{}, err
	}
	if fs.NArg() > 0 {
		return options{}, fmt.Errorf("неизвестные аргументы: %s", strings.Join(fs.Args(), " "))
	}
	if opts.timeout <= 0 {
		return options{}, fmt.Errorf("--timeout должен быть больше нуля")
	}
	return opts, nil
}

// resolvePaths fills unset flags with the defaults derived from env.
func resolvePaths(opts *options, env pathEnv) error {
	if opts.tokenPath == "" {
		resolved, err := env.defaultTokenPath()
		if err != nil {
			return err
		}
		opts.tokenPath = resolved
	}
	if opts.userDataDir == "" {
		resolved, err := env.defaultUserDataDir()
		if err != nil {
			return err
		}
		opts.userDataDir = resolved
	}
	if opts.browsersPath == "" {
		resolved, err := env.defaultBrowsersPath()
		if err != nil {
			return err
		}
		opts.browsersPath = resolved
	}

	opts.tokenPath = filepath.Clean(opts.tokenPath)
	opts.userDataDir = filepath.Clean(opts.userDataDir)
	opts.browsersPath = filepath.Clean(opts.browsersPath)
	return nil
}

// helpText renders the --help output with the defaults of the current machine.
func helpText(env pathEnv) string {
	tokenPath := "<appDir>/token.json"
	if resolved, err := env.defaultTokenPath(); err == nil {
		tokenPath = resolved
	}
	userDataDir := "<appDir>/vk-token-fetcher/userdata"
	if resolved, err := env.defaultUserDataDir(); err == nil {
		userDataDir = resolved
	}
	browsersPath := "<appDir>/vk-token-fetcher/browsers"
	if resolved, err := env.defaultBrowsersPath(); err == nil {
		browsersPath = resolved
	}

	return fmt.Sprintf(`LaLuneTokenFetcher — получает VK access_token через Playwright (Chromium).

Использование:
  token-fetcher [флаги]

Флаги:
  --token-path <файл>        куда записать token.json
                             (по умолчанию %s)
  --user-data-dir <каталог>  профиль Chromium; cookies сохраняются между
                             запусками (по умолчанию %s)
  --browsers-path <каталог>  каталог браузеров Playwright, выставляется в
                             PLAYWRIGHT_BROWSERS_PATH (по умолчанию %s)
  --timeout <длительность>   общий таймаут ожидания токена (по умолчанию %s)
  --headless                 запустить Chromium без окна; по умолчанию
                             выключено, потому что для входа нужен видимый
                             браузер
  -h, --help                 показать эту справку

Коды возврата:
  0 — токен получен и сохранён
  3 — токен не получен (тайм-аут, отказ VK, silent_token без access_token)
  4 — Chromium не удалось установить (%s)
  1 — прочая ошибка

Если Chromium отсутствует, он скачивается автоматически при первом запуске.
Профиль Chromium сохраняется в --user-data-dir, поэтому при повторных запусках
VK сразу предлагает «Продолжить как ...» и токен получается без пароля.
`, tokenPath, userDataDir, browsersPath, defaultTimeout, chromiumMissingMarker)
}
