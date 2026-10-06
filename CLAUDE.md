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

### Deployment auf die VPS
Die Stacks liegen unter `deployment/docker-services/`. Wie sie auf die VPS kommen und wie die Produktion umgestellt wird (Cutover), ist noch nicht festgelegt (siehe Spec `modular-docker-compose`).
1. Für jeden Stack `.env.example` nach `.env` kopieren (`chmod 600`) und die Werte eintragen. Die DB-Zugangsdaten (`ODOO_DB_*`) in `odoo-*/.env` und `odoo-*/backup/.env` müssen gleich sein.
2. `./setup.sh` ausführen. Das Skript ist idempotent: Es legt die Netzwerke `db-net` und `ingress-net` an, ebenso fehlende Volumes (mit Warnung, auf der VPS existieren sie bereits) und `ingress/conf.d/ssl-dhparams.pem`, falls die Datei fehlt. Außerdem prüft es alle `.env`-Dateien.
3. `./start-all-services.sh` startet die Stacks in dieser Reihenfolge: `database` (wartet auf `healthy`) → `odoo-*` → `odoo-*/backup` → `ingress`. Mit `--dry-run` werden die Befehle nur angezeigt.
4. **Odoo-Update:**
   - In `odoo-griffity-prod/backup` zuerst ein manuelles Backup auslösen (`docker compose exec backup-service /app/entrypoint.sh`), danach das Backup mit `docker compose stop` anhalten. Der Filestore wird ohne Versionen gespiegelt, siehe `.features/.specs/backup-filestore-versioning.md`.
   - In `odoo-griffity-prod/.env` `ODOO_IMAGE_TAG` setzen, dann `docker compose pull && docker compose up -d` ausführen. Bei Bedarf `-u <module>` gegen `tomagency.griffity.de` laufen lassen.
   - Läuft alles, das Backup mit `docker compose start` wieder starten. `start-all-services.sh` startet ein angehaltenes Backup ebenfalls wieder, deshalb das Skript nicht mitten in einem Update aufrufen.

Die Volumes `postgres_data`, `odoo_data` und `certbot_www` sind `external: true` und behalten die Namen aus dem Monolithen.

### Tests (`deployment/docker-services/tests/`)
```bash
shellcheck -x --source-path=SCRIPTDIR deployment/docker-services/*.sh deployment/docker-services/tests/*.sh
deployment/docker-services/tests/run-baseline.sh          # Parität + nginx -t des Monolithen (archive/)
deployment/docker-services/tests/test-compose-parity.sh --modular deployment/docker-services
deployment/docker-services/tests/test-compose-policy.sh   # Ports, Netze, Restart, Secrets, Image-Defaults
deployment/docker-services/tests/test-nginx-config.sh deployment/docker-services/ingress/conf.d
deployment/docker-services/tests/test-repo-hygiene.sh     # gitignore + Build-Kontext
deployment/docker-services/tests/test-setup.sh
deployment/docker-services/tests/test-start-order.sh
deployment/docker-services/tests/smoke-test.sh            # Ende-zu-Ende, lokal, nativ arm64, braucht Ports 80/443/15432
```
Der Smoke-Test verwendet Ersatz-Images, weil das TOM-Image nur für amd64 existiert: `odoo:17.0`, `bitnamilegacy/postgresql:15.10.0-debian-12-r2` und ein lokal gebautes `../tom-backup-image`. Er prüft die Infrastruktur, nicht die TOM-Module. Die Variablen `POSTGRES_IMAGE`, `ODOO_IMAGE`, `BACKUP_IMAGE` und `POSTGRES_HOST_PORT` sind nur für Tests gedacht und stehen nie in einer `.env` auf der VPS.

## Wichtige Abhängigkeiten in der Konfiguration

- **Websocket / Worker-Modus**: Auf der VPS ist `workers` **nicht** gesetzt (Threaded-Server, Stand 2026-10-06). `archive/odoo.conf` mit `workers = 6` entspricht also nicht der Produktion. Live-Updates (Chatter, Benachrichtigungen, Anwesenheit) laufen über `/websocket` auf Port 8069. Dafür braucht nginx `proxy_http_version 1.1` und die Header `Upgrade`/`Connection` (`location /websocket` in `ingress/conf.d`). Ohne diese Header antwortet Odoo mit 400. Wer `workers > 0` setzt, muss `/websocket` auf den gevent-Port 8072 umleiten (Vorlage `archive/nginx-conf-new/`). Der Smoke-Test prüft den Handshake (101).
- **Timeouts**: `limit_time_real` (1200 s) in `odoo.conf` darf nicht größer sein als `proxy_read_timeout` in nginx (1200 s).
- **DB-Verbindungen**: `db_maxconn = 10` mal 9 Prozesse (6 Worker + 2 Cron + 1 gevent) ergibt 90, das muss unter `max_connections` von PostgreSQL (100) bleiben. Wer `workers` erhöht, muss diese Rechnung neu machen.
- `dbfilter = ^%h$` und `db_name` setzen voraus, dass der Datenbankname dem Hostnamen entspricht. `list_db = False`, außerdem blockiert nginx `/web/database`.
- **Python/pip im Image**: Zuerst pip aktualisieren (TOM-195, sonst wird `email_bridge_client` als "UNKNOWN" gebaut), `python3-cairo` kommt aus apt (pycairo hat keine Linux-Wheels). `pyOpenSSL~=22.0.0` und `cryptography~=38.0.0` werden danach absichtlich wieder heruntergepinnt.
- `openupgradelib` wird für die Migrationsskripte der OCA-Module bei `-u` gebraucht.
- `web_dialog_size` bleibt nur so lange im Image, bis das Modul in der Produktion deinstalliert ist (ersetzt durch `mikrowerk_widgets`, TOM-71).

## Architektur: modulare Compose-Struktur

Spec: `.features/.specs/modular-docker-compose.md`, Plan: `.features/.plans/modular-docker-compose.md`.

```
deployment/docker-services/
├── setup.sh                  # Netzwerke, Volumes, dhparams, .env-Prüfung (idempotent)
├── start-all-services.sh     # database → odoo-* → odoo-*/backup → ingress
├── database/                 # Projekt "database": Postgres (ghcr.io/mikrowerk/postgresql:15 = Bitnami 15.10)
├── odoo-griffity-prod/       # Projekt "odoo-griffity-prod": Odoo, Alias odoo-griffity-prod in ingress-net
│   └── backup/               # Projekt "odoo-griffity-prod-backup": backup-service, separat pausierbar
├── ingress/                  # Projekt "ingress": nginx (1.30) + certbot
│   └── conf.d/               # nginx-Konfiguration (Zertifikate in CERTBOT_DIR, dhparams von setup.sh)
└── tests/
```

- **Je Odoo-Instanz ein Verzeichnis `odoo-<name>/`** mit eigener `compose.yaml` und `.env`, eigener Datenbank, eigenem DB-User und eigenem Backup unter `backup/`. Jeder Stack lässt sich einzeln starten, stoppen und aktualisieren, ohne die anderen zu berühren. Weitere Instanzen und eine Vorlage dafür sind noch nicht umgesetzt.
- **Backup als eigenes Projekt:** Ein `docker compose up`/`down` im Odoo-Stack lässt das Backup unberührt. Nur so lässt es sich während eines Updates pausieren.
- **Netzwerke (extern):** `db-net` verbindet Postgres (Alias `postgresql`) mit Odoo und Backup. `ingress-net` verbindet nginx mit Odoo (Alias `odoo-<name>`). nginx kann Postgres nicht erreichen. certbot hängt in keinem der beiden Netzwerke.
- **Robuster nginx-Start:** Der Upstream wird mit `resolver 127.0.0.11` und `server odoo-griffity-prod:8069 resolve;` zur Laufzeit aufgelöst. Deshalb startet nginx auch, wenn ein Odoo-Stack nicht läuft (bis dahin 502). Voraussetzung ist nginx ≥ 1.27.3.
- **Keine festen `container_name`**, sondern feste Projektnamen (`name:`). Odoo veröffentlicht keine Ports, nach außen veröffentlicht nur nginx 80 und 443.
- **Postgres nur per SSH-Tunnel von außen:** Der Port ist nur an Loopback gebunden (`127.0.0.1:5432:5432`), **nie** `5432:5432` (das wäre `0.0.0.0`, und Docker umgeht dabei ufw/iptables-Regeln). Zugriff von außen (pgAdmin, DBeaver, psql) nur über `ssh -L 5432:127.0.0.1:5432 <user>@<vps>`. Die Container verbinden sich über `db-net`. Eine externe Firewall schützt den Port derzeit zwar, darauf darf sich die Konfiguration aber **nicht** verlassen. Die Compose-Dateien müssen auch ohne Firewall sicher sein, und das gilt genauso für alle anderen internen Dienste. Der Policy-Test prüft das.
- **Healthcheck Postgres:** `pg_isready` braucht `-U`. Ohne diese Option findet es im Bitnami-Container (UID 1001) keinen Benutzer, und der Check scheitert mit `no attempt`.
- **Ressourcen addieren sich:** Die `db_maxconn`-Rechnung (siehe oben) gilt für alle Odoo-Instanzen zusammen gegen ein einziges Postgres. Dasselbe gilt für Worker und RAM.
- Compose-Dateien heißen `compose.yaml`, verwendet wird `docker compose` (v2).

## Secrets

- **Keine Secrets in versionierten Dateien.** Passwörter, AWS-Keys, `ODOO_CONFIG_ENCRYPTION_KEY`, `admin_passwd` usw. gehören in **`.env`-Dateien** oder **Passwort-Dateien** (Docker secrets / `*_FILE`-Variablen, z. B. `POSTGRESQL_PASSWORD_FILE`), nicht in `compose.yaml` oder `odoo.conf`.
- `.env` und Passwort-Dateien kommen in `.gitignore`. Ins Repo gehört stattdessen eine `.env.example` mit allen Variablen und leeren oder Dummy-Werten.
- Passwort-Dateien bekommen restriktive Rechte (`chmod 600`, Besitzer root bzw. UID 101).
- In `compose.yaml` werden Werte nur per `${VAR}` bzw. `secrets:` referenziert. Werte, die Odoo aus `odoo.conf` braucht (z. B. `admin_passwd`), werden per Umgebungsvariable/Kommandozeile übergeben oder beim Start aus der Passwort-Datei erzeugt.
- Pflichtvariablen werden als `${VAR:?set in .env}` referenziert. `setup.sh` weist `.env`-Dateien ab, in denen Variablen fehlen, leer sind oder noch `changeme` steht.
- `odoo.conf` (mit `admin_passwd` usw.) und die Zertifikate liegen nur auf der VPS (`ODOO_CONF_DIR`, `CERTBOT_DIR`). `ingress/conf.d/ssl-dhparams.pem` ist gitignored.
- Die Dateien unter `archive/` enthalten nur Platzhalter (`***`). Diese bleiben unverändert, echte Werte werden dort nie eingetragen.

## Projektdokumente: `.features/`

Spezifikationen, Pläne und Dokumentation werden im Repo versioniert:

| Verzeichnis | Inhalt |
|---|---|
| `.features/.specs/` | Spezifikationen (Was und Warum) mit Abschnitt „Entscheidungen“ (datiert), z. B. `.features/.specs/modular-docker-compose.md` |
| `.features/.plans/` | Umsetzungspläne zu einer Spec (Baseline, Schritte als Checkboxen, betroffene Dateien, Abweichungen) |
| `.features/.docs/` | Betriebs- und Architekturdokumentation, z. B. Setup der VPS, Runbooks, neuen Kunden anlegen |

Ein Plan und seine Spec tragen denselben Dateinamen. Ein Plan wird erst erstellt, wenn die Spec vorliegt, und die Umsetzung erfolgt erst nach einem Plan. Umgesetzt wird auf einem Feature-Branch (`feature/<name>`), der von `releases/17-candidate` abzweigt, mit einem Commit pro Planschritt.
