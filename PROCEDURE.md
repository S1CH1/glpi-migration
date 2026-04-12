# Procédure de migration manuelle

> Cette procédure couvre la migration pas-à-pas d'une instance GLPI 11.0.4 entre deux serveurs Ubuntu Server 24.04, avec externalisation des pièces jointes sur NAS Synology via NFS.
>
> Si tu veux automatiser la migration, utilise [`migrate.sh`](./migrate.sh) à la place.

---

## Stack

| Composant | Version |
|-----------|---------|
| GLPI | 11.0.4 |
| OS | Ubuntu Server 24.04 |
| Web | Apache 2.4 + PHP 8.3 FPM |
| BDD | MariaDB 10.11 |

## Prérequis

- Accès SSH aux deux machines (`<IP_SOURCE>` et `<IP_CIBLE>`)
- Clés SSH configurées entre source et cible (pour les rsync)
- Accès SSH au NAS Synology (partage NFS à créer manuellement, voir étape 12)
- Prévoir une fenêtre de maintenance (GLPI indisponible pendant la migration)

> Conseil pratique : ouvrir deux terminaux, un par serveur.

---

## Étape 1 — Préparation de la machine cible

**Sur `<IP_CIBLE>`**

```bash
sudo apt-get update && sudo apt-get upgrade -y
sudo timedatectl set-timezone Europe/Paris
sudo timedatectl set-ntp true
```

Vérifier la connectivité vers la source :

```bash
ping -c 3 <IP_SOURCE>
```

> Si le ping échoue, les transferts rsync de l'étape 4 échoueront.

---

## Étape 2 — Installation des paquets

**Sur `<IP_CIBLE>`**

```bash
sudo apt-get install -y \
  apache2 \
  php8.3 php8.3-fpm php8.3-mysql php8.3-curl php8.3-gd php8.3-intl \
  php8.3-xml php8.3-zip php8.3-mbstring php8.3-imap php8.3-ldap \
  php8.3-xmlrpc php8.3-opcache php8.3-bz2 php8.3-bcmath \
  mariadb-server rsync nfs-common
```

Vérification :

```bash
php8.3 -v && apache2 -v && mysql --version
```

---

## Étape 3 — Structure des dossiers

**Sur `<IP_CIBLE>`**

```bash
sudo mkdir -p /etc/glpi /var/lib/glpi/files /var/log/glpi /var/www/glpi
```

---

## Étape 4 — Export et transfert depuis la source

**Sur `<IP_SOURCE>`**

### a) Dump de la base

```bash
mysqldump -u adm_glpi -p \
  --single-transaction --routines --triggers \
  glpi_prod > ~/glpi_migration.sql
```

Vérifier que le dump n'est pas vide :

```bash
du -sh ~/glpi_migration.sql
```

> Attendu : ~50-60 Mo. Un fichier de quelques Ko indique un dump raté.

### b) Transfert des sources GLPI

```bash
rsync -az --progress --exclude='files/' \
  /var/www/glpi/ \
  adm_glpi@<IP_CIBLE>:/tmp/glpi_src/
```

### c) Transfert des pièces jointes

```bash
rsync -az --progress \
  --exclude='_sessions/' --exclude='_cache/' \
  --exclude='_tmp/' --exclude='_lock/' \
  /var/lib/glpi/files/ \
  adm_glpi@<IP_CIBLE>:/tmp/glpi_files/
```

### d) Transfert du dump SQL

```bash
scp ~/glpi_migration.sql adm_glpi@<IP_CIBLE>:~/
```

### e) Transfert de `/etc/glpi`

> ⚠️ Point critique — `glpicrypt.key` chiffre les mots de passe SMTP et collecteurs stockés en base. Sans ce fichier, tous les mots de passe sont à re-saisir après migration.

```bash
mkdir -p ~/glpi_etc_tmp
sudo cp -r /etc/glpi/. ~/glpi_etc_tmp/
sudo chown -R adm_glpi:adm_glpi ~/glpi_etc_tmp
rsync -az ~/glpi_etc_tmp/ adm_glpi@<IP_CIBLE>:/tmp/glpi_etc/
```

Vérification depuis la source :

```bash
ssh adm_glpi@<IP_CIBLE> "
  echo '=== /tmp/glpi_etc/ ===' && ls /tmp/glpi_etc/
  echo '=== /tmp/glpi_src/ ===' && ls /tmp/glpi_src/ | head -5
  echo '=== dump SQL ===' && du -sh ~/glpi_migration.sql"
```

Résultat attendu dans `/tmp/glpi_etc/` : `config_db.php  glpicrypt.key  local_define.php  oauth.pem  oauth.pub`

---

## Étape 5 — Déploiement des fichiers

**Sur `<IP_CIBLE>`**

```bash
# Sources GLPI
sudo cp -a /tmp/glpi_src/. /var/www/glpi/

# Pièces jointes
sudo mkdir -p /var/lib/glpi/files/{_cache,_cron,_graphs,_inventories,_locales,_lock,_log,_rss,_sessions,_themes,_tmp,_uploads}
sudo cp -a /tmp/glpi_files/. /var/lib/glpi/files/

# Configuration
sudo cp -r /tmp/glpi_etc/* /etc/glpi/

# Droits
sudo chown -R www-data:www-data /var/www/glpi /var/lib/glpi /var/log/glpi /etc/glpi
sudo chmod 640 /etc/glpi/*
```

---

## Étape 6 — Configuration PHP-FPM

**Sur `<IP_CIBLE>`**

```bash
sudo tee /etc/php/8.3/fpm/conf.d/99-glpi.ini > /dev/null << 'EOF'
upload_max_filesize = 20M
post_max_size = 20M
max_execution_time = 60
memory_limit = 256M
session.cookie_httponly = On
EOF
```

---

## Étape 7 — VirtualHost Apache

**Sur `<IP_CIBLE>`**

```bash
sudo tee /etc/apache2/sites-available/glpi.conf > /dev/null << 'EOF'
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
        SetHandler "proxy:unix:/run/php/php8.3-fpm.sock|fcgi://localhost/"
    </FilesMatch>
</VirtualHost>
EOF

sudo a2enmod rewrite proxy_fcgi setenvif
sudo a2enconf php8.3-fpm
sudo a2ensite glpi.conf
sudo a2dissite 000-default.conf
sudo apache2ctl configtest
```

> Résultat attendu : `Syntax OK`

---

## Étape 8 — Base de données

**Sur `<IP_CIBLE>`**

```bash
sudo mysql -e "
  CREATE DATABASE glpi_prod CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
  CREATE USER 'adm_glpi'@'localhost' IDENTIFIED BY '<MOT_DE_PASSE_BDD>';
  GRANT ALL PRIVILEGES ON glpi_prod.* TO 'adm_glpi'@'localhost';
  FLUSH PRIVILEGES;"
```

Import du dump :

```bash
mysql -u adm_glpi -p glpi_prod < ~/glpi_migration.sql
```

Mise à jour de l'URL de base :

```bash
mysql -u adm_glpi -p glpi_prod -e \
  "UPDATE glpi_configs SET value='http://<IP_CIBLE>' WHERE name='url_base';"
```

---

## Étape 9 — Démarrage des services

**Sur `<IP_CIBLE>`**

```bash
sudo systemctl enable apache2 php8.3-fpm mariadb
sudo systemctl start apache2 php8.3-fpm mariadb
```

Vérification :

```bash
sudo systemctl status apache2 php8.3-fpm mariadb | grep -E "Active|●"
```

---

## Étape 10 — Schéma BDD et cache

**Sur `<IP_CIBLE>`**

```bash
sudo -u www-data php /var/www/glpi/bin/console database:update --no-interaction
sudo rm -rf /var/lib/glpi/files/_cache/* /var/lib/glpi/files/_sessions/*
sudo -u www-data php /var/www/glpi/bin/console cache:clear
```

Test HTTP :

```bash
curl -s -o /dev/null -w 'HTTP %{http_code}\n' http://localhost/
```

> HTTP 200 = OK. HTTP 500 → `sudo tail -30 /var/log/glpi/php-errors.log`

---

## Étape 11 — Cron et fuseaux horaires

**Sur `<IP_CIBLE>`**

```bash
# Fuseaux horaires MySQL
mysql_tzinfo_to_sql /usr/share/zoneinfo | sudo mysql -u root mysql

# Crontab www-data
sudo crontab -u www-data -e
```

Ajouter :

```
*/1 * * * * /usr/bin/php /var/www/glpi/front/cron.php --force
*/1 * * * * /usr/bin/php /var/www/glpi/front/cron.php --force mailgate
*/1 * * * * /usr/bin/php /var/www/glpi/front/cron.php --force queuednotification
```

---

## Étape 12 — Externalisation NFS (Synology)

### a) Configuration Synology

Créer le dossier partagé `GLPI-PROD_NFS`, puis configurer la règle NFS :

| Paramètre | Valeur |
|-----------|--------|
| Hôte | `<IP_CIBLE>` |
| Privilège | Lecture/écriture |
| Squash | **Pas de mappage** |
| Mode asynchrone | Activé |
| Ports non privilégiés | Désactivé |
| Montage de sous-dossiers | Activé |

> **Pourquoi "Pas de mappage" ?** NFS authentifie via les UID/GID Linux. Ce mode laisse passer `www-data` (UID 33) tel quel, ce qui autorise les écritures sans erreur de permission.

### b) Montage et droits

```bash
sudo mkdir -p /mnt/glpi-syno-data
sudo mount -t nfs -o vers=4 <IP_NAS>:/volume1/GLPI-PROD_NFS /mnt/glpi-syno-data
sudo chown -R www-data:www-data /mnt/glpi-syno-data
```

### c) fstab

```bash
sudo nano /etc/fstab
```

Ajouter :

```
<IP_NAS>:/volume1/GLPI-PROD_NFS /mnt/glpi-syno-data nfs _netdev,vers=4.1,hard,timeo=600,retrans=5,rsize=1048576,wsize=1048576,noatime 0 0
/mnt/glpi-syno-data /var/lib/glpi/files none bind 0 0
```

```bash
sudo systemctl daemon-reload
```

### d) Transfert des pièces jointes existantes

```bash
sudo systemctl stop apache2
sudo umount /var/lib/glpi/files 2>/dev/null || true

# Déplacer les fichiers (y compris les fichiers cachés .htaccess etc.)
sudo mv /var/lib/glpi/files/* /mnt/glpi-syno-data/
sudo mv /var/lib/glpi/files/.* /mnt/glpi-syno-data/ 2>/dev/null || true

sudo mount -a
sudo systemctl start apache2
```

Vérification :

```bash
df -h | grep glpi
```

Les deux lignes attendues :

```
<IP_NAS>:/volume1/GLPI-PROD_NFS   ...  /mnt/glpi-syno-data
/mnt/glpi-syno-data               ...  /var/lib/glpi/files
```

---

## Étape 13 — Configuration post-migration (interface GLPI)

Se connecter sur `http://<IP_CIBLE>` avec le compte super-admin.

**SMTP** : `Configuration > Notifications > Suivi par courriel`

**Collecteurs mail** : `Configuration > Collecteurs` — tester chaque collecteur.

**Plugins** : `Administration > Plugins` — cliquer "Mettre à jour" si proposé.

---

## Checklist de validation

- [ ] Connexion admin sur `http://<IP_CIBLE>`
- [ ] Ouvrir un ticket existant — suivis et pièces jointes visibles
- [ ] Créer un ticket test et joindre un fichier
- [ ] Envoyer une notification test (`Configuration > Notifications > Tester`)
- [ ] Vérifier que le cron tourne : `journalctl -u cron | grep www-data | tail -5`
- [ ] Pièces jointes stockées sur le NAS : `df -h | grep glpi`
- [ ] Plugins tous actifs : `Administration > Plugins`

---

## Problèmes rencontrés lors de la migration initiale

| Date | Symptôme | Cause | Fix |
|------|----------|-------|-----|
| 08/03/2026 | Erreur PHP au démarrage | `php8.3-bcmath` manquant | Ajouté à la liste des paquets (étape 2) |
| 08/03/2026 | `/etc/glpi` vide après copie | `cp` sans `-r` sur un dossier | Utiliser `cp -r /etc/glpi/.` |
| 08/03/2026 | Erreur connexion BDD | Mot de passe avec `!` cassé par bash | Toujours encapsuler le mot de passe en guillemets simples dans les commandes mysql |
| 11/03/2026 | `chown` échoue sur le NAS | Squash NFS configuré sur "admin" | Passer le Squash à "Pas de mappage" sur le Synology |
| 11/03/2026 | `.htaccess` non déplacé par `mv *` | `*` n'attrape pas les fichiers cachés | Ajouter `mv /var/lib/glpi/files/.*` |

---

## Sources

- [Documentation officielle GLPI](https://glpi-install.readthedocs.io)
- [Releases GLPI sur GitHub](https://github.com/glpi-project/glpi/releases)
