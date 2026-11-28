# LaLune Backend API

Актуальные backend-ветки поддерживают CSQTT, CSQTTR, ToTS и WDTToR.
Конкретный набор протоколов среды запрашивается через `GET /core/protocols`.

## Профили

`GET /configs` возвращает сохранённые профили.

`POST /configs/parse` разбирает профиль без сохранения. Тело:
```json
{"link":"csqtt://...","protocol":"CSQTT"}
```

`POST /configs` сохраняет профиль, `DELETE /configs/{id}` удаляет его.

Для CSQTT поддерживаются идентификаторы `CSQTT`, `CSQTT 2.1.9`,
`CSQTT 2.5.1`; для CSQTTR — `CSQTTR`; для ToTS — `ToTS`;
для WDTToR — `WDTToR` (в UI подписан как «WDTToR (WDTT)»).

## VPN

`POST /vpn/connect/{id}` запускает выбранный профиль, `POST /vpn/disconnect`
останавливает его. `GET /vpn/status` и `GET /vpn/stats` возвращают состояние
и статистику текущего соединения.

ToTS получает параметры из разобранного `tots://` URI и настроек клиента;
CLI-флаг `--config` интеграцией LaLune не используется.

WDTToR — обратно совместимый с сервером WDTT клиент на Rust
(`Endlad2/wdtt-rslib`): WireGuard поверх TURN/DTLS. Ссылка
`wdtt://host:dtls:wg:local:password:hashes` разбирается в `peer`, `password`
и `hashes`, а `rawLink` сохраняется целиком.

Особенности запуска:

* на десктопе и OpenWRT ядро само поднимает TUN (нужен root/администратор);
* на Android TUN создаёт `VpnService`, а ядру передаётся `--packet-port`:
  оно принимает сырые IP-пакеты по UDP и само делает WireGuard;
* на iOS протокол недоступен — там нет системного VPN-провайдера.

Готовность приходит событием `__WDTT_EVENT__|READY|`, а адрес и DNS для
интерфейса — строкой `TUNCONF:<ip>:<dns>`; статистика печатается в формате
оригинального WDTT: `[СТАТИСТИКА] Активных: N | Трафик: X.XX МБ`.

Настройки: `wdttWorkers` (кратно 9, 9..108), `wdttObfs` (`audio`/`video`),
`wdttVkAuthMode` (`manual`/`autoApi`), `wdttLocalPort`, `wdttDeviceId`.
В режиме `autoApi` бэкенд создаёт VK-звонки перед запуском и подставляет их
хеши; в `manual` хеши берутся из конфига.
