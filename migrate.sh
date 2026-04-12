#!/usr/bin/env bash
# migrate.sh — Migration GLPI entre deux serveurs Ubuntu 24.04
# Usage : sudo ./migrate.sh [--source | --target | --full]
# Prérequis : renseigner .env (voir config.example.env)

set -euo pipefail

# ─── Couleurs ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

log()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ─── Chargement de la config ──────────────────────────────────────────────────
ENV_FILE="$(dirname "$0")/.env"
[[ -f "$ENV_FILE" ]] || die ".env introuvable. Copier config.example.env en .env et renseigner les valeurs."
# shellcheck source=/dev/null
source "$ENV_FILE"

# Vérification des variables obligatoires
for var in SOURCE_IP TARGET_IP SSH_USER DB_NAME DB_USER DB_PASS; do
  [[ -n "${!var:-}" ]] || die "Variable \$$var non renseignée dans .env"
done

# ─── Fonctions utilitaires ────────────────────────────────────────────────────
check_ssh() {
  local host="$1"
  ssh -o ConnectTimeout=5 -o BatchMode=yes "${SSH_USER}@${host}" exit 2>/dev/null \
    || die "SSH vers ${SSH_USER}@${host} échoue. Vérifier les clés SSH et l'accès réseau."
}

remote_target() {
  ssh "${SSH_USER}@${TARGET_IP}" "$@"
}

remote_source() {
  ssh "${SSH_USER}@${SOURCE_IP}" "$@"
}

# ─── Phase SOURCE : export et transfert ───────────────────────────────────────
phase_source() {
  log "=== PHASE SOURCE (${SOURCE_IP}) ==="

  log "Vérification SSH source..."
  check_ssh "$SOURCE_IP"
  ok "SSH source OK"

  log "Dump de la base de données ${DB_NAME}..."
  remote_source "mysqldump -u ${DB_USER} -p'${DB_PASS}' \
    --single-transaction --routines --triggers \
    ${DB_NAME} > ~/glpi_migration.sql"

  local dump_size
  dump_size=$(remote_source "du -sh ~/glpi_migration.sql | cut -f1")
  ok "Dump créé : ${dump_size}"

  log "Transfert des sources GLPI vers la cible..."
  remote_source "rsync -az --progress --exclude='files/' \
    ${GLPI_WEB_DIR}/ \
    ${SSH_USER}@${TARGET_IP}:/tmp/glpi_src/"
  ok "Sources transférées"

  log "Transfert des pièces jointes..."
  remote_source "rsync -az --progress \
    --exclude='_sessions/' --exclude='_cache/' \
    --exclude='_tmp/' --exclude='_lock/' \
    ${GLPI_DATA_DIR}/files/ \
    ${SSH_USER}@${TARGET_IP}:/tmp/glpi_files/"
  ok "Pièces jointes transférées"

  log "Transfert du dump SQL..."
  remote_source "scp ~/glpi_migration.sql ${SSH_USER}@${TARGET_IP}:~/"
  ok "Dump SQL transféré"

  log "Transfert de la configuration /etc/glpi..."
  remote_source "mkdir -p ~/glpi_etc_tmp && \
    sudo cp -r ${GLPI_ETC_DIR}/. ~/glpi_etc_tmp/ && \
    sudo chown -R ${SSH_USER}:${SSH_USER} ~/glpi_etc_tmp && \
    rsync -az ~/glpi_etc_tmp/ ${SSH_USER}@${TARGET_IP}:/tmp/glpi_etc/"
  ok "Configuration /etc/glpi transférée"

  log "Vérification des transferts sur la cible..."
  remote_source "ssh ${SSH_USER}@${TARGET_IP} '
    echo \"=== /tmp/glpi_etc/ ===\"  && ls /tmp/glpi_etc/
    echo \"=== /tmp/glpi_src/ (5 premiers) ===\" && ls /tmp/glpi_src/ | head -5
    echo \"=== dump SQL ===\" && du -sh ~/glpi_migration.sql
  '"
  ok "=== Phase source terminée ==="
}

# ─── Phase TARGET : installation et configuration ─────────────────────────────
phase_target() {
  log "=== PHASE TARGET (${TARGET_IP}) ==="

  log "Vérification SSH cible..."
  check_ssh "$TARGET_IP"
  ok "SSH cible OK"

  log "Mise à jour du système..."
  remote_target "sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq"
  ok "Système à jour"

  log "Configuration du fuseau horaire..."
  remote_target "sudo timedatectl set-timezone Europe/Paris && sudo timedatectl set-ntp true"
  ok "Timezone : Europe/Paris"

  log "Test de connectivité réseau vers la source..."
  remote_target "ping -c 3 ${SOURCE_IP} > /dev/null" \
    || die "La cible ne ping pas la source. Régler le problème réseau avant de continuer."
  ok "Connectivité source OK"

  log "Installation des paquets..."
  remote_target "sudo apt-get install -y -qq \
    apache2 \
    php8.3 php8.3-fpm php8.3-mysql php8.3-curl php8.3-gd php8.3-intl \
    php8.3-xml php8.3-zip php8.3-mbstring php8.3-imap php8.3-ldap \
    php8.3-xmlrpc php8.3-opcache php8.3-bz2 php8.3-bcmath \
    mariadb-server rsync nfs-common"
  ok "Paquets installés"

  log "Création de la structure des dossiers..."
  remote_target "sudo mkdir -p \
    ${GLPI_ETC_DIR} \
    ${GLPI_DATA_DIR}/files \
    ${GLPI_LOG_DIR} \
    ${GLPI_WEB_DIR}"
  ok "Dossiers créés"

  log "Mise en place des fichiers sources..."
  remote_target "sudo cp -a /tmp/glpi_src/. ${GLPI_WEB_DIR}/"
  ok "Sources GLPI déployées"

  log "Mise en place des pièces jointes..."
  remote_target "sudo mkdir -p ${GLPI_DATA_DIR}/files/{_cache,_cron,_graphs,_inventories,_locales,_lock,_log,_rss,_sessions,_themes,_tmp,_uploads} && \
    sudo cp -a /tmp/glpi_files/. ${GLPI_DATA_DIR}/files/"
  ok "Pièces jointes déployées"

  log "Mise en place de la configuration /etc/glpi..."
  remote_target "sudo cp -r /tmp/glpi_etc/* ${GLPI_ETC_DIR}/"
  ok "Configuration GLPI déployée"

  log "Application des droits www-data..."
  remote_target "sudo chown -R www-data:www-data \
    ${GLPI_WEB_DIR} ${GLPI_DATA_DIR} ${GLPI_LOG_DIR} ${GLPI_ETC_DIR} && \
    sudo chmod 640 ${GLPI_ETC_DIR}/*"
  ok "Droits appliqués"

  log "Configuration PHP-FPM..."
  remote_target "sudo tee /etc/php/8.3/fpm/conf.d/99-glpi.ini > /dev/null << 'EOF'
upload_max_filesize = 20M
post_max_size = 20M
max_execution_time = 60
memory_limit = 256M
session.cookie_httponly = On
EOF"
  ok "PHP-FPM configuré"

  log "Configuration Apache VirtualHost..."
  remote_target "sudo tee /etc/apache2/sites-available/glpi.conf > /dev/null << 'EOF'
<VirtualHost *:80>
    ServerName glpi-server
    DocumentRoot /var/www/glpi/public

    <Directory /var/www/glpi/public>
        Require all granted
        RewriteEngine On
        RewriteCond %{REQUEST_FILENAME} !-f
        RewriteRule ^(.*)$ index.php [QSA,L]
    </Directory>

    <FilesMatch \.php$>
        SetHandler \"proxy:unix:/run/php/php8.3-fpm.sock|fcgi://localhost/\"
    </FilesMatch>
</VirtualHost>
EOF
sudo a2enmod rewrite proxy_fcgi setenvif
sudo a2enconf php8.3-fpm
sudo a2ensite glpi.conf
sudo a2dissite 000-default.conf
sudo apache2ctl configtest"
  ok "Apache configuré"

  log "Configuration MariaDB..."
  remote_target "sudo mysql -e \"
    CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
    CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
    GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
    FLUSH PRIVILEGES;\""
  ok "Base ${DB_NAME} et user ${DB_USER} créés"

  log "Import du dump SQL (peut prendre 2-5 minutes)..."
  remote_target "mysql -u ${DB_USER} -p'${DB_PASS}' ${DB_NAME} < ~/glpi_migration.sql"
  ok "Dump importé"

  log "Mise à jour de l'URL de base..."
  remote_target "mysql -u ${DB_USER} -p'${DB_PASS}' ${DB_NAME} -e \
    \"UPDATE glpi_configs SET value='http://${TARGET_IP}' WHERE name='url_base';\""
  ok "URL de base mise à jour : http://${TARGET_IP}"

  log "Démarrage et activation des services..."
  remote_target "sudo systemctl enable apache2 php8.3-fpm mariadb && \
    sudo systemctl start apache2 php8.3-fpm mariadb"
  ok "Services démarrés"

  log "Mise à jour du schéma BDD..."
  remote_target "sudo -u www-data php ${GLPI_WEB_DIR}/bin/console database:update --no-interaction"
  ok "Schéma BDD à jour"

  log "Vidage du cache..."
  remote_target "sudo rm -rf ${GLPI_DATA_DIR}/files/_cache/* \
    ${GLPI_DATA_DIR}/files/_sessions/* && \
    sudo -u www-data php ${GLPI_WEB_DIR}/bin/console cache:clear"
  ok "Cache vidé"

  log "Chargement des fuseaux horaires MySQL..."
  remote_target "mysql_tzinfo_to_sql /usr/share/zoneinfo | sudo mysql -u root mysql"
  ok "Fuseaux horaires chargés"

  log "Configuration du cron www-data..."
  remote_target "sudo crontab -u www-data -l 2>/dev/null | grep -q 'cron.php' && \
    echo 'Cron déjà configuré, skip.' || \
    (echo '*/1 * * * * /usr/bin/php /var/www/glpi/front/cron.php --force
*/1 * * * * /usr/bin/php /var/www/glpi/front/cron.php --force mailgate
*/1 * * * * /usr/bin/php /var/www/glpi/front/cron.php --force queuednotification' \
    | sudo crontab -u www-data -)"
  ok "Cron configuré"

  log "Test HTTP final..."
  local http_code
  http_code=$(remote_target "curl -s -o /dev/null -w '%{http_code}' http://localhost/")
  [[ "$http_code" == "200" ]] || die "HTTP ${http_code} — vérifier les logs : sudo tail -30 ${GLPI_LOG_DIR}/php-errors.log"
  ok "HTTP 200 — GLPI répond sur http://${TARGET_IP}"

  ok "=== Phase target terminée ==="
}

# ─── NFS (optionnel, lancé séparément) ───────────────────────────────────────
phase_nfs() {
  [[ -n "${NAS_IP:-}" ]] || die "NAS_IP non renseigné dans .env"
  [[ -n "${NAS_SHARE:-}" ]] || die "NAS_SHARE non renseigné dans .env"

  log "=== PHASE NFS (${TARGET_IP} → ${NAS_IP}:${NAS_SHARE}) ==="
  warn "Prérequis Synology : partage ${NAS_SHARE} créé, règle NFS configurée pour ${TARGET_IP} avec Squash = 'Pas de mappage'."

  log "Création du point de montage..."
  remote_target "sudo mkdir -p ${NFS_MOUNT}"

  log "Test du montage NFS..."
  remote_target "sudo mount -t nfs -o vers=4 ${NAS_IP}:${NAS_SHARE} ${NFS_MOUNT}" \
    || die "Montage NFS échoue. Vérifier la règle NFS sur le Synology et la connectivité vers ${NAS_IP}."
  ok "Montage NFS OK"

  log "Application des droits sur le NAS..."
  remote_target "sudo chown -R www-data:www-data ${NFS_MOUNT}"

  log "Ajout dans /etc/fstab..."
  remote_target "grep -q '${NAS_IP}:${NAS_SHARE}' /etc/fstab && \
    echo 'Entrées fstab déjà présentes, skip.' || \
    sudo tee -a /etc/fstab > /dev/null << EOF
${NAS_IP}:${NAS_SHARE} ${NFS_MOUNT} nfs _netdev,vers=4.1,hard,timeo=600,retrans=5,rsize=1048576,wsize=1048576,noatime 0 0
${NFS_MOUNT} ${GLPI_DATA_DIR}/files none bind 0 0
EOF"
  remote_target "sudo systemctl daemon-reload"
  ok "fstab mis à jour"

  log "Transfert des pièces jointes vers le NAS..."
  remote_target "sudo systemctl stop apache2 && \
    sudo umount ${GLPI_DATA_DIR}/files 2>/dev/null || true && \
    sudo mv ${GLPI_DATA_DIR}/files/* ${NFS_MOUNT}/ 2>/dev/null || true && \
    sudo mv ${GLPI_DATA_DIR}/files/.* ${NFS_MOUNT}/ 2>/dev/null || true && \
    sudo mount -a && \
    sudo systemctl start apache2"
  ok "Pièces jointes déplacées sur le NAS"

  log "Vérification des montages..."
  remote_target "df -h | grep glpi"

  ok "=== Phase NFS terminée ==="
}

# ─── Résumé post-migration ────────────────────────────────────────────────────
summary() {
  echo ""
  echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║           MIGRATION TERMINÉE                        ║${NC}"
  echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo "  URL        : http://${TARGET_IP}"
  echo "  Comptes    : vérifier Administration > Utilisateurs"
  echo "  SMTP       : reconfigurer dans Configuration > Notifications"
  echo "  Collecteurs: reconfigurer dans Configuration > Collecteurs"
  echo "  Plugins    : vérifier dans Administration > Plugins"
  echo ""
  echo -e "${YELLOW}Checklist finale :${NC}"
  echo "  [ ] Ouvrir un ticket existant → suivis et pièces jointes visibles"
  echo "  [ ] Créer un ticket test et joindre un fichier"
  echo "  [ ] Envoyer une notification test"
  echo "  [ ] Vérifier que le cron tourne : journalctl -u cron | grep www-data | tail -5"
  echo "  [ ] Couper le GLPI source une fois validé"
  echo ""
}

# ─── Entrypoint ───────────────────────────────────────────────────────────────
usage() {
  echo "Usage : $0 [--source | --target | --nfs | --full]"
  echo ""
  echo "  --source   Export et transfert depuis le serveur source"
  echo "  --target   Installation et configuration sur le serveur cible"
  echo "  --nfs      Externalisation des pièces jointes vers NAS Synology"
  echo "  --full     Enchaîne --source + --target (sans NFS)"
  echo ""
  echo "Exemple migration complète avec NFS :"
  echo "  $0 --source && $0 --target && $0 --nfs"
}

case "${1:-}" in
  --source) phase_source ;;
  --target) phase_target && summary ;;
  --nfs)    phase_nfs ;;
  --full)   phase_source && phase_target && summary ;;
  *)        usage; exit 1 ;;
esac
