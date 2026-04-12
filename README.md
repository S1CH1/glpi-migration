# glpi-migration

Script et procédure pour migrer une instance GLPI entre deux serveurs Ubuntu Server 24.04, avec externalisation des pièces jointes sur NAS Synology via NFS.

Testé sur GLPI 11.0.4 / Apache 2.4 / PHP 8.3 FPM / MariaDB 10.11.

---

## Contenu

```
glpi-migration/
├── migrate.sh            # Script d'automatisation
├── config.example.env    # Variables à renseigner
├── PROCEDURE.md          # Procédure pas-à-pas (migration manuelle)
└── docs/
    └── nfs-synology.md   # Configuration NFS Synology détaillée
```

---

## Utilisation rapide

```bash
# 1. Cloner le repo sur la machine source ou cible
git clone https://github.com/<toi>/glpi-migration.git
cd glpi-migration

# 2. Créer et renseigner le fichier de config
cp config.example.env .env
nano .env

# 3. Rendre le script exécutable
chmod +x migrate.sh

# 4. Lancer la migration complète
./migrate.sh --source    # Depuis la machine source : dump + transferts
./migrate.sh --target    # Depuis la machine cible  : installation + config
./migrate.sh --nfs       # Optionnel : externalisation vers NAS Synology
```

Ou en une seule commande (sans NFS) :

```bash
./migrate.sh --full
```

---

## Prérequis

- Ubuntu Server 24.04 sur les deux machines
- SSH sans mot de passe configuré entre source et cible (`ssh-copy-id`)
- L'utilisateur SSH doit avoir accès sudo
- Pour le NFS : partage Synology créé avec règle NFS configurée (voir [`docs/nfs-synology.md`](./docs/nfs-synology.md))

---

## Ce que fait le script

**`--source`** — sur le serveur GLPI existant :
- Dump MariaDB avec `--single-transaction`
- `rsync` des sources GLPI (sans le dossier `files/`)
- `rsync` des pièces jointes (sans les caches et sessions)
- Transfert de `/etc/glpi/` (dont `glpicrypt.key`)

**`--target`** — sur le nouveau serveur :
- Installation des paquets (Apache, PHP 8.3, MariaDB, extensions GLPI)
- Déploiement des sources et configuration des droits
- Configuration PHP-FPM et VirtualHost Apache
- Création de la base MariaDB et import du dump
- Mise à jour du schéma BDD (`database:update`) et vidage du cache
- Configuration du cron `www-data` et des fuseaux horaires MySQL

**`--nfs`** — optionnel, après `--target` :
- Montage NFS du partage Synology
- Migration des pièces jointes vers le NAS
- Configuration du bind mount dans `/etc/fstab`

---

## Migration manuelle

Si tu préfères exécuter les étapes à la main, la [procédure complète](./PROCEDURE.md) documente chaque commande avec les vérifications et les résultats attendus.

---

## Problèmes connus

Voir la section [Problèmes rencontrés](./PROCEDURE.md#problèmes-rencontrés-lors-de-la-migration-initiale) dans la procédure. Les points d'attention principaux :

- `glpicrypt.key` doit être copié — sans lui, les mots de passe SMTP et collecteurs sont perdus
- Squash NFS : configurer sur **"Pas de mappage"** sur le Synology, sinon `chown www-data` échoue
- Mot de passe contenant `!` : toujours utiliser des guillemets simples dans les commandes mysql

---

## Stack

| Composant | Version |
|-----------|---------|
| GLPI | 11.0.4 |
| OS | Ubuntu Server 24.04 |
| Web | Apache 2.4 + PHP 8.3 FPM |
| BDD | MariaDB 10.11 |
| Stockage | NAS Synology (NFS v4.1) |

---

## Licence

MIT
