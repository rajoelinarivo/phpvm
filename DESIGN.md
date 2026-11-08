# phpvm — Gestionnaire de versions et d'extensions PHP pour Windows

> Nom provisoire : `phpvm`.
> Statut : **implémenté en PowerShell 5.1** (`bin\phpvm.ps1` + `bin\phpvm.cmd`), jalons M1 à M6 couverts (hors e2e sur VM propre et distribution). Testé avec PHP 8.3.36 NTS x64 : install, use, off/on, config, ext enable/disable, ext install xdebug (PECL), rollback d'un `php.ini` cassé, doctor.
>
> Écart par rapport à la conception : Go n'était pas installé sur la machine ; PowerShell 5.1 est présent sur tout Windows 10/11, donc aucun prérequis. Messages de l'outil en anglais ASCII. À l'installation, un jeu d'extensions courantes est activé (curl, fileinfo, mbstring, openssl, pdo_mysql, pdo_sqlite, mysqli, sqlite3, zip, intl, gd, exif) car Composer et la plupart des frameworks en ont besoin.

## 1. Objectif

Outil en ligne de commande pour Windows qui permet de :

- installer et désinstaller plusieurs versions de PHP côte à côte ;
- **activer / désactiver** une version PHP (basculer de l'une à l'autre, ou n'en avoir aucune d'active) ;
- configurer PHP (`php.ini`) sans éditer le fichier à la main ;
- installer, activer et désactiver des extensions (natives et PECL).

Cibles : Windows 10/11, sans droits administrateur (tout vit dans le profil utilisateur).

## 2. Hors périmètre (v1)

- Serveur web (Apache, nginx, IIS) : pas de gestion de vhosts ni de services.
- Compilation depuis les sources.
- Linux / macOS.
- Gestion de Composer (peut venir en v2 : `phpvm composer install`).

## 3. Sources de téléchargement

| Besoin | Source |
|---|---|
| Liste des versions courantes | `https://windows.php.net/downloads/releases/releases.json` (contient noms de zip et SHA-256) |
| Versions anciennes | `https://windows.php.net/downloads/releases/archives/` |
| Extensions PECL | `https://downloads.php.net/~windows/pecl/releases/<ext>/<version>/` |

Nom d'un zip PHP : `php-<version>-<nts|Win32>-<vs16|vs17|…>-<x64|x86>.zip`
Nom d'un zip PECL : `php_<ext>-<extver>-<phpmajor.minor>-<nts|ts>-<vc>-<arch>.zip`

Le **triplet de compatibilité** `(major.minor PHP, nts/ts, compilateur vc, arch)` doit correspondre exactement entre PHP et chaque extension PECL. L'outil le déduit de la version PHP installée.

## 4. Arborescence

```
%USERPROFILE%\.php\
├── bin\                  # phpvm.exe (dans le PATH utilisateur)
├── versions\
│   ├── 8.3.12-nts-x64\   # un dossier par version installée (zip décompressé)
│   └── 8.2.24-nts-x64\
├── current\              # jonction (junction) vers la version active
├── cache\                # zips téléchargés + releases.json mis en cache
├── config.json           # état : version active, défauts (arch, nts/ts)
└── DESIGN.md
```

Le PATH utilisateur contient `%USERPROFILE%\.php\bin` et `%USERPROFILE%\.php\current`.

## 5. Mécanisme d'activation / désactivation

Principe : **jonction NTFS** `current` → `versions\<version>`.

- Une jonction ne nécessite pas de droits administrateur (contrairement à un lien symbolique).
- `use <version>` : supprime la jonction existante, recrée vers la version cible, met à jour `config.json`.
- `off` (désactiver) : supprime la jonction ; `php` n'est alors plus résolu dans le PATH. `config.json` mémorise la dernière version pour `on`.
- `on` : recrée la jonction vers la dernière version active.
- Le PATH utilisateur est modifié une seule fois (à `phpvm init`) via le registre `HKCU\Environment`, puis un message `WM_SETTINGCHANGE` est diffusé. Le basculement de version ne touche plus au PATH, donc effet immédiat dans les **nouveaux** terminaux.
- Terminaux déjà ouverts : la jonction étant résolue à l'exécution, le changement est visible aussitôt sans relancer le terminal (le PATH ne change pas).

Évolution v2 : fichier `.php-version` par projet (résolution via shims `php.cmd` dans `bin\`).

## 6. Commandes

### Versions

| Commande | Rôle |
|---|---|
| `phpvm init` | Crée l'arborescence, ajoute au PATH utilisateur |
| `phpvm list` | Liste les versions installées (marque l'active) |
| `phpvm list --remote [--all]` | Liste les versions disponibles en ligne |
| `phpvm install <version> [--ts] [--x86]` | Télécharge, vérifie le SHA-256, décompresse, crée `php.ini` |
| `phpvm uninstall <version>` | Supprime la version (refus si active, sauf `--force`) |
| `phpvm use <version>` | Active la version |
| `phpvm off` | Désactive PHP (supprime la jonction) |
| `phpvm on` | Réactive la dernière version utilisée |
| `phpvm current` | Affiche la version active |

`<version>` accepte un préfixe : `8.3` résout vers le dernier patch 8.3.x disponible/installé.

### Configuration (`php.ini`)

| Commande | Rôle |
|---|---|
| `phpvm config get <clé>` | Lit une directive |
| `phpvm config set <clé> <valeur>` | Écrit une directive (décommente si besoin, préserve les commentaires) |
| `phpvm config unset <clé>` | Commente la directive |
| `phpvm config edit` | Ouvre `php.ini` dans l'éditeur par défaut |
| `phpvm config reset` | Régénère depuis `php.ini-development` ou `--production` |

À l'installation : copie de `php.ini-development` en `php.ini`, puis `extension_dir = "ext"` (chemin absolu calculé) activé, car PHP Windows ne le fait pas par défaut.

### Extensions

| Commande | Rôle |
|---|---|
| `phpvm ext list` | Extensions disponibles (dossier `ext\`) et leur état (activée / désactivée) |
| `phpvm ext enable <nom>` | Décommente/ajoute `extension=<nom>` dans `php.ini` |
| `phpvm ext disable <nom>` | Commente la ligne (la DLL reste) |
| `phpvm ext install <nom>[@version]` | Télécharge depuis PECL, copie la DLL dans `ext\`, active |
| `phpvm ext remove <nom>` | Désactive et supprime la DLL |
| `phpvm ext search <nom>` | Cherche les builds PECL compatibles |

Règles :

- `opcache` et `xdebug` utilisent `zend_extension=` et non `extension=`. Liste codée en dur des extensions « zend » connues, avec détection de secours (inspection du DLL ou lecture de la doc PECL).
- Les extensions sont rattachées à la **version PHP ciblée** (chaque version a son `php.ini` et son `ext\`). Option `--version <v>` pour agir sur une version non active.
- Après modification, vérification : `php -r "..."` ou `php -m` pour confirmer le chargement, avec restauration du `php.ini` si PHP ne démarre plus (sauvegarde `php.ini.bak` avant chaque écriture).
- Dépendances DLL (ex. `libssl`, `libsasl`) : déjà dans le dossier PHP pour les extensions natives ; pour PECL, le zip peut contenir des DLL à copier à côté de `php.exe`.

## 7. Choix techniques

**Langage recommandé : Go.**

- Un seul `.exe` autonome, sans runtime à installer (important pour un outil qui installe… le runtime PHP).
- Bibliothèque standard suffisante : HTTP, zip, SHA-256, JSON.
- Accès registre via `golang.org/x/sys/windows/registry`.
- Cross-compilation facile, tests simples.

Alternatives : PowerShell (rapide à prototyper, mais politique d'exécution et lenteur), Rust (plus lourd pour ce besoin).

Bibliothèques : `cobra` pour la CLI, parsing `php.ini` maison (ligne par ligne, préservant l'ordre et les commentaires).

## 8. Sécurité et robustesse

- HTTPS uniquement ; vérification SHA-256 contre `releases.json` avant décompression.
- Décompression : refuser les chemins `..` (zip-slip).
- Installation atomique : décompression dans un dossier temporaire, puis renommage vers `versions\<v>`.
- Verrou fichier pour empêcher deux `phpvm` simultanés d'écrire `config.json`.
- Sauvegarde `php.ini.bak` avant chaque écriture.
- Prérequis Visual C++ Redistributable : détecter via le registre et avertir avec le lien de téléchargement adapté (vs16 → VC++ 2019, vs17 → VC++ 2022) ; ne pas l'installer automatiquement.
- Aucune élévation de privilèges requise.

## 9. Cas limites à gérer

- `php.exe` en cours d'exécution lors de `use`/`uninstall` : la jonction se recrée sans problème, mais la suppression de dossier peut échouer → message clair.
- Version PHP déjà présente via un autre PATH (XAMPP, Scoop, Chocolatey) : `phpvm doctor` détecte et signale les conflits d'ordre dans le PATH.
- Pas de connexion : `list` fonctionne hors ligne (cache), `install` échoue avec message explicite.
- Extension PECL indisponible pour le triplet : message listant les builds proches disponibles.
- Versions sans build Windows (PHP 8.x nouvelles RC, etc.) : indiqué dans `list --remote`.

## 10. Plan de réalisation

| Jalon | Contenu |
|---|---|
| M1 | `init`, `list --remote`, `install`, `uninstall`, `list`, `current` |
| M2 | `use`, `off`, `on` (jonction + PATH) |
| M3 | `config get/set/unset/edit/reset` + parseur `php.ini` |
| M4 | `ext list/enable/disable` (extensions natives) |
| M5 | `ext install/remove/search` (PECL) |
| M6 | `doctor`, prérequis VC++, messages d'erreur, tests e2e sur VM Windows |
| M7 | Distribution : release GitHub, script d'installation PowerShell (`irm … \| iex`), éventuellement Scoop/winget |

## 11. Tests

- Unitaires : parseur `php.ini` (commentaires, sections, doublons, fins de ligne CRLF), résolution de préfixe de version, construction des URLs PECL.
- Intégration : serveur HTTP local simulant `releases.json` et les zips.
- E2E : installer deux versions, basculer, activer/désactiver une extension, vérifier `php -v` et `php -m`.

## 12. Questions ouvertes

1. Langage final : Go (recommandé) ou PowerShell ?
2. Nom définitif de l'outil / de la commande.
3. Support du TS (thread-safe, pour Apache `mod_php`) dès la v1 ou seulement NTS ?
4. Faut-il gérer un `.php-version` par projet dès la v1 ?
5. Installer Composer automatiquement avec chaque version ?
