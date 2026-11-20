# LaLune AI-Doctor (VPS + Google OAuth 2.0)

Сервер ИИ-диагностики и самовосстановления OpenWRT для LaLune. Работает через ваш Google-аккаунт (OAuth 2.0 → Gemini API) без статических API-ключей.

## Быстрый запуск на VPS

1. В Google Cloud Console включите **Generative Language API**, создайте OAuth 2.0 Client (**Web application**) с Redirect URI `https://<ваш-домен-vps>/auth/google/callback`, скачайте JSON в `/data/client_secret.json` и переведите Audience в **In production**.
2. Запустите Docker-контейнер:
```bash
docker build -t lalune-ai-doctor .
docker run -d --name lalune-ai-doctor --restart unless-stopped \
  -p 8080:8080 -v /data:/data \
  -e PUBLIC_BASE_URL="https://<ваш-домен-vps>" \
  -e AI_DOCTOR_SECRET="<ваш-секрет>" \
  -e GEMINI_MODEL="gemini-2.5-flash" \
  lalune-ai-doctor
```
3. Откройте `https://<ваш-домен-vps>/auth/google/login` и войдите через Google.
4. В LaLune (окно установки OpenWRT → **«Исправить с ИИ»**) укажите адрес VPS и секрет.
