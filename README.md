# phpvm

Gestionnaire de versions et d'extensions PHP pour Windows, écrit en PowerShell. Il permet d'installer plusieurs versions de PHP côte à côte, d'en activer une (ou aucune), de modifier `php.ini` et d'activer ou désactiver des extensions, y compris celles de PECL.

- Aucune installation préalable : PowerShell 5.1 est déjà présent sur Windows 10/11.
- Aucun droit administrateur : tout vit dans `%USERPROFILE%\.php`.
- Les téléchargements viennent de [windows.php.net](https://windows.php.net/downloads/releases/) et sont vérifiés par SHA-256.

## Installation

1. Placer le dossier du projet dans `%USERPROFILE%\.php` (il contient `bin\phpvm.ps1` et `bin\phpvm.cmd`).
2. Lancer une fois :

   ```powershell
   & "$env:USERPROFILE\.php\bin\phpvm.cmd" init
   ```

   `init` crée les dossiers et ajoute `~\.php\bin` et `~\.php\current` au PATH utilisateur. Ouvrir ensuite un **nouveau** terminal.
   `init --no-path` crée les dossiers sans toucher au PATH.
3. Vérifier l'environnement :

   ```powershell
   phpvm doctor
   ```

Pour utiliser un autre emplacement, définir la variable d'environnement `PHPVM_HOME`.

## Démarrage rapide

```powershell
phpvm install 8.3      # dernière 8.3.x (NTS, x64)
phpvm use 8.3
php -v
```

## Commandes

### Versions

| Commande | Rôle |
|---|---|
| `phpvm list` | Versions installées (`*` = active) |
| `phpvm list --remote [--all]` | Versions disponibles en ligne (`--all` ajoute les archives) |
| `phpvm install <ver> [--ts] [--x86] [--production]` | Télécharge, vérifie, décompresse et crée `php.ini` |
| `phpvm uninstall <ver> [--force]` | Supprime une version (refus si active, sauf `--force`) |
| `phpvm use <ver>` | Active une version ; sans argument, lit `.php-version` du dossier courant |
| `phpvm off` / `phpvm on` | Désactive PHP / réactive la dernière version utilisée |
| `phpvm current` | Affiche la version active |

`<ver>` accepte un préfixe : `8.3` désigne la dernière 8.3.x installée ou disponible. Par défaut, le build est NTS x64 ; `--ts` choisit le build thread-safe, `--x86` le 32 bits.

### Configuration de `php.ini`

S'applique à la version active, ou à celle donnée par `--version <v>`.

| Commande | Rôle |
|---|---|
| `phpvm config get <clé>` | Lit une directive |
| `phpvm config set <clé> <valeur>` | Écrit une directive (décommente la ligne si besoin) |
| `phpvm config unset <clé>` | Commente la directive |
| `phpvm config edit` | Ouvre `php.ini` dans le Bloc-notes |
| `phpvm config reset [--production]` | Régénère depuis `php.ini-development` (ou production) |
| `phpvm config path` | Affiche le chemin de `php.ini` |

Chaque modification est suivie d'un test de démarrage de PHP. Si PHP ne démarre plus, l'ancien `php.ini` est restauré (sauvegarde dans `php.ini.bak`).

### Extensions

| Commande | Rôle |
|---|---|
| `phpvm ext list` | Extensions présentes dans `ext\` et leur état |
| `phpvm ext enable <nom>...` | Active une extension |
| `phpvm ext disable <nom>...` | Désactive une extension (la DLL reste) |
| `phpvm ext install <nom>[@version] [--pre]` | Télécharge un build PECL compatible, copie la DLL et active |
| `phpvm ext remove <nom>` | Désactive et supprime la DLL |
| `phpvm ext search <nom> [--pre]` | Liste les builds PECL compatibles avec la version ciblée |

`opcache` et `xdebug` sont gérées comme `zend_extension`. À l'installation d'une version, ces extensions courantes sont activées : curl, fileinfo, mbstring, openssl, pdo_mysql, pdo_sqlite, mysqli, sqlite3, zip, intl, gd, exif.

### Diagnostic

`phpvm doctor` contrôle le PATH, la présence d'un autre `php.exe` qui masquerait phpvm, le runtime Visual C++ et le bon démarrage de la version active.

## Exemples

```powershell
phpvm install 8.2.24 --ts          # version archivée, build thread-safe
phpvm use 8.2
phpvm config set memory_limit 512M
phpvm ext install xdebug           # build PECL adapté à la version active
phpvm ext disable xdebug
phpvm off                          # plus de PHP dans le PATH
phpvm on                           # retour à la dernière version
```

## Fonctionnement

```
%USERPROFILE%\.php\
├── bin\            phpvm.ps1, phpvm.cmd (dans le PATH)
├── versions\       une version par dossier, ex. 8.3.36-nts-x64
├── current\        jonction NTFS vers la version active (dans le PATH)
├── cache\          zips téléchargés, releases.json
└── config.json     dernière version active
```

- **Activation** : `use` recrée la jonction `current` vers le dossier de la version choisie. Le PATH n'est modifié qu'une fois, par `init` ; le changement de version est donc immédiat, même dans un terminal déjà ouvert. `off` supprime la jonction.
- **`php.ini`** : un par version, dans le dossier de la version, avec `extension_dir` calculé automatiquement.
- **Extensions PECL** : le build doit correspondre à la version PHP (`major.minor`), au mode NTS/TS, au compilateur (vs16, vs17…) et à l'architecture. phpvm déduit ce triplet de la version installée.
- **Sécurité** : HTTPS, vérification SHA-256 (sauf versions archivées, pour lesquelles aucune somme n'est publiée), protection contre les chemins malveillants dans les zips (zip-slip), installation atomique via un dossier temporaire.

## Limites

- Windows uniquement ; pas de gestion de serveur web (Apache, nginx, IIS).
- Messages de l'outil en anglais.
- Le Visual C++ Redistributable n'est pas installé automatiquement ; `phpvm doctor` indique le lien à utiliser.
- Les builds `--x86` et `--ts` sont gérés mais moins testés que NTS x64.

## Documentation

La conception détaillée est dans [DESIGN.md](DESIGN.md).
