# Linux TUN tests

Набор проверяет desktop backend в изолированных network namespace и,
где применимо, совместимость CSQTT/CSQTTR с маршрутизацией TUN.

Пример:
```bash
sudo python3 Backend/tests/linux_tun.py Backend/Desktop/target/debug/lalune-backend
```

Для отдельной проверки CSQTTR:
```bash
sudo python3 Backend/tests/linux_tun.py Backend/Desktop/target/debug/lalune-backend --case csqttr_compat
```

Если задан `CARGO_TARGET_DIR`, укажите соответствующие пути к бинарникам.
Тестовое эхо-ядро не проверяет настоящий транспортный протокол.
