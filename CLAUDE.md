# CLAUDE.md

Dieses Repository baut das Docker-Image für **TOM 2.0** (Odoo 17, auf Basis des offiziellen Odoo-Images) und enthält die Laufzeitkonfiguration (Docker Compose, Odoo, nginx) für den Betrieb auf einer Linux-VPS (Host `tomagency.griffity.de`).

Hier wird **kein Odoo-Modulcode entwickelt**. Die Add-ons liegen in Git-Submodulen und werden in deren eigenen Repositories gepflegt. In diesem Repo werden nur die Submodul-Zeiger, das Dockerfile, die Python-Abhängigkeiten und die Deployment-Konfiguration geändert.

## Aufbau

| Pfad | Zweck |
|---|---|
| `Dockerfile` | Mehrstufiger Build: Stufe `gs-build` kompiliert Ghostscript aus den Quellen (für PDF/A-3b, TOM-201), danach Basis `ghcr.io/mikrowerk/odoo-17-official-image-amd-64:<datum>` plus Add-ons und pip-Pakete |
| `additional-requirements.txt` | Zusätzliche Python-Pakete, die als root ins Image installiert werden |
| `deployment/docker-services/` | Modulare Laufzeit-Stacks für die VPS: `database/`, `ingress/`, `odoo-griffity-prod/` (mit `backup/`) sowie `setup.sh`, `start-all-services.sh` und `tests/` (siehe „Deployment“) |
| `archive/` | Abgelöster Monolith als Referenz: `docker-compose.yaml`, `odoo.conf` (auf der VPS unter `/opt/odoo/conf/odoo.conf`), `nginx-conf/` (läuft so produktiv) und `nginx-conf-new/` (Multi-Worker-Variante mit `/websocket` → 8072, Login-Rate-Limit, Scanner-Sperren, derzeit nicht produktiv). Secrets und `ssl-dhparams.pem` sind dort geschwärzt (`***`) |
| `.dockerignore` | Hält `deployment/`, `archive/`, `.features/`, `.git` und `.env`-Dateien aus dem Build-Kontext |
| `odoo_user_add.sh` | Legt auf dem Host den User/die Gruppe `odoo` mit UID/GID 101 an (passend zum Container, wichtig für Bind-Mounts) |
| `mount_s3fs.sh` | Bindet einen IONOS-S3-Bucket per s3fs als Filestore ein (uid/gid 101) |
| `.features/` | Specs, Pläne und Doku (siehe unten) |
| `.github/workflows/build_publish_image.yml` | CI: baut und pusht das Image bei Pushes auf `main`, `releases/**` und `rc/**` |

### Submodule (alle mit Branch `releases/17-candidate`, relative URLs `../<name>.git`)

- `odoo-tom-jobcontrol`: die Mikrowerk-Module (`jobcontrol`, `mikrowerk_*`); wird **komplett** nach `/mnt/extra-addons` kopiert
- `griffity_doc_templates`: nur `griffity_templates` wird kopiert
- `odoo-tom-third-party-addons`: `copy_section_with_products`, `section_wise_subtotal`
- OCA: `oca-account-financial-tools`, `oca-account-reconcile`, `oca-bank-payment`, `oca-partner-contact` werden komplett kopiert. Aus `oca_web`, `oca_knowledge`, `oca-purchase-workflow` und `oca-social` werden nur **einzelne Module** übernommen (siehe die `COPY`-Zeilen im `Dockerfile`)

Ein neues Modul aus einem OCA-Repo, aus dem nur Teile übernommen werden, braucht deshalb eine eigene `COPY`-Zeile im `Dockerfile`. Dass es im Submodul liegt, reicht nicht.

## Typische Arbeitsabläufe

### Module aktualisieren (häufigster Fall)
```bash
git submodule update --init --recursive              # nach dem Klonen
cd odoo-tom-jobcontrol && git pull origin releases/17-candidate && cd ..
git add odoo-tom-jobcontrol && git commit -m "update module: <kurzbeschreibung>"
```
Die meisten Commits hier sind reine Submodul-Bumps. Commit-Messages sind kurz und auf Englisch. Wenn es ein Ticket gibt, kommt die Ticketnummer davor (`TOM-201: ...`).

### Image bauen
- CI taggt `ghcr.io/mikrowerk/tom-2-0-odoo-17-image` mit `latest`, `rc-03-2025` und dem **kurzen Commit-Hash**.
- Lokal (amd64-Basisimage, auf Apple Silicon deshalb die Plattform angeben):
  ```bash
  docker build --platform linux/amd64 -t tom-2-0-odoo-17-image:local .
  ```
- Der Ghostscript-Build ist über `GS_VERSION`, `GS_TAG` und `GS_SHA256` versioniert. Bei einem Versionswechsel immer auch die SHA256 aktualisieren.
