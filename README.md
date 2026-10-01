# Element Matrix Local Lab

Локальный тестовый стенд **Matrix + Element Web + MatrixRTC/LiveKit** для Ubuntu.
https://element.m.localhost

sudo cp caddy-root.crt /usr/local/share/ca-certificates/element-matrix-lab.crt && sudo update-ca-certificates

Разворачивается полностью на ноутбуке: без публичного DNS, без VPS, без внешних доменов.
HTTPS обеспечивается Caddy с приватным локальным CA.

---

## Стек

| Компонент        | Роль                                    |
|------------------|-----------------------------------------|
| Synapse          | Matrix homeserver                       |
| PostgreSQL       | База данных Synapse                     |
| Element Web      | Веб-клиент                              |
| Caddy            | Reverse proxy + локальный HTTPS         |
| LiveKit          | SFU для аудио/видеозвонков (MatrixRTC)  |
| lk-jwt-service   | Выдача JWT для подключения к LiveKit    |

---

## Локальные имена
https://element.m.localhost Element Web
https://matrix.m.localhost Synapse
https://matrix-rtc.m.localhost LiveKit + lk-jwt

Matrix ID пользователей:
@alex:matrix.m.localhost
@test:matrix.m.localhost


---

## Требования

- Ubuntu 22.04+
- Docker Engine с плагином Docker Compose v2
- `sudo`, `curl`, `openssl`, `ip`
- Свободные порты `80`, `443`, `8448` на `127.0.0.1`
- Свободные порты на LAN IP: `7881/tcp`, `7882/udp`, `3478/udp`

Скрипт установки сам поставит отсутствующие утилиты и Docker при необходимости.

---

## Установка

Запускать от обычного пользователя, **не от root**:

```bash
chmod +x install-element-matrix-local.sh
./install-element-matrix-local.sh
```

Скрипт ```install-element-matrix-local```:

Генерирует synapse/homeserver.yaml, element/config.json,
livekit/livekit.yaml, Caddyfile, compose.yaml, .env.

Поднимает все контейнеры.

Извлекает корневой CA Caddy в caddy-root.crt и ставит его в
системный trust store Ubuntu.

Добавляет локальные имена в /etc/hosts.

Создаёт вспомогательные скрипты start.sh, stop.sh, status.sh,
logs.sh, create-user.sh.

Проект разворачивается в ~/element-matrix-lab
(переопределяется переменной PROJECT_DIR).



## Создание пользователей
```
cd ~/element-matrix-lab
./create-user.sh
```
Скрипт спросит имя, пароль и права администратора. Повтори для каждого пользователя.


## Запуск и остановка
```
cd ~/element-matrix-lab

./start.sh          # запустить стек
./stop.sh           # остановить (данные сохраняются)
./status.sh         # статус и проверка эндпоинтов
./logs.sh           # все логи
./logs.sh synapse   # логи конкретного сервиса
```
## Полный сброс (с удалением БД, сертификатов и пользователей):

```
cd ~/element-matrix-lab
docker compose down -v
rm -rf synapse element livekit Caddyfile compose.yaml compose.override.yaml .env
```

После этого можно снова запустить install-element-matrix-local.sh

## Доверие к сертификату
Caddy использует приватный CA. Чтобы браузеры и клиенты доверяли *.m.localhost,
корневой сертификат нужно установить в их хранилища.

## Система (Chrome, Chromium, Brave)
Скрипт установки уже делает это. Если нужно повторить вручную:
```
cd ~/element-matrix-lab
docker compose cp caddy:/data/caddy/pki/authorities/local/root.crt ./caddy-root.crt
sudo cp caddy-root.crt /usr/local/share/ca-certificates/element-matrix-lab.crt
sudo update-ca-certificates
```


### Структура проекта
element-matrix-lab/
├── .env                       сгенерированные секреты
├── Caddyfile                  reverse proxy конфиг
├── compose.yaml               основной стек
├── compose.override.yaml      локальные фиксы для 8448 и алиасов
├── caddy-root.crt             корневой CA Caddy
├── install-element-matrix-local.sh
├── start.sh / stop.sh / status.sh / logs.sh / create-user.sh
├── element/
│   └── config.json
├── livekit/
│   └── livekit.yaml
└── synapse/
    ├── homeserver.yaml
    ├── *.signing.key
    └── *.log.config
