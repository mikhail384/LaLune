package main

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"regexp"
	"strings"
	"time"

	"github.com/mxschmitt/playwright-go"
)

// VK OAuth configuration. These values match the Flutter client and the
// retired .NET fetcher: client_id 7793118 is the official VK Android app, the
// only app id for which VK allows the implicit flow on this redirect URI.
const (
	vkAuthURL = "https://oauth.vk.ru/authorize?" +
		"client_id=7793118&" +
		"scope=1073737727&" +
		"redirect_uri=https%3A%2F%2Foauth.vk.ru%2Fblank.html&" +
		"display=page&" +
		"response_type=token&" +
		"revoke=1&" +
		"v=5.199"
	vkHomeURL = "https://vk.com/"
	blankPath = "/blank.html"
)

// Timing constants mirror the .NET implementation.
const (
	// pollInterval is how often page.URL() is checked while waiting for the
	// OAuth redirect.
	pollInterval = 3 * time.Second
	// vkHomeWait is how long vk.com is kept open so VK can set the session
	// cookie after a silent_token response.
	vkHomeWait = 2 * time.Second
	// maxSilentRestarts is the number of extra OAuth passes allowed after a
	// silent_token response (one restart, two passes in total).
	maxSilentRestarts = 1
	// vkHomeTimeout bounds the navigation to vk.com after a silent_token.
	vkHomeTimeout = 30 * time.Second
)

// blankHosts are the hosts VK redirects to after a successful login.
var blankHosts = map[string]struct{}{
	"oauth.vk.ru":  {},
	"oauth.vk.com": {},
}

// errTokenNotReceived means the token could not be obtained: timeout, an OAuth
// error, or a silent_token that could not be exchanged. Maps to exit code 3.
var errTokenNotReceived = errors.New("токен не получен")

// redirectKind classifies what a blank.html redirect contains.
type redirectKind int

const (
	// redirectNone means the URL is not an interesting blank.html redirect yet.
	redirectNone redirectKind = iota
	// redirectAccessToken means the fragment carries a real access_token.
	redirectAccessToken
	// redirectSilentToken means the fragment carries payload=...type=silent_token.
	redirectSilentToken
	// redirectOAuthError means the fragment carries error=...
	redirectOAuthError
)

// redirectResult is the outcome of inspecting one URL.
type redirectResult struct {
	kind  redirectKind
	token string
}

// silentTypeRe matches the silent_token marker inside a URL-decoded fragment,
// e.g. payload={"type":"silent_token",...}. The character class tolerates the
// quoting/escaping variants VK has produced over time, like the .NET regex.
var silentTypeRe = regexp.MustCompile(`(?i)type[\\"':=\s]*silent_token`)

// isBlankRedirect reports whether rawURL points at the VK OAuth blank page on
// one of the two known hosts.
func isBlankRedirect(rawURL string) bool {
	if strings.TrimSpace(rawURL) == "" {
		return false
	}
	parsed, err := url.Parse(rawURL)
	if err != nil || parsed.Host == "" {
		return false
	}
	if _, ok := blankHosts[strings.ToLower(parsed.Hostname())]; !ok {
		return false
	}
	return strings.EqualFold(parsed.Path, blankPath)
}

// extractFragment returns the URL-decoded fragment of rawURL, falling back to
// its query string. VK delivers the token in the fragment (#access_token=...);
// the query fallback keeps behaviour identical to the .NET parser.
func extractFragment(rawURL string) string {
	if _, fragment, ok := strings.Cut(rawURL, "#"); ok {
		return decodeFragment(fragment)
	}
	if _, query, ok := strings.Cut(rawURL, "?"); ok {
		return decodeFragment(query)
	}
	return ""
}

// decodeFragment decodes percent-escapes without turning '+' into a space, so
// token characters survive unchanged (the Go analogue of Uri.UnescapeDataString).
func decodeFragment(raw string) string {
	decoded, err := url.PathUnescape(raw)
	if err != nil {
		return raw
	}
	return decoded
}

// fragmentParam returns the value of key in an already decoded fragment or
// query string ("a=1&b=2").
func fragmentParam(fragment, key string) string {
	for _, pair := range strings.Split(fragment, "&") {
		name, value, ok := strings.Cut(pair, "=")
		if !ok || name != key {
			continue
		}
		return value
	}
	return ""
}

// isSilentTokenFragment reports whether the decoded fragment carries a
// payload whose JSON contains type=silent_token.
func isSilentTokenFragment(fragment string) bool {
	if !strings.Contains(fragment, "payload=") {
		return false
	}
	return silentTypeRe.MatchString(fragment)
}

// parseRedirect inspects a page URL and classifies the redirect. Access tokens
// take precedence over silent tokens, which take precedence over OAuth errors.
func parseRedirect(rawURL string) redirectResult {
	if !isBlankRedirect(rawURL) {
		return redirectResult{kind: redirectNone}
	}

	fragment := extractFragment(rawURL)
	if fragment == "" {
		return redirectResult{kind: redirectNone}
	}

	if token := fragmentParam(fragment, "access_token"); token != "" {
		return redirectResult{kind: redirectAccessToken, token: token}
	}
	if isSilentTokenFragment(fragment) {
		return redirectResult{kind: redirectSilentToken}
	}
	if strings.Contains(fragment, "error=") {
		return redirectResult{kind: redirectOAuthError}
	}
	return redirectResult{kind: redirectNone}
}

// fetchToken opens a persistent Chromium profile, walks the VK OAuth flow and
// returns a real access token. A silent_token response triggers one extra pass
// through vk.com, after which VK usually offers "Continue as <name>" and hands
// out a real token. The whole flow is bounded by ctx.
func fetchToken(
	ctx context.Context,
	pw *playwright.Playwright,
	userDataDir string,
	headless bool,
	logf func(format string, args ...any),
) (string, error) {
	if err := ensureDir(userDataDir); err != nil {
		return "", err
	}
	logf("[LaLune] Профиль Chromium: %s", userDataDir)

	// Persistent context: cookies and localStorage are stored in userDataDir,
	// so the second run usually returns a token without a password prompt.
	context, err := pw.Chromium.LaunchPersistentContext(userDataDir,
		playwright.BrowserTypeLaunchPersistentContextOptions{
			Headless:   playwright.Bool(headless),
			Args:       []string{"--disable-blink-features=AutomationControlled"},
			Locale:     playwright.String("ru-RU"),
			TimezoneId: playwright.String("Europe/Moscow"),
		})
	if err != nil {
		return "", fmt.Errorf("запуск Chromium с профилем %s: %w", userDataDir, err)
	}
	defer func() {
		if closeErr := context.Close(); closeErr != nil {
			logf("[LaLune] Предупреждение: не удалось закрыть Chromium: %v", closeErr)
		}
	}()

	var page playwright.Page
	if pages := context.Pages(); len(pages) > 0 {
		page = pages[0]
	} else {
		page, err = context.NewPage()
		if err != nil {
			return "", fmt.Errorf("создание вкладки Chromium: %w", err)
		}
	}

	silentRestarts := 0
	for {
		if ctx.Err() != nil {
			return "", errTokenNotReceived
		}

		if err := navigate(ctx, page, vkAuthURL, 0); err != nil {
			return "", err
		}
		logf("[LaLune] Ожидаю авторизацию VK в открытом окне браузера...")

		result, err := waitForRedirect(ctx, page)
		if err != nil {
			return "", err
		}

		switch result.kind {
		case redirectAccessToken:
			return result.token, nil

		case redirectSilentToken:
			if silentRestarts >= maxSilentRestarts {
				logf("[LaLune] VK повторно вернул silent_token вместо access_token.")
				return "", errTokenNotReceived
			}
			silentRestarts++
			logf("[LaLune] VK вернул silent_token. Открываю vk.com, чтобы активировать сессию...")

			if err := navigate(ctx, page, vkHomeURL, vkHomeTimeout); err != nil {
				return "", err
			}
			if !sleepCtx(ctx, vkHomeWait) {
				return "", errTokenNotReceived
			}
			logf("[LaLune] Повторяю авторизацию VK (проход %d из 2)...", silentRestarts+1)

		case redirectOAuthError:
			return "", errTokenNotReceived

		default:
			// waitForRedirect only returns without an error once it has a
			// classified redirect, so this is unreachable in practice.
			return "", errTokenNotReceived
		}
	}
}

// waitForRedirect polls page.URL() every pollInterval until it recognises a
// blank.html redirect or ctx is done.
func waitForRedirect(ctx context.Context, page playwright.Page) (redirectResult, error) {
	for {
		if result := parseRedirect(page.URL()); result.kind != redirectNone {
			return result, nil
		}
		if !sleepCtx(ctx, pollInterval) {
			return redirectResult{kind: redirectNone}, errTokenNotReceived
		}
	}
}

// navigate opens rawURL and waits for DOMContentLoaded. The navigation timeout
// is the remaining context budget, optionally capped by maxTimeout (0 = no cap).
func navigate(ctx context.Context, page playwright.Page, rawURL string, maxTimeout time.Duration) error {
	options := playwright.PageGotoOptions{WaitUntil: playwright.WaitUntilStateDomcontentloaded}

	timeoutMs, hasDeadline := remainingMillis(ctx)
	if !hasDeadline {
		// No deadline: playwright's own default applies unless a cap is set.
		if maxTimeout > 0 {
			timeoutMs = float64(maxTimeout.Milliseconds())
		}
	} else {
		if timeoutMs < 1000 {
			timeoutMs = 1000
		}
		if capMs := float64(maxTimeout.Milliseconds()); maxTimeout > 0 && timeoutMs > capMs {
			timeoutMs = capMs
		}
	}
	if timeoutMs > 0 {
		options.Timeout = playwright.Float(timeoutMs)
	}

	if _, err := page.Goto(rawURL, options); err != nil {
		if ctx.Err() != nil {
			return errTokenNotReceived
		}
		return fmt.Errorf("переход на %s: %w", rawURL, err)
	}
	return nil
}

// sleepCtx sleeps for d and reports false when ctx was cancelled first.
func sleepCtx(ctx context.Context, d time.Duration) bool {
	timer := time.NewTimer(d)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}

// remainingMillis returns the time left until the context deadline in
// milliseconds. ok is false when the context has no deadline.
func remainingMillis(ctx context.Context) (float64, bool) {
	deadline, ok := ctx.Deadline()
	if !ok {
		return 0, false
	}
	remaining := time.Until(deadline)
	if remaining <= 0 {
		return 0, true
	}
	return float64(remaining.Milliseconds()), true
}
