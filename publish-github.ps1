# Публикация LaLune на GitHub одной командой.
#   powershell -ExecutionPolicy Bypass -File .\publish-github.ps1 [-Repo LaLune] [-Private]
# Делает: ставит git и GitHub CLI (если нет) -> вход в GitHub (один раз, по коду в браузере) ->
# подставляет ВАШ аккаунт в ссылки на релизы (установщик роутера/ПК скачивает бэкенды оттуда) ->
# создаёт репозиторий и пушит. Push запускает GitHub Actions: сборка всех платформ и релиз.
param(
  [string]$Repo = 'LaLune',
  [switch]$Private   # приватный репозиторий НЕ подходит для автоустановки: роутер качает релизы без входа
)
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

function Refresh-Path { $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User') }
function Ensure-Tool($cmd, $wingetId) {
  if (Get-Command $cmd -ErrorAction SilentlyContinue) { return }
  Write-Host "Устанавливаю $wingetId ..."
  winget install --id $wingetId -e --silent --accept-package-agreements --accept-source-agreements
  Refresh-Path
  if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
    foreach ($p in "$env:ProgramFiles\Git\cmd", "$env:ProgramFiles\GitHub CLI", "$env:LOCALAPPDATA\Programs\GitHub CLI") { if (Test-Path $p) { $env:Path += ";$p" } }
  }
  if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { throw "$cmd не найден после установки: перезапустите PowerShell и запустите скрипт снова." }
}
$tools = "$env:LOCALAPPDATA\LaLuneTools"
foreach ($p in "$tools\gh\bin", "$tools\git\cmd") { if (Test-Path $p) { $env:Path = "$p;" + $env:Path } }
Ensure-Tool git 'Git.Git'
Ensure-Tool gh  'GitHub.cli'

$null = & { $ErrorActionPreference = 'Continue'; gh auth status 2>&1 }
if ($LASTEXITCODE -ne 0) {
  Write-Host 'Вход в GitHub: откроется браузер, введите показанный код.'
  gh auth login --hostname github.com --git-protocol https --web
}
$login = (gh api user -q .login).Trim()
$id    = (gh api user -q .id).Trim()
Write-Host "Аккаунт: $login"

# Ссылки на релизы LaLune -> ваш репозиторий (ядра Endlad2/csqtt-core и др. не трогаем).
$target = "$login/$Repo"
$files = @('Installer\openwrt.sh','Installer\install.ps1','Installer\install.sh','Installer\launcher\build.rs','Frontend\lib\state\openwrt_installer.dart')
foreach ($f in $files) {
  if (-not (Test-Path $f)) { continue }
  $t = [IO.File]::ReadAllText((Resolve-Path $f))
  $n = $t.Replace('Endlad2/LaLune', $target)
  if ($n -ne $t) { [IO.File]::WriteAllText((Resolve-Path $f), $n, (New-Object Text.UTF8Encoding($false))); Write-Host "обновлено: $f" }
}

if (-not (Test-Path .git)) { git init -b main | Out-Null }
git config user.name  $login
git config user.email "$id+$login@users.noreply.github.com"
git add -A
$null = & { $ErrorActionPreference = 'Continue'; git commit -m "LaLune: initial import" 2>&1 }

$vis = if ($Private) { '--private' } else { '--public' }
$null = & { $ErrorActionPreference = 'Continue'; gh repo view $target 2>&1 }
if ($LASTEXITCODE -ne 0) {
  gh repo create $target $vis --source . --remote origin --push
} else {
  if (-not (git remote | Select-String '^origin$')) { git remote add origin "https://github.com/$target.git" }
  git push -u origin main
}
Write-Host ''
Write-Host "Готово: https://github.com/$target"
Write-Host "Сборка:  https://github.com/$target/actions   (релиз появится сам, ~30-60 мин)"
Write-Host "Релизы:  https://github.com/$target/releases"