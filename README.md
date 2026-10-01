Element Matrix Local Lab
=======================

Локальный тестовый стенд Matrix + Element Web + MatrixRTC/LiveKit для Ubuntu.

Разворачивается полностью на ноутбуке: без публичного DNS, без VPS, без
внешних доменов. HTTPS обеспечивается Caddy с приватным локальным CA.

Что входит в стек

Synapse - Matrix homeserver
PostgreSQL - база данных Synapse
Element Web - веб-клиент
Caddy - reverse proxy + локальный HTTPS
LiveKit - SFU для аудио/видеозвонков (MatrixRTC)
lk-jwt-service - выдача JWT для подключения к LiveKit

Локальные имена

https://element.m.localhost Element Web
https://matrix.m.localhost Synapse
https://matrix-rtc.m.localhost LiveKit + lk-jwt

Matrix ID пользователей:

@alex:matrix.m.localhost
@test:matrix.m.localhost

Требования

Ubuntu (тестировалось на 22.04+)

Docker Engine с плагином Docker Compose v2

sudo, curl, openssl, ip

Свободные порты 80, 443, 8448 на 127.0.0.1

Свободные порты на LAN IP: 7881/tcp, 7882/udp, 3478/udp

Скрипт сам установит отсутствующие утилиты и Docker при необходимости.

Установка

Запускать от обычного пользователя, НЕ от root:

chmod +x install-element-matrix-local.sh
./install-element-matrix-local.sh

Скрипт:

Генерирует synapse/homeserver.yaml, element/config.json,
livekit/livekit.yaml, Caddyfile, compose.yaml, .env.

Поднимает все контейнеры.

Извлекает корневой CA Caddy в caddy-root.crt и ставит его в
системный trust store Ubuntu.

Добавляет локальные имена в /etc/hosts.

Создаёт вспомогательные скрипты (start.sh, stop.sh, status.sh,
logs.sh, create-user.sh).

Проект разворачивается в ~/element-matrix-lab (переопределяется через
PROJECT_DIR).

Создание пользователей

cd ~/element-matrix-lab
./create-user.sh

Скрипт спросит имя, пароль и права администратора. Повтори для каждого
пользователя.

Запуск и остановка

cd ~/element-matrix-lab

./start.sh запустить стек
./stop.sh остановить (данные сохраняются)
./status.sh статус и проверка эндпоинтов
./logs.sh все логи
./logs.sh synapse логи конкретного сервиса

Полный сброс (с удалением БД, сертификатов и пользователей):

cd ~/element-matrix-lab
docker compose down -v
rm -rf synapse element livekit Caddyfile compose.yaml compose.override.yaml .env

После этого можно снова запустить install-element-matrix-local.sh.

Доверие к сертификату

Caddy использует приватный CA. Чтобы браузеры и клиенты доверяли
*.m.localhost, корневой сертификат нужно установить в их хранилища.

Система (Chrome, Chromium, Brave):

Скрипт установки уже делает это. Если нужно повторить вручную:

cd ~/element-matrix-lab
docker compose cp caddy:/data/caddy/pki/authorities/local/root.crt ./caddy-root.crt
sudo cp caddy-root.crt /usr/local/share/ca-certificates/element-matrix-lab.crt
sudo update-ca-certificates

Firefox:

Настройки -> Приватность и защита -> Сертификаты ->
Просмотреть сертификаты -> Центры сертификации -> Импортировать ->
выбрать caddy-root.crt -> отметить "Доверять этому CA для
идентификации веб-сайтов" -> перезапустить Firefox.

Element Desktop:

SSL_CERT_FILE="$HOME/element-matrix-lab/caddy-root.crt" element-desktop

или, для AppImage:

SSL_CERT_FILE="$HOME/element-matrix-lab/caddy-root.crt" ./Element-*.AppImage

Тестирование звонков

Открыть https://element.m.localhost в двух разных браузерных профилях
(или в двух разных браузерах).

Войти как @alex и @test.

Создать Direct Message между ними.

Начать аудио- или видеозвонок через Element Call.

Legacy call в Element Web использует другую инфраструктуру (не MatrixRTC)
и в этом стенде не тестируется.

Известные особенности

user_directory.search_all_users по умолчанию выключен. В
synapse/homeserver.yaml он включён, иначе Element не сможет находить
пользователей для DM, пока у них нет общих комнат.

/livekit/sfu - Caddy срезает этот префикс перед проксированием в
LiveKit, иначе API LiveKit отвечает 404. Это уже настроено в Caddyfile.

OpenID через 8448 - lk-jwt для проверки токена обращается к
federation-эндпоинту Synapse. В compose.override.yaml для этого
добавлен сетевой алиас и проброс 127.0.0.1:8448.

LIVEKIT_INSECURE_SKIP_VERIFY_TLS включено только для локального теста,
поскольку Caddy использует приватный CA. На VPS это нужно выключить.

LIVEKIT_REDIS_URL не задан - сервис работает на in-memory store. Для
одного узла этого достаточно.

Перенос на VPS

Стенд рассчитан на последующий перенос в продакшн. Что изменится:

реальный публичный DNS вместо *.m.localhost;

доверенный TLS (Let's Encrypt через Caddy) вместо tls internal;

LIVEKIT_INSECURE_SKIP_VERIFY_TLS выключить;

открыть в firewall: 443/tcp, 80/tcp, 7881/tcp, 7882/udp, 3478/udp
(и 8448/tcp, если нужна федерация);

HOST_LAN_IP заменить на публичный IP или использовать
use_external_ip: true в livekit.yaml.

Структура проекта

element-matrix-lab/
.env сгенерированные секреты
Caddyfile reverse proxy конфиг
compose.yaml основной стек
compose.override.yaml локальные фиксы для 8448 и алиасов
caddy-root.crt корневой CA Caddy
install-element-matrix-local.sh
start.sh / stop.sh / status.sh / logs.sh / create-user.sh
element/
config.json
livekit/
livekit.yaml
synapse/
homeserver.yaml
*.signing.key
*.log.config

Версии компонентов

Synapse 1.161.0
Element Web 1.12.30
LiveKit 1.13.7
lk-jwt-service 0.7.0
PostgreSQL 16-alpine
Caddy 2.11.4-alpine

Обрати внимание: образ lk-jwt-service использует тег 0.7.0 БЕЗ префикса
v. Тег v0.7.0 в registry отсутствует.
