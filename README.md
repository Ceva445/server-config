# server-config

Конфігурація домашнього сервера (NucBox, Ubuntu) для проектів під доменом
`piatek-magazyn.com`, опублікованих через Cloudflare Tunnel.

## Що тут лежить

| Файл | Призначення |
|---|---|
| `startup.sh` | Автозапуск: Wi-Fi → git pull → docker compose up --build → перевірка стану → логи/алерти |
| `apps-startup.service` | systemd-юніт, який запускає `startup.sh` при завантаженні |
| `cloudflared/config.yml` | Ingress-правила тунелю (субдомен → локальний порт) |
| `install.sh` | Розкатує все перелічене на сервер |
| `templates/` | Шаблони секретних конфігів (реальні — тільки на сервері, у git не комітяться) |

## Архітектура

- Кожен проект — тека в `~/Desktop/apps/<назва>` зі своїм `docker-compose.yml`
  (окремий контейнер застосунку + окремий Postgres).
- Ця тека репозиторію на сервері — `~/Desktop/apps/configs` (виключена з циклу проектів).
- Порти: pinokio → 8000, szafa → 8001; наступний проект → 8002 і далі.
- Cloudflare Tunnel (`cloudflared`, systemd) роздає субдомени на локальні порти,
  жодних відкритих портів на роутері.

## Як розгорнути зміни

```bash
cd ~/Desktop/apps/configs
git pull
bash install.sh
```

## Як додати новий проект

1. Склонувати репозиторій проекту в `~/Desktop/apps/<назва>` (гілка з docker-compose).
2. Покласти його `.env` (через scp, у git він не живе).
3. Додати в `cloudflared/config.yml` (у ЦЬОМУ репо) блок перед `http_status:404`:
   ```yaml
   - hostname: <назва>.piatek-magazyn.com
     service: http://localhost:<порт>
   ```
4. Створити DNS-запис: `cloudflared tunnel route dns piatek <назва>.piatek-magazyn.com`
5. `git pull` + `bash install.sh` на сервері — тунель підхопить новий маршрут,
   а `startup.sh` при наступному старті підніме проект автоматично.
   Одразу запустити вручну: `sudo systemctl restart apps-startup`.

## Секрети (тільки на сервері)

- `wifi.txt` — `SSID=` / `PASSWORD=` мережі, до якої підключатися після ребуту.
- `healthcheck.txt` — один рядок з URL, куди POST-яться логи впалих контейнерів
  (порожній файл = логи лишаються лише локально в `logs/`).
- `.env` кожного проекту — в теці самого проекту.

## Відновлення сервера з нуля

1. Встановити Ubuntu, docker.io, docker-compose-v2, git, cloudflared.
2. `cloudflared tunnel login` + `cloudflared tunnel create piatek`
   (або перенести збережений `~/.cloudflared/*.json` зі старого сервера).
3. `git clone https://github.com/Ceva445/server-config.git ~/Desktop/apps/configs`
4. Заповнити `wifi.txt`, `healthcheck.txt`, склонувати проекти, розкласти `.env`-файли.
5. `bash ~/Desktop/apps/configs/install.sh`
