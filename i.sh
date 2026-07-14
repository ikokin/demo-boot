#!/bin/bash
# Полная установка демо-стенда Mebel CRM ОДНОЙ командой, изнутри сервера.
# Запуск в веб-консоли (root):
#   curl -sL <short-url> | bash
#
# Идемпотентно: повторный запуск не ломает уже установленное.
# Требует: Ubuntu 22.04, ~2 ГБ RAM (добавляем swap), домен уже указывает на этот сервер.
set -e
export DEBIAN_FRONTEND=noninteractive

DOMAIN="${DOMAIN:-optimizatorai.com}"
APP_DIR=/opt/mebel-crm
FILES_DIR=/opt/mebel-crm-files
PORT=3101
SA_PASSWORD="Mebel_Demo_$(hostname | md5sum | cut -c1-8)Aa1!"
LOG() { echo ""; echo "===== $* ====="; }

# --- 0. SSH-ключ Ивана (чтобы дальше можно было и напрямую) ---
mkdir -p /root/.ssh && chmod 700 /root/.ssh
grep -q "IMnA15IoSi6mv6wYgbw37DcVpazOmdDKnfCiKJog" /root/.ssh/authorized_keys 2>/dev/null || \
  echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMnA15IoSi6mv6wYgbw37DcVpazOmdDKnfCiKJog+bSM ivankokin" >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

# --- 1. Swap (страховка на 2 ГБ RAM под MS SQL) ---
if [ ! -f /swapfile ]; then
  LOG "Создаю swap 2G"
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  grep -q /swapfile /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab
fi

# --- 2. Пакеты: docker, node, nginx, certbot, git ---
LOG "Устанавливаю пакеты (docker, node 22, nginx, certbot)"
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg git nginx >/dev/null
if ! command -v docker >/dev/null; then
  curl -fsSL https://get.docker.com | sh >/dev/null 2>&1
fi
if ! command -v node >/dev/null || [ "$(node -v | cut -c2-3)" -lt 20 ]; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null 2>&1
  apt-get install -y -qq nodejs >/dev/null
fi
command -v certbot >/dev/null || apt-get install -y -qq certbot python3-certbot-nginx >/dev/null

# --- 3. MS SQL в Docker ---
LOG "Поднимаю MS SQL (Docker)"
if ! docker ps -a --format '{{.Names}}' | grep -q '^mebel-mssql$'; then
  docker run -d --name mebel-mssql --restart unless-stopped \
    -e ACCEPT_EULA=Y -e "MSSQL_SA_PASSWORD=$SA_PASSWORD" -e MSSQL_PID=Express \
    -p 127.0.0.1:1433:1433 -v mebel-mssql-data:/var/opt/mssql \
    mcr.microsoft.com/mssql/server:2022-latest >/dev/null
  echo "Жду старта MS SQL (60с)..."; sleep 60
else
  docker start mebel-mssql >/dev/null 2>&1 || true
  # если контейнер уже был — берём его пароль из env
  SA_PASSWORD=$(docker inspect mebel-mssql --format '{{range .Config.Env}}{{println .}}{{end}}' | grep MSSQL_SA_PASSWORD | cut -d= -f2)
  sleep 5
fi

# --- 4. Код ---
LOG "Клонирую/обновляю код"
if [ -d "$APP_DIR/.git" ]; then
  cd "$APP_DIR" && git pull --ff-only
else
  git clone https://github.com/ikokin/mebel-crm "$APP_DIR"
fi
mkdir -p "$FILES_DIR"

# --- 5. .env ---
LOG "Пишу .env"
JWT=$(node -e "console.log(require('crypto').randomBytes(48).toString('hex'))")
cat > "$APP_DIR/backend/.env" <<ENVEOF
DATABASE_URL="sqlserver://localhost:1433;database=crm_mebel;user=sa;password=$SA_PASSWORD;encrypt=true;trustServerCertificate=true"
JWT_SECRET="$JWT"
PORT=$PORT
FILES_DIR=$FILES_DIR
ENVEOF

# --- 6. Сборка + миграции + демо-данные ---
LOG "Собираю backend"
cd "$APP_DIR/backend"
npm install --no-audit --no-fund
npx tsx scripts/create-db.ts
npx prisma migrate deploy
npx prisma generate
npm run build
npm run seed:demo
LOG "Собираю frontend"
cd "$APP_DIR/frontend"
npm install --no-audit --no-fund
npm run build

# --- 7. systemd-служба ---
LOG "Ставлю службу"
cp "$APP_DIR/deploy/mebel-crm.service" /etc/systemd/system/mebel-crm.service
# служба под root (демо), путь к node абсолютный
sed -i "s#^User=.*#User=root#; s#^Group=.*#Group=root#; s#^ExecStart=.*#ExecStart=$(command -v node) --env-file=.env dist/index.js#" /etc/systemd/system/mebel-crm.service
systemctl daemon-reload
systemctl enable mebel-crm >/dev/null 2>&1
systemctl restart mebel-crm
sleep 3

# --- 8. nginx (рядом с существующими сайтами, свой конфиг) ---
LOG "Настраиваю nginx для $DOMAIN"
sed "s/optimizatorai.com/$DOMAIN/g; s#127.0.0.1:3101#127.0.0.1:$PORT#g" \
  "$APP_DIR/deploy/nginx-optimizatorai.conf" > /etc/nginx/sites-available/mebel-crm.conf
ln -sf /etc/nginx/sites-available/mebel-crm.conf /etc/nginx/sites-enabled/mebel-crm.conf
nginx -t && systemctl reload nginx

# --- 9. HTTPS ---
LOG "Выпускаю HTTPS-сертификат"
certbot --nginx -d "$DOMAIN" -d "www.$DOMAIN" --non-interactive --agree-tos \
  -m ${CERTBOT_EMAIL} --redirect || echo "!! certbot не смог (проверь, что $DOMAIN указывает на этот сервер) — сайт пока по http"

# --- 10. Итог ---
LOG "ПРОВЕРКА"
sleep 2
echo "локально приложение:"; curl -s -o /dev/null -w "  http://127.0.0.1:$PORT -> %{http_code}\n" http://127.0.0.1:$PORT/
systemctl is-active mebel-crm && echo "служба mebel-crm: активна"
echo ""
echo "############################################"
echo "#  ДЕМО-СТЕНД ГОТОВ: https://$DOMAIN"
echo "#  Логины (пароль у всех: Demo2026!):"
echo "#    admin@demo  rop@demo  manager@demo"
echo "#    raschet@demo  konstruktor@demo  fasad@demo  ceh@demo"
echo "############################################"
echo "=== DEPLOY-DONE ==="
