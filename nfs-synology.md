# Configuration NFS — NAS Synology

Ce document détaille la configuration côté Synology pour l'externalisation des pièces jointes GLPI via NFS.

---

## Pourquoi NFS et pas SMB ?

GLPI tourne sous `www-data` (UID 33). NFS authentifie via les UID/GID Linux, ce qui permet de propager les droits correctement depuis la VM jusqu'au NAS sans mapping supplémentaire. SMB nécessite une couche d'authentification supplémentaire et pose des problèmes de permissions sur les fichiers cachés (`.htaccess`, etc.).

---

## Configuration Synology DSM

### 1. Créer le dossier partagé

`Panneau de configuration > Dossier partagé > Créer`

| Paramètre | Valeur |
|-----------|--------|
| Nom | `GLPI-PROD_NFS` |
| Cacher dans "Mes emplacements réseaux" | Oui |
| Activer la corbeille | Non |

### 2. Configurer la règle NFS

`Panneau de configuration > Services de fichiers > NFS > Activer NFS`

Puis dans les propriétés du dossier partagé, onglet **NFS** :

| Paramètre | Valeur |
|-----------|--------|
| Nom d'hôte ou IP | IP du serveur GLPI cible |
| Privilège | Lecture/écriture |
| Squash | **Pas de mappage** |
| Activer le mode asynchrone | Oui |
| Permettre les connexions depuis des ports non privilégiés | Non |
| Permettre à des utilisateurs de monter des sous-dossiers NFS | Oui |

> **Squash = "Pas de mappage"** est le paramètre critique. Les autres options ("Mapper tous les utilisateurs sur admin" ou "Mapper l'utilisateur root sur admin") remplacent l'UID de `www-data` (33) par celui d'admin, ce qui casse les écritures depuis GLPI.

---

## Vérification côté serveur GLPI

Après montage :

```bash
df -h | grep glpi
```

Résultat attendu :

```
<IP_NAS>:/volume1/GLPI-PROD_NFS   32T  xT   xT  x%  /mnt/glpi-syno-data
/mnt/glpi-syno-data                32T  xT   xT  x%  /var/lib/glpi/files
```

Test d'écriture sous www-data :

```bash
sudo -u www-data touch /var/lib/glpi/files/test_write && \
  echo "Écriture OK" && \
  sudo rm /var/lib/glpi/files/test_write
```

---

## Options fstab expliquées

```
<IP_NAS>:/volume1/GLPI-PROD_NFS /mnt/glpi-syno-data nfs _netdev,vers=4.1,hard,timeo=600,retrans=5,rsize=1048576,wsize=1048576,noatime 0 0
/mnt/glpi-syno-data /var/lib/glpi/files none bind 0 0
```

| Option | Rôle |
|--------|------|
| `_netdev` | Attend que le réseau soit disponible avant de monter |
| `vers=4.1` | NFS v4.1 — plus stable que 4.0 |
| `hard` | Attend le NAS indéfiniment au lieu d'échouer — évite la corruption si le NAS redémarre |
| `timeo=600` | Timeout de 60 secondes par tentative |
| `retrans=5` | 5 tentatives avant erreur |
| `rsize/wsize=1048576` | Blocs de 1 Mo — performances réseau optimisées |
| `noatime` | Ne met pas à jour la date d'accès à chaque lecture — réduit les écritures inutiles |
| `bind` | Monte `/mnt/glpi-syno-data` sur `/var/lib/glpi/files` — GLPI voit ses fichiers au chemin habituel |
