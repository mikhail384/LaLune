# LaLune Site

Статический сайт без Flutter и дополнительных npm-зависимостей.

## Файлы

- `index.html` — разметка.
- `styles.css` — адаптивный дизайн и анимации.
- `app.js` — загрузка GitHub-статистики, контрибьютеров и latest release.
- `assets/` — локальные изображения LaLune и QR зеркала MAX.

## Локальный запуск

```bash
cd Site
python3 -m http.server 8080
```

Открой `http://localhost:8080`.

GitHub API используется без токена, поэтому для публичного клиента действует стандартный rate limit GitHub. Данные кешируются в `localStorage` на 10 минут.
