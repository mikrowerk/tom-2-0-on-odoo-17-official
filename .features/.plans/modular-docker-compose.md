# Plan: Modulare Docker-Compose-Struktur

Spec: `.features/.specs/modular-docker-compose.md`, maßgeblich sind die Abschnitte unter „Entscheidungen“ vom 2026-10-06.
Erstellt: 2026-10-06

## Zielbild

```
deployment/docker-services/
├── setup.sh                     # einmalig/idempotent: Netzwerke, Volumes, .env-Prüfung
├── start-all-services.sh        # database → odoo-* → odoo-*/backup → ingress
├── tests/                       # Regressions-, Policy- und Smoke-Tests
├── database/
│   ├── compose.yaml             # name: database – Postgres (ghcr.io/mikrowerk/postgresql:15)
│   └── .env.example
├── odoo-griffity-prod/
│   ├── compose.yaml             # name: odoo-griffity-prod – Odoo
│   ├── .env.example
│   └── backup/
│       ├── compose.yaml         # name: odoo-griffity-prod-backup – backup-service
│       └── .env.example
└── ingress/
    ├── compose.yaml             # name: ingress – nginx + certbot
    ├── .env.example
    └── conf.d/                  # odoo.conf, tomagency.griffity.de.conf, options-ssl-nginx.conf, ssl-dhparams.pem
```

Netzwerke (extern, von `setup.sh` angelegt):
- `db-net`: Postgres (Alias `postgresql`), Odoo und Backup
- `ingress-net`: nginx und Odoo (Alias `odoo-griffity-prod`)

Externe Volumes, unverändert: `postgres_data`, `odoo_data`, `certbot_www`.

## Baseline

**2026-10-06** – `deployment/docker-services/tests/run-baseline.sh` auf `feature/modular-docker-compose` (Stand `4e95afa`):
- `test-compose-parity.sh --monolith docker-compose.yaml` ergibt 47/47 Prüfungen grün: externe Volumes, Postgres (Image, Volume, Env), Odoo (Image, Command, Volumes, Env), Backup (Image, ro-Volume, Env-Keys aus `backup.sh`, `DATA_DIR`, gleiche DB), nginx (Ports, Mounts), certbot (Entrypoint, Mounts).
- `test-nginx-config.sh` auf `nginx-conf/` (ohne den Rest `root@u`, mit generierten Test-DH-Parametern) mit `--add-host odoo` ergibt: `nginx: configuration file /etc/nginx/nginx.conf test is successful`.
- Exit-Code 0, `shellcheck tests/*.sh` sauber.
- Bekannter Befund, als Ausgangszustand bestätigt: `test-nginx-config.sh deployment/docker-services/ingress --add-host odoo` ist rot mit `duplicate upstream "odoo-backend" in /etc/nginx/conf.d/options-ssl-nginx.conf:2`. Das behebt Schritt 3.
- Bekannter Befund: `nginx-conf/ssl-dhparams.pem` ist geschwärzt (siehe Spec).

## Konventionen für alle Schritte

- Jeder Schritt endet mit grünen Tests und **einem** Commit. Commit-Messages sind kurz und auf Englisch, z. B. `deployment: add database stack`.
- Tests liegen unter `deployment/docker-services/tests/` und sind Bash mit `set -euo pipefail` und `shellcheck`-sauber. Sie brauchen nur `docker`, `docker compose` (v2), `jq`, `curl` und `openssl`.
- `.env.example` enthält alle Variablen mit Dummy-Werten (`changeme`). Echte `.env`-Dateien werden nie committet.
- Compose-Tests laufen mit `docker compose --env-file .env.example …`, damit sie ohne echte Secrets funktionieren.

---

## Schritte

### Phase A – Regressionstests gegen den aktuellen Stand (vor allen Änderungen)

- [x] **1. Spec, Backup-Spec und Plan committen**
  - Dateien: `.features/.specs/modular-docker-compose.md`, `.features/.specs/backup-filestore-versioning.md`, `.features/.plans/modular-docker-compose.md`
  - Nachweis: `git status` ist sauber, abgesehen von `CLAUDE.md` (kommt in Schritt 13) und den Rohdateien unter `deployment/docker-services/ingress/` (kommen in Schritt 3).
  - Commit: `docs: add spec and plan for modular docker compose`
  - **Abweichung:** Auf Wunsch (Rückfrage 2026-10-06) committet dieser Schritt auch die bis dahin untracked `CLAUDE.md` und die unveränderten nginx-Rohdateien unter `deployment/docker-services/ingress/`. Dadurch zeigen die Schritte 3 und 13 saubere Diffs. Gearbeitet wird auf dem Branch `feature/modular-docker-compose`, abgezweigt von `releases/17-candidate`.

- [x] **2. Paritätstest und nginx-Konfigurationstest, grün gegen den Monolithen**
  - Neu: `deployment/docker-services/tests/lib.sh` mit Hilfsfunktionen (`fail`, `assert_eq`, `compose_json`).
  - Neu: `deployment/docker-services/tests/test-compose-parity.sh` mit den Modi `--monolith <file>` und `--modular <dir>`. Das Skript erzeugt aus `docker compose config --format json` eine normalisierte Sicht je Dienst und prüft die **fachlichen Invarianten**, die nach der Aufteilung erhalten bleiben müssen:
    - Odoo: Image-Repository `ghcr.io/mikrowerk/tom-2-0-odoo-17-image`, `command` = `odoo --log-level=info -d <db>`, Volumes `odoo_data → /var/lib/odoo` und `<conf> → /etc/odoo`, Env-Keys `HOST`, `PORT`, `USER`, `PASSWORD`, `ODOO_CONFIG_ENCRYPTION_KEY`, `HOST=postgresql`
    - Postgres: Volume `postgres_data → /bitnami/postgresql`, Env-Keys `POSTGRESQL_*`
    - nginx: Ports 80/443, Volumes `→ /etc/nginx/conf.d`, `→ /etc/letsencrypt`, `certbot_www → /var/www/certbot`
    - certbot: identischer `entrypoint` (Renew-Schleife), Volumes `→ /etc/letsencrypt` und `certbot_www → /var/www/certbot`
    - Backup: Image `ghcr.io/mikrowerk/tom-backup-image:feature-build-image-for-odoo-17`, `odoo_data → /var/lib/odoo` read-only, Env-Keys aus `backup.sh` (`POSTGRESQL_POSTGRES_PASSWORD`, `POSTGRES_HOST`, `POSTGRESQL_USERNAME`, `POSTGRESQL_DATABASE`, `S3_BUCKET`, `DATA_DIR`, `BACKUP_RETENTION`, `ENCRYPTION_PASSWORD`, `AWS_*`), `DATA_DIR = /var/lib/odoo/data/filestore/<db>`
    - Volumes `postgres_data`, `odoo_data` und `certbot_www` sind `external`.
  - Neu: `deployment/docker-services/tests/test-nginx-config.sh <conf-dir> [--add-host odoo]`. Das Skript erzeugt in einem Temp-Verzeichnis ein selbstsigniertes Zertifikat unter `live/tomagency.griffity.de/` und führt `nginx -t` im nginx-Container aus (Image wie im ingress-Stack).
  - **Nachweis grün gegen den aktuellen Stand:**
    - `tests/test-compose-parity.sh --monolith docker-compose.yaml` ist grün.
    - `tests/test-nginx-config.sh` gegen eine Temp-Kopie von `nginx-conf/`, in der nur der Prompt-Rest `root@u` am Ende von `options-ssl-nginx.conf` entfernt ist, ist mit `--add-host odoo` grün. Das entspricht dem produktiven Stand auf der VPS. Die Bereinigung im Test wird kommentiert, die Datei in `nginx-conf/` selbst bleibt unverändert.
    - `tests/test-nginx-config.sh deployment/docker-services/ingress --add-host odoo` ist **rot**, weil `options-ssl-nginx.conf` beschädigt ist (siehe Spec). Das ist der erwartete Ausgangsbefund und wird im Testprotokoll des Commits vermerkt.
  - `shellcheck deployment/docker-services/tests/*.sh` läuft sauber.
  - Commit: `deployment: add regression tests for compose parity and nginx config`
  - **Abweichung:** Neu ist `tests/run-baseline.sh`, das die Baseline reproduzierbar zusammenfasst: Parität des Monolithen plus `nginx -t` auf `nginx-conf/` ohne den Rest `root@u`. Ab Schritt 12 nimmt das Skript automatisch `archive/`.
  - **Abweichung:** `test-nginx-config.sh` testet auf einer Kopie des Konfigurationsverzeichnisses und setzt dort Test-DH-Parameter ein, wenn `ssl-dhparams.pem` fehlt oder ungültig ist. Grund: Die versionierte Datei ist geschwärzt (siehe Spec, Entscheidung „Schritt 2: `ssl-dhparams.pem`“).
  - **Abweichung:** `docker compose config` gibt `$$` im certbot-`entrypoint` unverändert escaped aus. Der Erwartungswert im Paritätstest berücksichtigt das.

### Phase B – Bestehende Konfiguration ins Zielbild überführen

- [x] **3. nginx-Konfiguration nach `ingress/conf.d/` übernehmen und reparieren (ohne inhaltliche Änderung)**
  - `deployment/docker-services/ingress/{odoo.conf,tomagency.griffity.de.conf,options-ssl-nginx.conf}` nach `ingress/conf.d/` verschieben (`git mv`).
  - `conf.d/options-ssl-nginx.conf` bereinigen: Die kopierte `odoo.conf` und die Shell-Prompt-Zeile am Anfang entfernen, sodass nur der certbot-Inhalt übrig bleibt, mit abschließendem Newline. Abgleich mit `nginx-conf/options-ssl-nginx.conf`, Unterschied darf nur der dortige Rest `root@u` am Ende sein.
  - ~~`nginx-conf/ssl-dhparams.pem` nach `ingress/conf.d/ssl-dhparams.pem` kopieren.~~ Entfällt, die Datei ist geschwärzt. `ingress/conf.d/ssl-dhparams.pem` wird gitignored und von `setup.sh` erzeugt (Schritt 9).
  - Test: `test-nginx-config.sh deployment/docker-services/ingress/conf.d --add-host odoo` ist jetzt grün. `diff -r nginx-conf deployment/docker-services/ingress/conf.d` zeigt nur den Rest `root@u` bzw. das Newline in `options-ssl-nginx.conf`.
  - Commit: `deployment: move nginx config to ingress/conf.d and repair options-ssl-nginx.conf`
  - Ergebnis 2026-10-06: `nginx -t` ist grün. `diff -r` zeigt nur den Rest `root@u` in `nginx-conf/options-ssl-nginx.conf` und die fehlende `ssl-dhparams.pem`. Beides ist gewollt, siehe Abweichung oben.

- [x] **4. Repo-Hygiene: `.dockerignore` und `.gitignore`**
  - Neu: `.dockerignore` mit `deployment/`, `.features/`, `archive/`, `**/.env`, `.idea/` und `.git`.
  - `.gitignore`: `.env` greift bereits in jeder Tiefe (Zeile 139). Ergänzen: `!.env.example` zur Sicherheit, `deployment/docker-services/tests/.tmp/` für Testartefakte und `deployment/docker-services/ingress/conf.d/ssl-dhparams.pem`.
  - Neu: `deployment/docker-services/tests/test-repo-hygiene.sh`
    - `git check-ignore` meldet `deployment/docker-services/{database,ingress,odoo-griffity-prod,odoo-griffity-prod/backup}/.env` als ignoriert und `.env.example` als **nicht** ignoriert.
    - Build-Kontext-Probe: `docker build -f - .` mit einem Mini-Dockerfile (`FROM busybox`, `COPY . /ctx`, `RUN` listet `/ctx`). Prüft, dass alle `COPY`-Quellen aus dem echten `Dockerfile` im Kontext vorhanden sind und `deployment/`, `.features/` und `archive/` fehlen.
  - Nachweis: Der Test ist grün, und die Build-Kontext-Probe vorher und nachher zeigt, dass keine `COPY`-Quelle verloren gegangen ist.
  - Commit: `build: add .dockerignore, keep deployment and docs out of build context`
  - Ergebnis 2026-10-06: Vorher waren alle 18 `COPY`-Quellen im Kontext, außerdem `deployment/` und `.features/`, und die Ignore-Regeln für dhparams und `tests/.tmp` fehlten (4 Fehler). Nachher sind alle Prüfungen grün, die 18 `COPY`-Quellen weiterhin vorhanden.
  - **Abweichung:** `shellcheck` läuft ab jetzt mit `-x`, damit das eingebundene `lib.sh` mitgeprüft wird. Das gilt auch für die Befehle in Schritt 14.

### Phase C – Stacks

Für jeden Stack-Schritt gilt: `docker compose --env-file .env.example -f <stack>/compose.yaml config -q` ist grün, `test-compose-parity.sh --modular deployment/docker-services` prüft die bis dahin vorhandenen Stacks (fehlende Stacks werden übersprungen, nicht als Fehler gewertet), `test-compose-policy.sh` ist grün.

- [x] **5. Policy-Test und `database`-Stack**
  - Neu: `deployment/docker-services/tests/test-compose-policy.sh` prüft alle `*/compose.yaml` und `*/*/compose.yaml`:
    - Jede Datei hat `name:`, kein Dienst hat `container_name`.
    - Nur `ingress/nginx` veröffentlicht Ports, und zwar genau 80 und 443.
    - Postgres veröffentlicht nur `127.0.0.1:5432` (`host_ip == "127.0.0.1"`). Jeder andere veröffentlichte Port mit leerer `host_ip` oder `0.0.0.0` ist ein Fehler.
    - Odoo, Backup und certbot haben keine `ports`.
    - `restart: unless-stopped` bei postgresql, odoo, nginx, certbot und backup-service.
    - Netzwerke: `postgresql` nur in `db-net`. `nginx` nicht in `db-net`. `odoo` in `db-net` und `ingress-net` mit Alias `odoo-griffity-prod`. `backup-service` nur in `db-net`. `db-net` und `ingress-net` sind `external`.
    - Keine Secret-Literale: Werte von `*PASSWORD*`, `*SECRET*`, `*KEY*` müssen im Roh-YAML als `${…}` stehen.
    - Image-Defaults: Ohne gesetzte `POSTGRES_IMAGE`, `ODOO_IMAGE` und `BACKUP_IMAGE` ergeben sich die Produktiv-Images. Geprüft wird mit `docker compose config` bei ungesetzten Variablen. Keine dieser Variablen steht in einer `.env.example`.
  - Neu: `deployment/docker-services/database/compose.yaml`
    - `name: database`, Dienst `postgresql`, Image `${POSTGRES_IMAGE:-ghcr.io/mikrowerk/postgresql:15}`, `restart: unless-stopped`, `ports: ["127.0.0.1:5432:5432"]`, Volume `postgres_data:/bitnami/postgresql` (external).
    - Netzwerk `db-net` (external) mit Alias `postgresql`.
    - Env `POSTGRESQL_POSTGRES_PASSWORD`, `POSTGRESQL_USERNAME`, `POSTGRESQL_PASSWORD` und `POSTGRESQL_DATABASE` per `${…}`.
    - Healthcheck mit `pg_isready`.
  - Neu: `deployment/docker-services/database/.env.example`
  - Neue Tests in diesem Schritt: Policy-Test (grün für `database`). Paritätstest `--modular`, Teil Postgres.
  - Commit: `deployment: add database stack`
  - Ergebnis 2026-10-06: `config -q`, Policy-Test (9/9) und Paritätstest `--modular` (Postgres) sind grün. Gegenprobe: Mit vorübergehend eingebautem `5432:5432`, einem Passwort-Literal und `container_name` meldet der Policy-Test genau diese drei Verstöße.
  - **Abweichung (trivial):** Pflichtvariablen werden als `${VAR:?set in .env}` referenziert. Fehlt eine Variable, bricht `docker compose` sofort ab, statt mit leerem Wert zu starten.

- [ ] **6. `odoo-griffity-prod`-Stack**
  - Neu: `deployment/docker-services/odoo-griffity-prod/compose.yaml`
    - `name: odoo-griffity-prod`, Dienst `odoo`, Image `${ODOO_IMAGE:-ghcr.io/mikrowerk/tom-2-0-odoo-17-image}:${ODOO_IMAGE_TAG}`, `restart: unless-stopped`, **keine** Ports.
    - Volumes `odoo_data:/var/lib/odoo` (external) und `${ODOO_CONF_DIR:-/opt/odoo/conf}:/etc/odoo`.
    - Env `HOST=postgresql`, `PORT=5432`, `USER=${ODOO_DB_USER}`, `PASSWORD=${ODOO_DB_PASSWORD}`, `ODOO_CONFIG_ENCRYPTION_KEY=${ODOO_CONFIG_ENCRYPTION_KEY}`.
    - `command: [odoo, --log-level=info, -d, "${ODOO_DB_NAME}"]`
    - Netzwerke: `db-net` und `ingress-net` (Alias `odoo-griffity-prod`).
  - Neu: `deployment/docker-services/odoo-griffity-prod/.env.example` mit `ODOO_IMAGE_TAG`, `ODOO_DB_NAME`, `ODOO_DB_USER`, `ODOO_DB_PASSWORD`, `ODOO_CONFIG_ENCRYPTION_KEY` und `ODOO_CONF_DIR`.
  - Tests: Policy- und Paritätstest um Odoo erweitert, beide grün.
  - Commit: `deployment: add odoo-griffity-prod stack`

- [ ] **7. Backup-Stack `odoo-griffity-prod/backup`**
  - Neu: `deployment/docker-services/odoo-griffity-prod/backup/compose.yaml`
    - `name: odoo-griffity-prod-backup`, Dienst `backup-service`, Image `${BACKUP_IMAGE:-ghcr.io/mikrowerk/tom-backup-image:feature-build-image-for-odoo-17}`, `restart: unless-stopped`, keine Ports, Netzwerk nur `db-net`.
    - Volume `odoo_data:/var/lib/odoo:ro` (external).
    - Env: `POSTGRES_HOST=postgresql`, `POSTGRESQL_USERNAME=${ODOO_DB_USER}`, `POSTGRESQL_POSTGRES_PASSWORD=${ODOO_DB_PASSWORD}` (der Odoo-DB-User statt des Superusers, siehe Spec), `POSTGRESQL_DATABASE=${ODOO_DB_NAME}`, `DATA_DIR=/var/lib/odoo/data/filestore/${ODOO_DB_NAME}`, `BACKUP_RETENTION`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`, `S3_BUCKET` und `ENCRYPTION_PASSWORD`.
  - Neu: `deployment/docker-services/odoo-griffity-prod/backup/.env.example`
  - Tests: Policy- und Paritätstest um das Backup erweitert. Paritätstest bestätigt, dass `DATA_DIR` und die Env-Keys aus `backup.sh` vollständig sind.
  - Commit: `deployment: add separate backup stack for odoo-griffity-prod`

- [ ] **8. `ingress`-Stack mit Alias und robustem Upstream**
  - Neu: `deployment/docker-services/ingress/compose.yaml`
    - `name: ingress`
    - `nginx`: Image fest gepinnt auf eine aktuelle Stable-Version ≥ 1.27.3. Die Version wird im Schritt mit `docker run --rm nginx:<tag> nginx -v` ermittelt und im Commit genannt. `restart: unless-stopped`, Ports `80:80` und `443:443`, Volumes `./conf.d:/etc/nginx/conf.d:ro`, `${CERTBOT_DIR:-/opt/certbot}:/etc/letsencrypt:ro` und `certbot_www:/var/www/certbot`, Netzwerk `ingress-net` und Default-Netzwerk.
    - `certbot`: Image `docker.io/certbot/certbot`, `restart: unless-stopped`, Volumes `${CERTBOT_DIR:-/opt/certbot}:/etc/letsencrypt` und `certbot_www:/var/www/certbot`, `entrypoint` unverändert, nur Default-Netzwerk.
  - Neu: `deployment/docker-services/ingress/.env.example` (`CERTBOT_DIR`)
  - `ingress/conf.d/odoo.conf` anpassen, das ist die einzige inhaltliche Änderung an der nginx-Konfiguration:
    ```nginx
    resolver 127.0.0.11 valid=10s ipv6=off;
    upstream odoo-backend {
        zone odoo-backend 64k;
        server odoo-griffity-prod:8069 resolve;
    }
    ```
  - Tests:
    - `test-nginx-config.sh deployment/docker-services/ingress/conf.d` **ohne** `--add-host` ist grün. Das beweist, dass nginx auch ohne auflösbaren Odoo-Host startet.
    - Policy- und Paritätstest für alle vier Stacks sind grün.
  - Commit: `deployment: add ingress stack, resolve odoo upstream dynamically`

### Phase D – Skripte

- [ ] **9. `setup.sh`**
  - Neu: `deployment/docker-services/setup.sh` (idempotent, `set -euo pipefail`)
    1. Prüft, ob `docker` und `docker compose` v2 vorhanden sind.
    2. Legt die Netzwerke `db-net` und `ingress-net` an, falls sie fehlen.
    3. Legt die Volumes `postgres_data`, `odoo_data` und `certbot_www` an, falls sie fehlen, und meldet dabei deutlich „neu angelegt“, weil das auf der VPS nicht passieren sollte.
    3a. Erzeugt `ingress/conf.d/ssl-dhparams.pem` mit `openssl dhparam 2048`, falls die Datei fehlt. Eine vorhandene Datei wird nie überschrieben, eine ungültige wird gemeldet (Exit ≠ 0). Die Tests decken beide Fälle ab.
    4. Für jedes Stack-Verzeichnis mit `.env.example` (auch `*/backup`): `.env` muss existieren, jede Variable aus `.env.example` muss gesetzt, nicht leer und nicht `changeme` sein, und die Rechte dürfen nicht weiter als `600` sein (sonst Warnung).
    5. Konsistenzprüfung: `ODOO_DB_NAME`, `ODOO_DB_USER` und `ODOO_DB_PASSWORD` sind in `odoo-*/.env` und `odoo-*/backup/.env` identisch.
    6. Gibt am Ende eine Zusammenfassung aus. Exit-Code ≠ 0, sobald eine Prüfung fehlschlägt.
  - Option `--root <dir>` (Default: Skriptverzeichnis), damit die Tests auf einer Kopie laufen können.
  - Neu: `deployment/docker-services/tests/test-setup.sh` mit Fixture-Kopie unter `tests/.tmp/`:
    - fehlende `.env` → Exit ≠ 0
    - fehlende Variable → Exit ≠ 0
    - `changeme` → Exit ≠ 0
    - DB-User in odoo und backup unterschiedlich → Exit ≠ 0
    - gültige Fixture → Exit 0, zweiter Lauf → Exit 0 (Idempotenz), Netzwerke existieren
  - `shellcheck` ist sauber.
  - Commit: `deployment: add setup.sh`

- [ ] **10. `start-all-services.sh`**
  - Neu: `deployment/docker-services/start-all-services.sh`
    - Reihenfolge: `database` → warten, bis der Postgres-Healthcheck `healthy` meldet (mit Timeout) → alle `odoo-*/` → alle `odoo-*/backup/` (falls vorhanden) → `ingress`.
    - Jeweils `docker compose up -d` im Stack-Verzeichnis.
    - Ruft vorher `setup.sh` auf. Bricht ab, wenn `setup.sh` fehlschlägt.
    - `--dry-run` gibt die Befehle nur aus.
  - Neu: `deployment/docker-services/tests/test-start-order.sh` prüft die Reihenfolge per `--dry-run`, auch mit einem zweiten Fixture-Kunden (`odoo-test2`) mit und ohne `backup/`.
  - `shellcheck` ist sauber.
  - Commit: `deployment: add start-all-services.sh`

### Phase E – Integration

- [ ] **11. Lokaler Smoke-Test des Gesamtsystems**
  - Neu: `deployment/docker-services/tests/smoke-test.sh`
    - Bricht ab, falls die Volumes `postgres_data`, `odoo_data` oder `certbot_www` lokal schon existieren. So werden keine fremden Daten angefasst.
    - **Native arm64-Images** (siehe Spec, Abschnitt „Smoke-Test auf Apple Silicon“), über die Image-Variablen in den Test-`.env`-Dateien gesetzt:
      - `POSTGRES_IMAGE=docker.io/bitnamilegacy/postgresql:15.10.0-debian-12-r2`
      - `ODOO_IMAGE=docker.io/library/odoo`, `ODOO_IMAGE_TAG=17.0`
      - `BACKUP_IMAGE=tom-backup-image:smoke`, lokal gebaut mit `docker build -t tom-backup-image:smoke ../tom-backup-image` (vorher prüfen, dass Branch `feature/build-image-for-odoo-17` ausgecheckt ist). Ohne Checkout wird das Produktiv-Image mit `--platform linux/amd64` verwendet und eine Warnung ausgegeben.
      - Vorab prüft der Test mit `docker image inspect --format '{{.Architecture}}'`, dass auf einem arm64-Host alle Images außer im Fallback `arm64` sind.
    - Erzeugt unter `tests/.tmp/` Dummy-`.env`-Dateien, eine Test-`odoo.conf` (`workers = 0`, `db_host = postgresql`, `dbfilter = ^%h$`) als `ODOO_CONF_DIR` und ein selbstsigniertes Zertifikat als `CERTBOT_DIR/live/tomagency.griffity.de/`.
    - Ablauf und Prüfungen:
      1. `setup.sh` ist grün, `database` wird hochgefahren und meldet `healthy`.
      2. Test-DB `tomagency.griffity.de` per `docker compose run --rm odoo odoo -d … -i base --stop-after-init` initialisieren.
      3. **Robuster Start:** `ingress` hochfahren, **während Odoo nicht läuft**. Der nginx-Container läuft, ein Request auf `https://tomagency.griffity.de/` (per `curl -k --resolve …:443:127.0.0.1`) liefert 502.
      4. `odoo-griffity-prod` hochfahren. `/web/login` liefert 200, **ohne nginx neu zu starten**.
      5. `http://…/` liefert einen 301-Redirect auf HTTPS.
      6. **Ports:** `docker inspect` zeigt für Postgres `HostIp 127.0.0.1`. Für Odoo gibt es kein Port-Binding.
      7. **Netzisolation:** Im nginx-Container schlägt `getent hosts postgresql` fehl. Im Odoo-Container ist `postgresql` auflösbar.
      8. **Backup:** Stack `odoo-griffity-prod/backup` hochfahren. Im Container läuft `pg_dump` mit den gesetzten `POSTGRESQL_*`-Variablen gegen die Test-DB mit Exit 0. Das beweist, dass der Odoo-DB-User für das Backup reicht, ohne S3 anzufassen. `DATA_DIR` ist read-only gemountet.
      9. **Entkopplung:** `docker compose up -d --force-recreate` im Odoo-Stack lässt die Container-ID des Backups unverändert. `docker compose down` im Odoo-Stack lässt das Backup weiterlaufen.
      10. Alle Stacks stoppen, `start-all-services.sh` ausführen. Alle Dienste laufen wieder, `/web/login` liefert 200.
    - Aufräumen über `trap`: alle Stacks `down`, Test-Volumes und -Netzwerke entfernen, `tests/.tmp/` löschen.
  - Nachweis: Der Smoke-Test ist grün, das Protokoll wird im Commit-Text kurz zusammengefasst.
  - Commit: `deployment: add end-to-end smoke test`

### Phase F – Aufräumen und Doku

- [ ] **12. Altdateien archivieren**
  - `git mv docker-compose.yaml odoo.conf nginx-conf nginx-conf-new archive/`
  - `tests/test-compose-parity.sh --monolith archive/docker-compose.yaml` ist weiterhin grün, und der Monolith ist damit als Referenz weiter testbar.
  - Prüfen, dass nichts im Repo mehr auf die alten Pfade verweist (`grep -rn` über `Dockerfile`, `.github/`, Skripte). Ausnahme ist `CLAUDE.md`, das in Schritt 13 angepasst wird.
  - `test-repo-hygiene.sh` ist grün, `archive/` liegt nicht im Build-Kontext.
  - Commit: `chore: move monolithic compose and old configs to archive/`

- [ ] **13. `CLAUDE.md` an die Spec anpassen**
  - Tabelle „Aufbau“ auf `deployment/docker-services/`, `archive/` und `.dockerignore` umstellen.
  - Zielarchitektur-Baum auf den tatsächlichen Stand bringen. Backup-Hinweis bei `database/` entfernen, Backup unter `odoo-*/backup/` eintragen. `infra/` entfernen. Netzwerke `db-net` und `ingress-net` sowie die Aliase nennen.
  - Abschnitt „Deployment“ ergänzen: `setup.sh`, `start-all-services.sh`, Image-Tag über `ODOO_IMAGE_TAG` in der `.env`, Backup vor einem Update stoppen (Verweis auf die Backup-Spec).
  - `.features/specs|plans|docs` auf `.features/.specs|.plans|.docs` umstellen.
  - Hinweise zu `nginx-conf-new/` und zur fehlenden `/websocket`-Weiterleitung aktualisieren (Beobachtung aus der Spec).
  - Test-Befehle aus `deployment/docker-services/tests/` aufnehmen.
  - Commit: `docs: update CLAUDE.md for modular deployment`

- [ ] **14. Abschließende Verifikation**
  - `shellcheck deployment/docker-services/*.sh deployment/docker-services/tests/*.sh`
  - Für jeden Stack `docker compose --env-file .env.example -f … config -q`
  - `tests/test-compose-parity.sh --monolith archive/docker-compose.yaml` und `--modular deployment/docker-services`
  - `tests/test-compose-policy.sh`, `tests/test-nginx-config.sh deployment/docker-services/ingress/conf.d`, `tests/test-repo-hygiene.sh`, `tests/test-setup.sh`, `tests/test-start-order.sh`
  - `tests/smoke-test.sh` (vollständig)
  - Image-Build: `docker build --platform linux/amd64 .` lokal, optional, weil Ghostscript lange kompiliert. Alternativ muss der CI-Lauf `build_publish_image.yml` nach dem Push grün sein.
  - `git status` ist sauber, und keine `.env` ist getrackt (`git ls-files | grep -E '(^|/)\.env$'` liefert nichts).
  - Haken in diesem Plan setzen. Commit: `docs: mark modular compose plan as done`

---

## Nicht Teil dieses Plans (laut Spec)

- Cutover-Runbook für die VPS, Kopierweg und Ablageort auf der VPS
- Vorlage für weitere Kunden und das Anlegen von DB-Usern
- `odoo_user_add.sh` und `mount_s3fs.sh`
- `max_connections` und Tuning
- Inhaltliche nginx-Änderungen über Upstream und Resolver hinaus, z. B. die `/websocket`-Weiterleitung
- Migration auf `postgres:18` (eigene Spec folgt)
- Versioniertes Filestore-Backup (`.features/.specs/backup-filestore-versioning.md`)

## Risiken

- **Smoke-Test mit Ersatz-Images:** Der Smoke-Test läuft nativ auf arm64, aber mit `odoo:17.0` statt des TOM-Images und mit `bitnamilegacy/postgresql` statt der ghcr-Kopie. Er weist nach, dass die Infrastruktur funktioniert, nicht dass das TOM-Image und seine Module darin starten. Dass die Produktiv-Images korrekt verdrahtet sind, sichern Paritäts- und Policy-Test ab (Image-Defaults, Env-Keys, Volumes, Command). Ein Lauf mit den echten Images bleibt dem Cutover vorbehalten (nicht im Scope).
- **`resolve` im `upstream`:** Erfordert nginx ≥ 1.27.3. Das wird in Schritt 8 durch das Pinning und den `nginx -t`-Test ohne `--add-host` abgesichert.
- **Bitnami-Env bei bestehenden Daten:** Die `POSTGRESQL_*`-Variablen wirken nur bei der Initialisierung. Auf der VPS mit vorhandenem `postgres_data` ändern sie nichts. Für den Cutover muss deshalb der Odoo-DB-User, den das Backup nutzt, schon existieren und Owner der DB sein.
