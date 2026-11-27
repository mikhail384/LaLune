package main

import (
	"net/url"
	"strings"
	"testing"
)

func TestIsBlankRedirect(t *testing.T) {
	tests := []struct {
		name string
		url  string
		want bool
	}{
		{
			name: "vk.ru blank page",
			url:  "https://oauth.vk.ru/blank.html#access_token=abc",
			want: true,
		},
		{
			name: "vk.com blank page",
			url:  "https://oauth.vk.com/blank.html#access_token=abc",
			want: true,
		},
		{
			name: "uppercase host",
			url:  "https://OAuth.VK.RU/blank.html#access_token=abc",
			want: true,
		},
		{
			name: "blank page without fragment",
			url:  "https://oauth.vk.ru/blank.html",
			want: true,
		},
		{
			name: "other path on oauth host",
			url:  "https://oauth.vk.ru/login#access_token=abc",
			want: false,
		},
		{
			name: "vk.com main page",
			url:  "https://vk.com/blank.html#access_token=abc",
			want: false,
		},
		{
			name: "not a URL",
			url:  "blank.html",
			want: false,
		},
		{
			name: "empty",
			url:  "",
			want: false,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := isBlankRedirect(test.url); got != test.want {
				t.Fatalf("isBlankRedirect(%q) = %v, want %v", test.url, got, test.want)
			}
		})
	}
}

func TestExtractFragment(t *testing.T) {
	tests := []struct {
		name string
		url  string
		want string
	}{
		{
			name: "fragment",
			url:  "https://oauth.vk.ru/blank.html#access_token=abc&user_id=1",
			want: "access_token=abc&user_id=1",
		},
		{
			name: "query fallback",
			url:  "https://oauth.vk.ru/blank.html?access_token=abc",
			want: "access_token=abc",
		},
		{
			name: "fragment wins over query",
			url:  "https://oauth.vk.ru/blank.html?a=1#b=2",
			want: "b=2",
		},
		{
			name: "percent decoded",
			url:  "https://oauth.vk.ru/blank.html#payload=%7B%22type%22%3A%22silent_token%22%7D",
			want: `payload={"type":"silent_token"}`,
		},
		{
			name: "plus is preserved",
			url:  "https://oauth.vk.ru/blank.html#access_token=a+b",
			want: "access_token=a+b",
		},
		{
			name: "no fragment",
			url:  "https://oauth.vk.ru/blank.html",
			want: "",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := extractFragment(test.url); got != test.want {
				t.Fatalf("extractFragment(%q) = %q, want %q", test.url, got, test.want)
			}
		})
	}
}

func TestIsSilentTokenFragment(t *testing.T) {
	tests := []struct {
		name     string
		fragment string
		want     bool
	}{
		{
			name:     "compact json payload",
			fragment: `payload={"type":"silent_token","token":"abc"}`,
			want:     true,
		},
		{
			name:     "json payload with spaces",
			fragment: `payload={"type": "silent_token"}`,
			want:     true,
		},
		{
			name:     "payload without silent type",
			fragment: `payload={"type":"access_token","token":"abc"}`,
			want:     false,
		},
		{
			name:     "silent type without payload",
			fragment: `type":"silent_token"`,
			want:     false,
		},
		{
			name:     "plain access token",
			fragment: "access_token=abc&expires_in=0",
			want:     false,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := isSilentTokenFragment(test.fragment); got != test.want {
				t.Fatalf("isSilentTokenFragment(%q) = %v, want %v", test.fragment, got, test.want)
			}
		})
	}
}

func TestParseRedirect(t *testing.T) {
	tests := []struct {
		name      string
		url       string
		wantKind  redirectKind
		wantToken string
	}{
		{
			name:      "real access token",
			url:       "https://oauth.vk.ru/blank.html#access_token=vk1.a.ABCdef&expires_in=0&user_id=1",
			wantKind:  redirectAccessToken,
			wantToken: "vk1.a.ABCdef",
		},
		{
			name:      "access token on vk.com host",
			url:       "https://oauth.vk.com/blank.html#access_token=TOKEN42&expires_in=86399&user_id=42",
			wantKind:  redirectAccessToken,
			wantToken: "TOKEN42",
		},
		{
			name:      "percent encoded access token",
			url:       "https://oauth.vk.ru/blank.html#access_token=vk1%2Fa&expires_in=0",
			wantKind:  redirectAccessToken,
			wantToken: "vk1/a",
		},
		{
			name:      "access token in query",
			url:       "https://oauth.vk.ru/blank.html?access_token=query-token",
			wantKind:  redirectAccessToken,
			wantToken: "query-token",
		},
		{
			name:     "silent token payload",
			url:      "https://oauth.vk.ru/blank.html#payload=%7B%22type%22%3A%22silent_token%22%2C%22token%22%3A%22abc%22%7D",
			wantKind: redirectSilentToken,
		},
		{
			name:     "oauth error",
			url:      "https://oauth.vk.ru/blank.html#error=access_denied&error_description=User%20denied",
			wantKind: redirectOAuthError,
		},
		{
			name:      "access token wins over silent payload",
			url:       "https://oauth.vk.ru/blank.html#access_token=real&payload=%7B%22type%22%3A%22silent_token%22%7D",
			wantKind:  redirectAccessToken,
			wantToken: "real",
		},
		{
			name:     "silent token wins over error marker",
			url:      "https://oauth.vk.ru/blank.html#payload=%7B%22type%22%3A%22silent_token%22%7D&error=ignored",
			wantKind: redirectSilentToken,
		},
		{
			name:     "blank page without fragment",
			url:      "https://oauth.vk.ru/blank.html",
			wantKind: redirectNone,
		},
		{
			name:     "access token on a non blank page",
			url:      "https://vk.com/feed#access_token=abc",
			wantKind: redirectNone,
		},
		{
			name:     "unrelated fragment",
			url:      "https://oauth.vk.ru/blank.html#foo=bar",
			wantKind: redirectNone,
		},
		{
			name:     "empty url",
			url:      "",
			wantKind: redirectNone,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got := parseRedirect(test.url)
			if got.kind != test.wantKind {
				t.Fatalf("parseRedirect(%q).kind = %v, want %v", test.url, got.kind, test.wantKind)
			}
			if got.token != test.wantToken {
				t.Fatalf("parseRedirect(%q).token = %q, want %q", test.url, got.token, test.wantToken)
			}
		})
	}
}

func TestAuthURLMatchesVKConstants(t *testing.T) {
	if !strings.Contains(vkAuthURL, "redirect_uri=https%3A%2F%2Foauth.vk.ru%2Fblank.html") {
		t.Fatalf("vkAuthURL must carry the URL-encoded redirect_uri, got %q", vkAuthURL)
	}

	parsed, err := url.Parse(vkAuthURL)
	if err != nil {
		t.Fatalf("vkAuthURL is not a valid URL: %v", err)
	}
	if got, want := parsed.Scheme+"://"+parsed.Host+parsed.Path, "https://oauth.vk.ru/authorize"; got != want {
		t.Fatalf("vkAuthURL endpoint = %q, want %q", got, want)
	}

	query := parsed.Query()
	want := map[string]string{
		"client_id":     "7793118",
		"scope":         "1073737727",
		"redirect_uri":  "https://oauth.vk.ru/blank.html",
		"display":       "page",
		"response_type": "token",
		"revoke":        "1",
		"v":             "5.199",
	}
	for key, wantValue := range want {
		if got := query.Get(key); got != wantValue {
			t.Fatalf("vkAuthURL query %q = %q, want %q", key, got, wantValue)
		}
	}
}
