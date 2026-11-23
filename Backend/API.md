# LaLune Backend API

Актуальные backend-ветки поддерживают CSQTT, CSQTTR и ToTS.
Конкретный набор протоколов среды запрашивается через `GET /core/protocols`.

## Профили

`GET /configs` возвращает сохранённые профили.

`POST /configs/parse` разбирает профиль без сохранения. Тело:
```json
{"link":"csqtt://...","protocol":"CSQTT"}
```

`POST /configs` сохраняет профиль, `DELETE /configs/{id}` удаляет его.

Для CSQTT поддерживаются идентификаторы `CSQTT`, `CSQTT 2.1.9`,
`CSQTT 2.5.1`; для CSQTTR — `CSQTTR`; для ToTS — `ToTS`.

## VPN

`POST /vpn/connect/{id}` запускает выбранный профиль, `POST /vpn/disconnect`
останавливает его. `GET /vpn/status` и `GET /vpn/stats` возвращают состояние
и статистику текущего соединения.

ToTS получает параметры из разобранного `tots://` URI и настроек клиента;
CLI-флаг `--config` интеграцией LaLune не используется.
