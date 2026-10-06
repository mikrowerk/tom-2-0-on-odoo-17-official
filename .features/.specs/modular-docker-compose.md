# Spec: Make existing docker compose files modular

## Background
The existing 'docker-compose.yaml' file has to be made modular, so that it it easier to maintain.

## Goals
- split the given compose file into several parts, which should fit into the given directory structure herein:
'deployment/docker-services'

### Datebase
Target directory: deployment/docker-services/database
compose-file runs the postgres service

### ingress
Target directory: deployment/docker-services/ingress
compose-file runs ningx and certbot

### Odoo-app
Target directory: deployment/docker-services/odoo-griffity-prod
compose-file runs the odoo service and the backup-service

### External Docker Network or other items should be created by a bash script in: deployment/docker-services


## Offene Fragen (Review 2026-10-06)

Bitte jeweils inline unter **Antwort:** beantworten.

### Scope & Migration

1. **Cutover der Produktion:** Gehört die Umstellung des laufenden Systems auf der VPS (alten Stack stoppen, neue Stacks starten, Rollback auf `docker-compose.yaml`) zum Scope, z. B. als Runbook in `.features/.docs/`? Oder umfasst die Spec nur die Dateien im Repo? Ist eine kurze Downtime akzeptabel?
   **Antwort:** Runbook ist einstweilen out-of-scope

2. **Alte Dateien:** Was passiert mit `docker-compose.yaml`, `odoo.conf`, `nginx-conf/` und `nginx-conf-new/` im Repo-Root: nach der Migration löschen, als Referenz behalten oder sofort nach `deployment/` verschieben?
   **Antwort:** in archiv verschieben

3. **Ablageort auf der VPS:** Wie kommen die Dateien aus `deployment/docker-services/` auf die VPS (Git-Clone des Repos auf der VPS, rsync/scp, …) und unter welchem Pfad (`/docker-services`, `/srv/docker-services`, `/opt/...`)? Die heutigen Bind-Mounts zeigen auf `/opt/odoo/conf`, `/opt/nginx/config` und `/opt/certbot`. Sollen das künftig Pfade relativ zum jeweiligen Stack-Verzeichnis sein (`./config`, `./conf.d`)?
   **Antwort:** ist einstweilen out-of-scope

4. **Weitere Kunden:** Ist eine Vorlage für weitere Odoo-Instanzen (`odoo-kunde2`) Teil dieser Spec, oder geht es nur um `odoo-griffity-prod`? Gehört das Anlegen von Datenbank und DB-User für einen weiteren Kunden ins Bash-Skript?
   **Antwort:** ist einstweilen out-of-scope

5. **Hilfsskripte:** Sollen `odoo_user_add.sh` und `mount_s3fs.sh` nach `deployment/docker-services/` umziehen bzw. vom neuen Setup-Skript aufgerufen werden?
   **Antwort:** ist einstweilen out-of-scope

### Backup-Service

6. **Zuordnung:** Die Spec ordnet `backup-service` der Odoo-App zu (`odoo-griffity-prod`), die Zielstruktur in `CLAUDE.md` dagegen `database/` („ggf. Backup-Service“). Was gilt? Bei der Variante „pro Kunde“ sichert jeder Kunden-Stack seine DB und seinen Filestore selbst. Bei der Variante „zentral“ bräuchte der Dienst Zugriff auf die Filestores aller Kunden.
   **Antwort:** backup-service gehört zur odoo-app da instanz-spezifisch. Korrigierte CLAUDE.md

7. **DB-Zugang des Backups:** Heute nutzt der Backup-Service den Postgres-Superuser (`POSTGRESQL_POSTGRES_PASSWORD`). Soll das so bleiben, oder soll er den DB-User des Kunden verwenden? Bleibt das Image-Tag `feature-build-image-for-odoo-17` unverändert?
   **Antwort:** falls möglich odoo-instanz DB user verwenden

### Netzwerk & Hostnamen

8. **Netzwerke:** Ein gemeinsames externes Netzwerk für alles, oder zwei getrennte (z. B. `db-net` für Postgres ↔ Odoo/Backup und `ingress-net` für nginx ↔ Odoo), damit nginx Postgres gar nicht erreichen kann? Wie sollen die Netzwerke heißen?
   **Antwort:** getrennte Netzwerke

9. **Hostname der Odoo-Instanz:** nginx leitet heute fest an `odoo:8069` und `odoo:8072` weiter. Auf einem gemeinsamen Netzwerk würden mehrere Stacks mit dem Service-Namen `odoo` kollidieren. Vorschlag: Jede Instanz bekommt einen Netzwerk-Alias, z. B. `odoo-griffity-prod`, und der nginx-vhost zeigt darauf. Einverstanden?
   **Antwort:** einverstanden

10. **Hostname der Datenbank:** Soll Postgres im Netzwerk weiterhin `postgresql` heißen? `odoo.conf` (`db_host`) und der Backup-Service (`POSTGRES_HOST`) erwarten diesen Namen.
    **Antwort:** ja

11. **Startreihenfolge:** Über Stack-Grenzen hinweg greift `depends_on` nicht. nginx bricht beim Start ab, wenn ein Upstream-Host (`odoo-…`) nicht auflösbar ist, wenn also ein Kunden-Stack nicht läuft. Soll nginx so konfiguriert werden, dass es auch ohne laufende Odoo-Instanz startet (Docker-DNS-Resolver `127.0.0.11` plus Variablen in `proxy_pass`)? Oder reicht eine feste Startreihenfolge (database → odoo-* → ingress) im Skript?
    **Antwort:** ja, Lösung soll robust sein

### Ports & Sicherheit

12. **Ports:** Bitte bestätigen. Postgres wird nur an `127.0.0.1:5432` gebunden (heute `5432:5432`). Odoo bekommt **keinen** Host-Port mehr (heute ist `8069:8069` öffentlich und umgeht nginx). Nur nginx veröffentlicht 80 und 443.
    **Antwort:** Postgres wird nur an `127.0.0.1:5432`

13. **Restart-Policy:** Postgres hat heute keine `restart`-Policy. Soll überall `restart: unless-stopped` gesetzt werden?
    **Antwort:** ja, dort wo es Sinn macht

14. **Fixe `container_name`:** `CLAUDE.md` sieht keine festen `container_name` vor, heute gibt es aber `postgres_15_15`, `odoo_17`, `nginx`, `certbot` und `backup_manager`. Hängen Skripte, Cronjobs oder Monitoring auf der VPS an diesen Namen? Stattdessen würde je Stack ein fester Projektname (`name:` in `compose.yaml`) gesetzt.
    **Antwort:** OK, verfahre nach best practices

### Secrets & Konfiguration

15. **Mechanismus:** Reichen `.env`-Dateien pro Stack, oder sollen Passwort-Dateien (Docker `secrets:` / `*_FILE`) verwendet werden, wo das Image es unterstützt? Bitnami-Postgres unterstützt `POSTGRESQL_*_PASSWORD_FILE`. Beim Odoo-Basisimage `ghcr.io/mikrowerk/odoo-17-official-image-amd-64` ist nicht dokumentiert, ob `PASSWORD_FILE` unterstützt wird.
    **Antwort:** Gehe davon aus, dass das bitnami image durch das offizielle Docker image ersetzt wird. Bevorzugt sind .env secrets

16. **`odoo.conf` mit Secrets:** `odoo.conf` enthält `admin_passwd`, `db_user` und `db_password`. Mögliche Wege: (a) `config/odoo.conf` liegt nur auf der VPS (gitignored), ins Repo kommt `odoo.conf.example`; (b) beim Start aus einem Template plus `.env` erzeugen (envsubst); (c) die DB-Zugangsdaten nur per Env (`USER`/`PASSWORD`), `admin_passwd` als Hash in einer gitignorierten Datei. Was ist gewünscht?
    **Antwort:** gehe davon aus, dass secrets nur auf der VPS liegen

17. **Image-Tag:** Soll der Odoo-Image-Tag (heute fest `026aae4`) in die `.env` des Kunden-Stacks wandern (z. B. `ODOO_IMAGE_TAG`), damit ein Update nur die `.env` ändert?
    **Antwort:** OK

18. **Konfigurationsstand:** Was läuft heute produktiv? Das Repo-`odoo.conf` (workers = 6) passt nur zu `nginx-conf-new/`. Soll der neue `ingress`-Stack `nginx-conf-new/` übernehmen, inklusive `options-ssl-nginx.conf` und `ssl-dhparams.pem` aus `nginx-conf/`? Ist `ssl-dhparams.pem` unkritisch genug, um versioniert zu bleiben?
    **Antwort:** ist einstweilen out-of-scope, bestehende config Dateien werden weiter verwendet

19. **vhost-Verantwortung:** Liegt die vhost-Datei eines Kunden (`tomagency.griffity.de.conf`) im `ingress`-Stack oder im Kunden-Verzeichnis (dann per Mount bzw. Kopie in den ingress)? Ist die Erst-Ausstellung von Zertifikaten für neue Domains Teil des Scopes?
    **Antwort:** ist einstweilen out-of-scope, bestehende config Dateien werden weiter verwendet

### Datenbank & Volumes

20. **Volumes:** Sollen die bestehenden externen Volumes `postgres_data`, `odoo_data` und `certbot_www` unverändert weiterverwendet werden (keine Datenmigration)? Oder sollen sie umbenannt werden, z. B. `odoo-griffity-prod_data`? Umbenennen bedeutet Daten kopieren. Bleibt `/opt/certbot` als Bind-Mount bestehen?
    **Antwort:** keine Migration

21. **Postgres-Image:** Bitnami hat seine kostenlosen Images im Docker Hub 2025 eingestellt bzw. nach `bitnamilegacy/` verschoben. Ein `docker pull docker.io/bitnami/postgresql:15` funktioniert womöglich nicht mehr bzw. bekommt keine Updates. Soll das Image beibehalten werden (Tag pinnen bzw. `bitnamilegacy/postgresql`)? Oder ist ein Wechsel auf das offizielle `postgres:15` gewünscht? Ein Wechsel ändert Datenpfad und Env-Variablen und wäre ein eigenes Feature.
    **Antwort:** verwende die Backup-Kopie: 'ghcr.io/mikrowerk/postgresql:15'

22. **`max_connections`:** Postgres läuft heute mit dem Default 100. Soll der Wert im `database`-Stack explizit gesetzt werden, damit die `db_maxconn`-Rechnung für mehrere Instanzen nachvollziehbar bleibt?
    **Antwort:** ist einstweilen out-of-scope

### Setup-Skript

23. **Umfang:** Was genau soll das Skript in `deployment/docker-services/` tun? Netzwerk(e) anlegen, externe Volumes anlegen, Verzeichnisse und Rechte (UID 101), Prüfung, ob `.env` vorhanden ist? Soll es zusätzlich alle Stacks in der richtigen Reihenfolge starten und stoppen (`up`/`down`/`pull`), oder nur einmalig einrichten? Es muss idempotent sein, also mehrfach ausführbar. Bitte bestätigen und einen Namen nennen (z. B. `setup.sh`).
    **Antwort:** mehrere scripte,
    - setup.sh für initialen setup und prüfen .env
    - start-all-services.sh für starten in richtiger reihenfolge

### Verifikation & Repo-Hygiene

24. **Tests:** Was gilt als Nachweis? Vorschlag: `docker compose config` je Stack (Syntax und Variablen), `shellcheck` für das Skript, `nginx -t` gegen die ingress-Konfiguration und ein lokaler Smoke-Test (alle Stacks lokal mit Dummy-`.env` und leerer Test-DB starten, Odoo-Login über nginx/HTTP erreichbar). Reicht das, und ist ein lokaler Lauf (amd64-Image unter Emulation auf dem Mac) praktikabel?
    **Antwort:** OK

25. **`.dockerignore`:** Es gibt keine `.dockerignore`. `deployment/` (inklusive lokaler `.env`-Dateien) und `.features/` würden damit in den Build-Kontext der CI bzw. lokaler Builds geschickt, landen aber nicht im Image. Soll eine `.dockerignore` angelegt werden?
    **Antwort:** ja

26. **`CLAUDE.md` angleichen:** Dort stehen noch `infra/`, `.features/specs|plans|docs` (ohne Punkt) und `/docker-services/`. Die Spec nutzt `.features/.specs/` und `deployment/docker-services/`. Soll `CLAUDE.md` an die Spec angepasst werden?
    **Antwort:** ja

## Entscheidungen

### 2026-10-06 (aus den Antworten auf das Review)

**Scope**
- Nicht im Scope: Cutover-Runbook (1), Ablageort und Kopierweg auf der VPS (3), Vorlage für weitere Kunden und das Anlegen von DB-Usern (4), Umzug von `odoo_user_add.sh` und `mount_s3fs.sh` (5), inhaltliche Änderungen an der nginx- und Odoo-Konfiguration (18, 19), `max_connections` (22).
- `docker-compose.yaml`, `odoo.conf`, `nginx-conf/` und `nginx-conf-new/` werden in ein Archiv-Verzeichnis `archive/` im Repo-Root verschoben (2).
- `CLAUDE.md` wird an die Spec angepasst: `deployment/docker-services/`, `.features/.specs|.plans|.docs`, Backup gehört zur Odoo-App (6, 26).
- Es wird eine `.dockerignore` angelegt, die mindestens `deployment/`, `.features/`, `archive/` und `**/.env` ausschließt (25).

**Stacks und Dienste**
- `database`: nur Postgres. `ingress`: nginx und certbot. `odoo-griffity-prod`: Odoo und `backup-service`, denn das Backup ist instanzspezifisch (6).
- Postgres-Image ist `ghcr.io/mikrowerk/postgresql:15` (21). Geprüft am 2026-10-06: Das ist eine Kopie von Bitnami PostgreSQL 15.10.0 (UID 1001, Volume `/bitnami/postgresql`, Env `POSTGRESQL_*`). Damit bleiben die bestehenden Daten kompatibel.
- Das Backup nutzt den DB-User der Odoo-Instanz statt des Superusers (7). Geprüft in `tom-backup-image/backup.sh`: Das Skript ruft `pg_dump -U $POSTGRESQL_USERNAME` mit `PGPASSWORD=$POSTGRESQL_POSTGRES_PASSWORD` auf. Es reicht also, `POSTGRESQL_USERNAME` und `POSTGRESQL_POSTGRES_PASSWORD` auf die Zugangsdaten des Odoo-DB-Users zu setzen, das Image muss nicht geändert werden. Image-Tag `feature-build-image-for-odoo-17` bleibt.
- Feste Projektnamen über `name:` in jeder `compose.yaml` (`database`, `ingress`, `odoo-griffity-prod`). Es gibt keine `container_name` mehr (14).
- `restart: unless-stopped` gilt für Postgres, Odoo, nginx, certbot und Backup (13).

**Netzwerk**
- Es gibt zwei getrennte externe Netzwerke (8): `db-net` verbindet Postgres mit Odoo und Backup, `ingress-net` verbindet nginx und certbot mit Odoo. nginx kann Postgres damit nicht erreichen.
- Odoo hängt in `ingress-net` unter dem Alias `odoo-griffity-prod` (9). Postgres hängt in `db-net` unter dem Alias `postgresql` (10).
- nginx muss auch dann starten, wenn ein Odoo-Stack nicht läuft (11). Dafür sorgen der Docker-DNS-Resolver `127.0.0.11` und eine dynamische Auflösung des Upstreams.

**Ports**
- Postgres wird nur an `127.0.0.1:5432` gebunden, der Zugriff von außen läuft per SSH-Tunnel (12).

**Secrets und Konfiguration**
- Secrets stehen in `.env`-Dateien pro Stack. Diese liegen nur auf der VPS und sind gitignored. Im Repo liegt je Stack eine `.env.example` (15, 16).
- Der Odoo-Image-Tag wird als `ODOO_IMAGE_TAG` in der `.env` von `odoo-griffity-prod` gesetzt (17).

**Volumes**
- Keine Datenmigration (20). Die externen Volumes `postgres_data`, `odoo_data` und `certbot_www` bleiben mit ihren Namen erhalten.

**Skripte (23)**
- `deployment/docker-services/setup.sh` ist idempotent. Es legt die Netzwerke `db-net` und `ingress-net` an, legt fehlende externe Volumes an und prüft, ob jede `.env` existiert und alle Variablen aus der jeweiligen `.env.example` gesetzt sind.
- `deployment/docker-services/start-all-services.sh` startet die Stacks in der Reihenfolge `database` → alle `odoo-*` → `ingress`.

**Verifikation (24)**
- Nachweis über `docker compose config` je Stack, `shellcheck`, `nginx -t` und einen lokalen Smoke-Test (alle Stacks mit Dummy-`.env` und leerer Test-DB; Odoo über nginx erreichbar).

## Folgefragen (2026-10-06)

F1. **Postgres-Image und Antwort 15:** Antwort 15 sagt „Gehe davon aus, dass das bitnami image durch das offizielle Docker image ersetzt wird“, Antwort 21 legt `ghcr.io/mikrowerk/postgresql:15` fest, und das ist Bitnami. Ich verstehe das so: In diesem Feature bleibt es bei der Bitnami-Kopie (Env `POSTGRESQL_*`, Volume `/bitnami/postgresql`), und der Wechsel auf das offizielle `postgres`-Image ist ein späteres, eigenes Feature, weil er eine Datenmigration erfordert (andere Pfade, UID 999 statt 1001). Richtig?
   **Antwort:** zunächst wird  `ghcr.io/mikrowerk/postgresql:15` verwendet, die Migration auf das offiziell postgres:18 image wird eine eigene Spec

F2. **nginx-Konfiguration vs. Alias und robuster Start:** Antwort 18/19 sagt, die bestehenden Config-Dateien werden unverändert weiterverwendet. Die Entscheidungen 9 und 11 lassen sich aber nur mit Änderungen am vhost umsetzen: Upstream `odoo-griffity-prod` statt `odoo`, `resolver 127.0.0.11` und `server … resolve;` im `upstream` (das unterstützt nginx Open Source ab 1.27.3). Wie soll das gelöst werden?
   - (a) **Empfehlung:** Die nginx-Konfiguration kommt ins Repo nach `deployment/docker-services/ingress/conf.d/`, als Basis dient `nginx-conf-new/` plus `options-ssl-nginx.conf` und `ssl-dhparams.pem`. Nur die Upstream- und Resolver-Zeilen ändern sich. Der Mount-Pfad ist über die `.env` einstellbar (Default `./conf.d`), das nginx-Image wird auf `nginx:1.29` gepinnt statt `latest`.
   - (b) Die vhost-Dateien bleiben unverändert unter `/opt/nginx/config` auf der VPS. Odoo bekommt in `ingress-net` zusätzlich den Alias `odoo`, damit die bestehende Konfiguration weiter funktioniert. Auf den robusten Start (11) wird vorerst verzichtet.
   **Antwort:** config-files sind hier: deployment/docker-services/ingress  (ohne ssl cert)

F3. **Bind-Mount-Pfade:** Da der Ablageort auf der VPS nicht im Scope ist, mein Vorschlag: Die heutigen Host-Pfade bleiben als Defaults erhalten, sind aber über die `.env` überschreibbar. Das betrifft `ODOO_CONF_DIR=/opt/odoo/conf`, `CERTBOT_DIR=/opt/certbot` und `NGINX_CONF_DIR` (abhängig von F2). Für den lokalen Smoke-Test werden sie auf lokale Verzeichnisse gesetzt. Einverstanden?
   **Antwort:** OK

F4. **Odoo-Host-Port:** Antwort 12 nennt nur Postgres. Bitte bestätigen, dass Odoo **keinen** Host-Port mehr veröffentlicht (heute ist `8069:8069` öffentlich). Odoo wäre dann nur noch über nginx erreichbar. Zum Debuggen ginge ein SSH-Tunnel auf `127.0.0.1:8069`, falls gewünscht.
   **Antwort:** ja, kein öffentliche Host-Port

### 2026-10-06 (Nachtrag: eigenes Compose-File für den Backup-Service)

Diese Entscheidung ersetzt den Teil der Entscheidung „Stacks und Dienste“, nach dem `odoo-griffity-prod` Odoo **und** `backup-service` in einer Datei enthält. Das Backup bleibt kundenspezifisch, läuft aber als eigenes Compose-Projekt.

**Bewertung**

Warum ein Rollback das Pausieren des Backups braucht: Geprüft in `tom-backup-image` (Branch `feature/build-image-for-odoo-17`). Das Backup läuft per Cron neunmal am Tag (5 bis 21 Uhr, alle 2 h).
- **DB-Dumps** werden mit Zeitstempel hochgeladen (`copyto`) und erst nach `BACKUP_RETENTION` gelöscht. Ein fehlerhafter Dump nach einem Update überschreibt also keine älteren Dumps.
- **Filestore** wird mit `rclone sync` gespiegelt. Davon gibt es **nur eine Kopie ohne Versionen**. Löscht oder verändert ein fehlgeschlagenes Update Dateien im Filestore, übernimmt der nächste Backup-Lauf das ins S3. Der zum letzten guten Dump passende Filestore ist dann weg. Das Pausieren des Backups während eines Updates ist deshalb fachlich nötig.

| Variante | Backup pausieren | Risiko |
|---|---|---|
| Ein Compose-File, Backup als Service | `docker compose stop backup-service` | Jedes `docker compose up -d` im Kunden-Stack startet das Backup wieder, und genau das führt man beim Update aus, um das neue Image-Tag zu aktivieren. Der Fehler passiert leicht und ohne Warnung. |
| Ein Compose-File mit `profiles: [backup]` | `COMPOSE_PROFILES` in der `.env` leeren bzw. setzen | Funktioniert. Der Zustand „Backup aus“ steckt dann aber in einer Variable und ist bei `docker compose ps` nicht direkt zu sehen. `down` ohne Profil lässt verwaiste Container zurück. |
| **Eigenes Compose-Projekt** (empfohlen) | `docker compose stop` im Backup-Verzeichnis | `up`, `down` und `pull` im Odoo-Stack berühren das Backup nie. Kosten: eine zweite `.env`, in der die DB-Zugangsdaten doppelt stehen. |

**Festlegung**
- Das Backup bekommt eine eigene Datei unter `deployment/docker-services/odoo-griffity-prod/backup/compose.yaml` mit dem Projektnamen `odoo-griffity-prod-backup`. Es liegt im Kunden-Verzeichnis, weil es kundenspezifisch ist. Es liegt in einem Unterverzeichnis statt als Geschwister `odoo-griffity-prod-backup/`, weil `start-all-services.sh` sonst ein Verzeichnis, das mit `odoo-` beginnt, als Odoo-Stack starten würde.
- Das Backup nutzt die externen Ressourcen `db-net` und `odoo_data` (read-only), genau wie der Odoo-Stack.
- Eigene `backup/.env` (Vorlage `backup/.env.example`) mit S3-Zugang, `ENCRYPTION_PASSWORD`, `BACKUP_RETENTION` und den DB-Zugangsdaten. `setup.sh` prüft, dass DB-Name und DB-User in `odoo-griffity-prod/.env` und `odoo-griffity-prod/backup/.env` übereinstimmen.
- `start-all-services.sh` startet je Kunde zuerst Odoo und danach dessen Backup, falls `backup/compose.yaml` existiert. Die Reihenfolge ist `database` → `odoo-*` → `odoo-*/backup` → `ingress`.
- Ablauf beim Update, zur Information. Das Runbook selbst bleibt außerhalb des Scopes:
  1. Manuelles Backup auslösen (`docker compose exec backup-service /app/entrypoint.sh`).
  2. Backup stoppen.
  3. Odoo-Update durchführen.
  4. Prüfen, ob alles läuft.
  5. Bei Erfolg Backup wieder starten, sonst Rollback auf den letzten Dump und den unveränderten S3-Filestore.

F5. **Filestore ohne Versionen:** Durch das Pausieren hängt die Rollback-Fähigkeit davon ab, dass vor jedem Update jemand das Backup stoppt. Robuster wäre eine Versionierung im Backup-Image (`rclone sync --backup-dir …/filestore_versions/<datum>`) oder die Objekt-Versionierung im S3-Bucket. Beides betrifft `tom-backup-image` bzw. den Bucket und nicht dieses Repo. Ich würde es als eigenes Feature notieren und hier außerhalb des Scopes lassen. Einverstanden?
   **Antwort:** erstelle zum Optimieren des Backup eine eigene Spec

### 2026-10-06 (aus den Antworten auf die Folgefragen F1–F5)

- **F1:** Vorerst wird `ghcr.io/mikrowerk/postgresql:15` (Bitnami-Kopie) verwendet. Die Migration auf das offizielle Image `postgres:18` bekommt eine eigene Spec und gehört nicht zu diesem Feature.
- **F2:** Die nginx-Konfiguration liegt im Repo unter `deployment/docker-services/ingress/`, ohne SSL-Zertifikate. Die Zertifikate bleiben im certbot-Verzeichnis auf dem Host. Für Alias (9) und robusten Start (11) werden nur die Upstream- und Resolver-Zeilen angepasst.
- **F3:** Host-Pfade bleiben als Defaults erhalten und sind über die `.env` überschreibbar (`ODOO_CONF_DIR=/opt/odoo/conf`, `CERTBOT_DIR=/opt/certbot`).
- **F4:** Odoo veröffentlicht keinen Host-Port.
- **F5:** Die Versionierung bzw. Optimierung des Backups bekommt eine eigene Spec: `.features/.specs/backup-filestore-versioning.md`.

**Technische Festlegungen bei der Planung** (ohne Rückfrage, Einspruch jederzeit möglich)
- Die nginx-Dateien kommen nach `ingress/conf.d/` und werden als `./conf.d:/etc/nginx/conf.d:ro` gemountet. Ohne Unterverzeichnis würden `compose.yaml` und `.env` des ingress-Stacks mit in den nginx-Container gemountet.
- `ingress/options-ssl-nginx.conf` ist beschädigt (Copy-&-Paste-Rest). Vor dem eigentlichen Inhalt stehen eine Kopie von `odoo.conf` und ein Shell-Prompt (`gfr@ubuntu:~$ cat …`). nginx würde damit nicht starten (doppelter `upstream odoo-backend`). Die Datei wird auf den reinen certbot-Inhalt bereinigt. Auch die versionierte Vorlage `nginx-conf/options-ssl-nginx.conf` ist beschädigt: Am Dateiende hängt der Prompt-Rest `root@u`. Die Repo-Kopie ist also nicht mit der Datei auf der VPS identisch und kann nicht als fehlerfreie Baseline dienen.
- `ssl-dhparams.pem` fehlt in `ingress/`, der vhost bindet die Datei aber ein. Sie enthält öffentliche Parameter und kein Secret und wird deshalb aus `nginx-conf/` übernommen.
- Das nginx-Image wird auf eine feste Stable-Version ≥ 1.27.3 gepinnt statt `latest`, weil `server … resolve;` in einem `upstream` erst ab dieser Version in nginx Open Source funktioniert.
- certbot hängt nicht in `ingress-net`, weil er Odoo nicht erreichen muss. Er nutzt das Default-Netzwerk seines Stacks. Damit wird die Entscheidung „Netzwerk“ von oben präzisiert.

**Beobachtung, nicht im Scope:** Auf der VPS läuft die alte nginx-Konfiguration (`nginx-conf/`, identisch mit `ingress/`) ohne Weiterleitung von `/websocket` an Port 8072. Das `odoo.conf` im Repo setzt dagegen `workers = 6`. Falls die Odoo-Konfiguration auf der VPS ebenfalls Worker nutzt, funktionieren Live-Updates (Chatter, Benachrichtigungen) dort heute schon nicht. Das Feature ändert daran nichts, es bleibt beim Status quo.

### 2026-10-06 (Smoke-Test auf Apple Silicon)

Der lokale Smoke-Test soll native arm64-Images verwenden. Geprüft am 2026-10-06 mit `docker buildx imagetools inspect`:

| Dienst | Produktiv-Image | arm64? | Image im Smoke-Test |
|---|---|---|---|
| Postgres | `ghcr.io/mikrowerk/postgresql:15` (Bitnami 15.10.0-debian-12-r2) | nein | `docker.io/bitnamilegacy/postgresql:15.10.0-debian-12-r2` (gleicher Build-Stand, multi-arch) |
| Odoo | `ghcr.io/mikrowerk/tom-2-0-odoo-17-image:<tag>` | nein (auch das Basisimage ist nur amd64) | `docker.io/library/odoo:17.0` (offiziell, ohne TOM-Module) |
| Backup | `ghcr.io/mikrowerk/tom-backup-image:feature-build-image-for-odoo-17` | nein | lokal nativ gebaut aus `../tom-backup-image` (Branch `feature/build-image-for-odoo-17`, Basis `alpine`). Fehlt der Checkout, läuft das Produktiv-Image unter Emulation. |
| nginx | gepinnte Stable-Version | ja | wie Produktion |
| certbot | `certbot/certbot` | ja | wie Produktion |

- Entscheidung (Rückfrage beantwortet): Für Odoo wird `odoo:17.0` verwendet. Der Smoke-Test prüft die Infrastruktur (nginx, Netzwerke, Ports, DB, Login, Backup-Zugriff, Entkopplung), nicht die TOM-Module. Das TOM-Basisimage ist vom offiziellen Odoo-Image abgeleitet, deshalb funktionieren dieselben Env-Variablen (`HOST`, `USER`, `PASSWORD`) und dieselbe Konfiguration unter `/etc/odoo`.
- Damit die Images austauschbar sind, wird jedes Image in den Compose-Files über eine Variable mit dem Produktiv-Image als Default gesetzt (`POSTGRES_IMAGE`, `ODOO_IMAGE`, `BACKUP_IMAGE`). Der Policy-Test prüft, dass die Defaults den Produktiv-Images entsprechen. Auf der VPS bleiben die Variablen ungesetzt.

### 2026-10-06 (Umsetzung, Schritt 2: `ssl-dhparams.pem`)

- Befund: Die versionierte `nginx-conf/ssl-dhparams.pem` ist geschwärzt (`*** redacted ***`), genau wie die Secrets in `docker-compose.yaml` und `odoo.conf`. Die Festlegung „aus `nginx-conf/` übernehmen“ ist damit hinfällig.
- Entscheidung (Rückfrage beantwortet): `ingress/conf.d/ssl-dhparams.pem` wird gitignored. `setup.sh` erzeugt die Datei mit `openssl dhparam 2048`, aber nur, wenn sie fehlt. Eine vorhandene Datei, z. B. die Kopie aus `/opt/nginx/config`, wird nie überschrieben.
- Entscheidung (Rückfrage beantwortet): Die Baseline gilt mit diesem Befund als bekannt. `test-nginx-config.sh` testet auf einer Kopie und setzt dort generierte Test-DH-Parameter (ffdhe2048) ein, wenn die Datei fehlt oder kein gültiges PEM ist.

### 2026-10-06 (nach Abschluss: Websocket-Weiterleitung)

- Befund auf der VPS (curl mit Upgrade-Headern auf `https://tomagency.griffity.de/websocket`): `400 Bad Request`, Fehlerseite von Werkzeug, also von Odoo. nginx reicht `Upgrade`/`Connection` nicht weiter, Live-Updates funktionieren deshalb nicht. Das betrifft die bisherige Produktivkonfiguration (`archive/nginx-conf/`) und die daraus übernommene `ingress/conf.d`.
- Auf der VPS ist `workers` in `odoo.conf` nicht gesetzt (Auskunft des Users), Odoo läuft also im Threaded-Modus. Der Websocket wird damit auf 8069 bedient, Port 8072 ist nicht nötig.
- Entscheidung (Auftrag des Users): `ingress/conf.d` wird korrigiert, die frühere Beobachtung „nicht im Scope“ ist damit erledigt.
  - `odoo.conf`: `map $http_upgrade $connection_upgrade`
  - vhost: `location /websocket` mit `proxy_http_version 1.1`, `Upgrade`, `Connection`, Upstream `odoo-backend` (8069) und Timeouts von 3600 s
- Nachweis: Der Smoke-Test prüft neu den Websocket-Handshake (`101`). Mit der alten Konfiguration ist er rot (`400`, wie auf der VPS), mit der neuen grün (32/32).
