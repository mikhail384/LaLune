# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
"""LaLune AI-Doctor VPS server (Google OAuth 2.0 -> Gemini API)."""

import json
import os
import re
from pathlib import Path
from typing import Any, Literal, Optional

import httpx
from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from google.auth.transport.requests import Request as GoogleAuthRequest
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import Flow
from pydantic import BaseModel, Field

os.environ.setdefault("OAUTHLIB_RELAX_TOKEN_SCOPE", "1")

SCOPES = [
    "https://www.googleapis.com/auth/generative-language",
    "https://www.googleapis.com/auth/cloud-platform",
]
CLIENT_SECRETS_FILE = os.environ.get("GOOGLE_CLIENT_SECRETS", "/data/client_secret.json")
TOKEN_FILE = Path(os.environ.get("GOOGLE_TOKEN_FILE", "/data/token.json"))
PUBLIC_BASE_URL = os.environ.get("PUBLIC_BASE_URL", "http://localhost:8080").rstrip("/")
GEMINI_MODEL = os.environ.get("GEMINI_MODEL", "gemini-2.5-flash")
API_SECRET = os.environ.get("AI_DOCTOR_SECRET", "").strip()

SAFE_ACTIONS = {
    "cleanup_routing_10620",
    "restart_lalune",
    "install_pkg",
    "drop_caches",
    "collect_more_diagnostics",
}
SAFE_PACKAGES = {
    "ip-full",
    "kmod-tun",
    "iptables-nft",
    "iptables",
    "kmod-ipt-nat",
    "kmod-nft-nat",
    "kmod-nft-compat",
    "iptables-mod-nat-extra",
    "ca-bundle",
    "ca-certificates",
    "coreutils-nohup",
}
BLOCKED_PATTERNS = [
    re.compile(r"rm\s+-[^\n]*r[^\n]*f\s+/(?:\s|$)", re.I),
    re.compile(r"\b(mtd|sysupgrade|firstboot|jffs2reset|mkfs\.\w+)\b", re.I),
    re.compile(r"\bdd\b[^\n]*\bof=/dev/", re.I),
    re.compile(r"\bpasswd\b", re.I),
]

SYSTEM_PROMPT = """Ты — экспертный инженер OpenWRT и VPN-клиента LaLune (CSQTT/CSQTTR).
Тебе передают обезличенный лог установки или работы LaLune на роутере OpenWRT.
Определи точную первопричину сбоя и верни СТРОГО валидный JSON по схеме:
{
  "tier": "safe" | "approval_required" | "info_only",
  "diagnosis": "Краткий и точный диагноз на русском",
  "action_id": "cleanup_routing_10620" | "restart_lalune" | "install_pkg" | "drop_caches" | "collect_more_diagnostics" | "custom_root_command" | "none",
  "pkg": "имя пакета из разрешённого списка (только если action_id == install_pkg, иначе null)",
  "command": "точная команда root (только если tier == approval_required и action_id == custom_root_command, иначе null)",
  "risk_level": "low" | "medium" | "high",
  "consequences": "Понятное описание возможных последствий при неудаче на русском (обязательно для approval_required)",
  "backup_paths": ["/etc/config/..."],
  "rollback_hint": "Как откатить изменения при проблеме"
}
Правила безопасности:
1. Если проблему можно решить безопасным действием из белого списка (cleanup_routing_10620, restart_lalune, install_pkg, drop_caches), ВСЕГДА выбирай tier="safe".
2. Если нужна правка /etc/config/*, удаление конфликтующего пакета (opkg remove), перезагрузка сети/fw4 или нестандартная команда от root — ставь tier="approval_required", action_id="custom_root_command", подробно опиши последствия в consequences и перечисли изменяемые файлы в backup_paths.
3. Никогда не предлагай разрушительные команды (rm -rf /, mtd, sysupgrade, firstboot, dd of=/dev/, passwd).
"""

app = FastAPI(title="LaLune AI-Doctor", version="1.0.0")


class DiagnoseRequest(BaseModel):
    host: str = ""
    stage: str = ""
    error_message: str = ""
    log: str = Field(..., max_length=120_000)
    history: list[str] = Field(default_factory=list)


class DiagnoseResponse(BaseModel):
    tier: Literal["safe", "approval_required", "info_only"]
    diagnosis: str
    action_id: str = "none"
    pkg: Optional[str] = None
    command: Optional[str] = None
    risk_level: Literal["low", "medium", "high"] = "low"
    consequences: str = ""
    backup_paths: list[str] = Field(default_factory=list)
    rollback_hint: str = ""


def _check_secret(authorization: Optional[str]) -> None:
    if not API_SECRET:
        return
    if not authorization or authorization.strip() != f"Bearer {API_SECRET}":
        raise HTTPException(status_code=401, detail="Invalid AI_DOCTOR_SECRET")


def _redact(text: str) -> str:
    patterns = [
        (r"(password|pass|pwd|vk_token|secret|session_key|anonymToken)=([^\s&'\"\\]+)", r"\1=[REDACTED]"),
        (r"(CSQTT_PASSWORD=)([^\s]+)", r"\1[REDACTED]"),
        (r"(Bearer\s+)[A-Za-z0-9._\-]+", r"\1[REDACTED]"),
    ]
    out = text
    for pat, repl in patterns:
        out = re.sub(pat, repl, out, flags=re.I)
    return out


def _load_credentials() -> Optional[Credentials]:
    if not TOKEN_FILE.exists():
        return None
    creds = Credentials.from_authorized_user_file(str(TOKEN_FILE), SCOPES)
    if creds.expired and creds.refresh_token:
        creds.refresh(GoogleAuthRequest())
        TOKEN_FILE.parent.mkdir(parents=True, exist_ok=True)
        TOKEN_FILE.write_text(creds.to_json(), encoding="utf-8")
        os.chmod(TOKEN_FILE, 0o600)
    return creds if creds.valid else None


def _build_flow() -> Flow:
    if not Path(CLIENT_SECRETS_FILE).exists():
        raise HTTPException(
            status_code=500,
            detail=f"Missing Google OAuth client secret file: {CLIENT_SECRETS_FILE}",
        )
    return Flow.from_client_secrets_file(
        CLIENT_SECRETS_FILE,
        scopes=SCOPES,
        redirect_uri=f"{PUBLIC_BASE_URL}/auth/google/callback",
    )


@app.get("/auth/status")
def auth_status() -> dict[str, Any]:
    creds = _load_credentials()
    return {
        "authenticated": creds is not None,
        "model": GEMINI_MODEL,
        "login_url": f"{PUBLIC_BASE_URL}/auth/google/login",
    }


@app.get("/auth/google/login")
def google_login() -> RedirectResponse:
    flow = _build_flow()
    auth_url, _ = flow.authorization_url(
        access_type="offline",
        include_granted_scopes="true",
        prompt="consent",
    )
    return RedirectResponse(auth_url)


@app.get("/auth/google/callback")
def google_callback(request: Request) -> HTMLResponse:
    flow = _build_flow()
    flow.fetch_token(authorization_response=str(request.url))
    creds = flow.credentials
    TOKEN_FILE.parent.mkdir(parents=True, exist_ok=True)
    TOKEN_FILE.write_text(creds.to_json(), encoding="utf-8")
    os.chmod(TOKEN_FILE, 0o600)
    return HTMLResponse(
        "<h2>Google OAuth подключён</h2>"
        "<p>Теперь можно вернуться в приложение LaLune и запустить ИИ-диагностику.</p>"
    )


@app.post("/api/diagnose", response_model=DiagnoseResponse)
async def diagnose(
    req: DiagnoseRequest,
    authorization: Optional[str] = Header(default=None),
) -> DiagnoseResponse:
    _check_secret(authorization)
    creds = _load_credentials()
    if creds is None:
        raise HTTPException(
            status_code=401,
            detail=f"Google OAuth not authorized. Open {PUBLIC_BASE_URL}/auth/google/login",
        )

    user_text = (
        f"Host: {req.host}\n"
        f"Stage: {req.stage}\n"
        f"Error: {req.error_message}\n"
        f"Previous actions: {json.dumps(req.history, ensure_ascii=False)}\n\n"
        f"Diagnostic log:\n{_redact(req.log)[-30000:]}"
    )

    url = (
        f"https://generativelanguage.googleapis.com/v1beta/models/"
        f"{GEMINI_MODEL}:generateContent"
    )
    payload = {
        "systemInstruction": {"parts": [{"text": SYSTEM_PROMPT}]},
        "contents": [{"role": "user", "parts": [{"text": user_text}]}],
        "generationConfig": {
            "temperature": 0.1,
            "responseMimeType": "application/json",
        },
    }

    async with httpx.AsyncClient(timeout=60.0) as client:
        resp = await client.post(
            url,
            headers={
                "Authorization": f"Bearer {creds.token}",
                "Content-Type": "application/json",
            },
            json=payload,
        )
    if resp.status_code >= 400:
        raise HTTPException(
            status_code=502,
            detail=f"Gemini API error ({resp.status_code}): {resp.text[:500]}",
        )

    data = resp.json()
    try:
        raw_text = data["candidates"][0]["content"]["parts"][0]["text"]
        parsed = DiagnoseResponse.model_validate_json(raw_text)
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"Invalid model JSON: {exc}")

    if parsed.tier == "safe":
        if parsed.action_id not in SAFE_ACTIONS:
            parsed.tier = "approval_required"
            parsed.risk_level = "high"
        elif parsed.action_id == "install_pkg" and parsed.pkg not in SAFE_PACKAGES:
            parsed.tier = "approval_required"
            parsed.action_id = "custom_root_command"
            parsed.command = f"opkg update && opkg install {parsed.pkg or ''}".strip()
            parsed.risk_level = "medium"

    if parsed.command:
        for pat in BLOCKED_PATTERNS:
            if pat.search(parsed.command):
                return DiagnoseResponse(
                    tier="info_only",
                    diagnosis=(
                        f"{parsed.diagnosis}\n\n"
                        "Предложенная команда заблокирована политикой безопасности."
                    ),
                    action_id="none",
                    risk_level="high",
                    consequences="Команда заблокирована для предотвращения повреждения роутера.",
                )

    return parsed
