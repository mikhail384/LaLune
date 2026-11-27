package main

import "testing"

func TestAppDirWindowsUsesAppData(t *testing.T) {
	env := pathEnv{
		GOOS:    "windows",
		AppData: `C:\Users\user\AppData\Roaming`,
		Home:    `C:\Users\user`,
	}

	got, err := env.appDir()
	if err != nil {
		t.Fatalf("appDir() error: %v", err)
	}
	want := `C:\Users\user\AppData\Roaming\.la-lune`
	if got != want {
		t.Fatalf("appDir() = %q, want %q", got, want)
	}
}

func TestAppDirWindowsFallsBackToUserProfile(t *testing.T) {
	env := pathEnv{
		GOOS:    "windows",
		AppData: "   ",
		Home:    `C:\Users\user`,
	}

	got, err := env.appDir()
	if err != nil {
		t.Fatalf("appDir() error: %v", err)
	}
	want := `C:\Users\user\.la-lune`
	if got != want {
		t.Fatalf("appDir() = %q, want %q", got, want)
	}
}

func TestAppDirWindowsWithoutEnvironmentFails(t *testing.T) {
	env := pathEnv{GOOS: "windows"}
	if _, err := env.appDir(); err == nil {
		t.Fatal("appDir() error = nil, want an error when APPDATA and USERPROFILE are empty")
	}
}

func TestAppDirLinuxUsesHome(t *testing.T) {
	env := pathEnv{GOOS: "linux", Home: "/home/user"}

	got, err := env.appDir()
	if err != nil {
		t.Fatalf("appDir() error: %v", err)
	}
	want := "/home/user/.la-lune"
	if got != want {
		t.Fatalf("appDir() = %q, want %q", got, want)
	}
}

func TestAppDirLinuxWithoutHomeFails(t *testing.T) {
	env := pathEnv{GOOS: "linux", Home: ""}
	if _, err := env.appDir(); err == nil {
		t.Fatal("appDir() error = nil, want an error when HOME is empty")
	}
}

func TestDefaultPathsWindows(t *testing.T) {
	env := pathEnv{
		GOOS:    "windows",
		AppData: `C:\Users\user\AppData\Roaming`,
	}

	tokenPath, err := env.defaultTokenPath()
	if err != nil {
		t.Fatalf("defaultTokenPath() error: %v", err)
	}
	if want := `C:\Users\user\AppData\Roaming\.la-lune\token.json`; tokenPath != want {
		t.Fatalf("defaultTokenPath() = %q, want %q", tokenPath, want)
	}

	userDataDir, err := env.defaultUserDataDir()
	if err != nil {
		t.Fatalf("defaultUserDataDir() error: %v", err)
	}
	if want := `C:\Users\user\AppData\Roaming\.la-lune\vk-token-fetcher\userdata`; userDataDir != want {
		t.Fatalf("defaultUserDataDir() = %q, want %q", userDataDir, want)
	}

	browsersPath, err := env.defaultBrowsersPath()
	if err != nil {
		t.Fatalf("defaultBrowsersPath() error: %v", err)
	}
	if want := `C:\Users\user\AppData\Roaming\.la-lune\vk-token-fetcher\browsers`; browsersPath != want {
		t.Fatalf("defaultBrowsersPath() = %q, want %q", browsersPath, want)
	}
}

func TestDefaultPathsLinux(t *testing.T) {
	env := pathEnv{GOOS: "linux", Home: "/home/user"}

	tokenPath, err := env.defaultTokenPath()
	if err != nil {
		t.Fatalf("defaultTokenPath() error: %v", err)
	}
	if want := "/home/user/.la-lune/token.json"; tokenPath != want {
		t.Fatalf("defaultTokenPath() = %q, want %q", tokenPath, want)
	}

	userDataDir, err := env.defaultUserDataDir()
	if err != nil {
		t.Fatalf("defaultUserDataDir() error: %v", err)
	}
	if want := "/home/user/.la-lune/vk-token-fetcher/userdata"; userDataDir != want {
		t.Fatalf("defaultUserDataDir() = %q, want %q", userDataDir, want)
	}

	browsersPath, err := env.defaultBrowsersPath()
	if err != nil {
		t.Fatalf("defaultBrowsersPath() error: %v", err)
	}
	if want := "/home/user/.la-lune/vk-token-fetcher/browsers"; browsersPath != want {
		t.Fatalf("defaultBrowsersPath() = %q, want %q", browsersPath, want)
	}
}

func TestJoinForKeepsTargetSeparator(t *testing.T) {
	if got, want := joinFor("windows", `D:\LaLune`, "token.json"), `D:\LaLune\token.json`; got != want {
		t.Fatalf("joinFor(windows) = %q, want %q", got, want)
	}
	if got, want := joinFor("linux", "/opt/lalune", "token.json"), "/opt/lalune/token.json"; got != want {
		t.Fatalf("joinFor(linux) = %q, want %q", got, want)
	}
}
