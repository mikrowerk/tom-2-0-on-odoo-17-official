# CLAUDE.md

Dieses Repository baut das Docker-Image für **TOM 2.0** (Odoo 17, auf Basis des offiziellen Odoo-Images) und enthält die Laufzeitkonfiguration (Docker Compose, Odoo, nginx) für den Betrieb auf einer Linux-VPS (Host `tomagency.griffity.de`).

Hier wird **kein Odoo-Modulcode entwickelt**. Die Add-ons liegen in Git-Submodulen und werden in deren eigenen Repositories gepflegt. In diesem Repo werden nur die Submodul-Zeiger, das Dockerfile, die Python-Abhängigkeiten und die Deployment-Konfiguration geändert.

## Aufbau

| Pfad | Zweck |
|---|---|
| `Dockerfile` | Mehrstufiger Build: Stufe `gs-build` kompiliert Ghostscript aus den Quellen (für PDF/A-3b, TOM-201), danach Basis `ghcr.io/mikrowerk/odoo-17-official-image-amd-64:<datum>` plus Add-ons und pip-Pakete |
| `additional-requirements.txt` | Zusätzliche Python-Pakete, die als root ins Image installiert werden |
| `docker-compose.yaml` | Aktueller, monolithischer Laufzeit-Stack auf der VPS (wird modularisiert, siehe Zielarchitektur): `postgresql` (bitnami 15), `odoo`, `nginx`, `certbot`, `backup-service` |
| `odoo.conf` | Odoo-Serverkonfiguration; auf der VPS unter `/opt/odoo/conf/odoo.conf` |
| `nginx-conf/` | Alte nginx-Konfiguration (Single-Process-Odoo), enthält `options-ssl-nginx.conf` und `ssl-dhparams.pem` |
| `nginx-conf-new/` | Aktuelle nginx-Konfiguration für den Multi-Worker-Betrieb (Websocket → `odoo:8072`), Login-Rate-Limit und Sperren für Scanner-Pfade. Bindet `options-ssl-nginx.conf` und `ssl-dhparams.pem` aus `conf.d` ein, die beiden Dateien müssen also aus `nginx-conf/` mitkopiert werden |
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

### Deployment auf die VPS (aktueller monolithischer Stack)
1. In `docker-compose.yaml` den Image-Tag von `odoo` auf den Commit-Hash des gebauten Images setzen (`ghcr.io/mikrowerk/tom-2-0-odoo-17-image:<hash>`).
2. Die Dateien auf die VPS kopieren: `odoo.conf` nach `/opt/odoo/conf/`, die nginx-Dateien nach `/opt/nginx/config/`.
3. `docker compose pull && docker compose up -d`. Nach Modul-Updates ein `-u <module>` gegen die Datenbank `tomagency.griffity.de` ausführen.

Die Volumes `postgres_data`, `odoo_data` und `certbot_www` sind `external: true` und müssen auf dem Host schon existieren.

## Wichtige Abhängigkeiten in der Konfiguration

- **Worker-Modus**: `workers = 6`, `max_cron_threads = 2`, `gevent_port = 8072`. Damit das läuft, muss nginx `/websocket` an `odoo:8072` weiterleiten, also `nginx-conf-new/` verwenden.
- **Timeouts**: `limit_time_real` (1200 s) in `odoo.conf` darf nicht größer sein als `proxy_read_timeout` in nginx (1200 s).
- **DB-Verbindungen**: `db_maxconn = 10` mal 9 Prozesse (6 Worker + 2 Cron + 1 gevent) ergibt 90, das muss unter `max_connections` von PostgreSQL (100) bleiben. Wer `workers` erhöht, muss diese Rechnung neu machen.
- `dbfilter = ^%h$` und `db_name` setzen voraus, dass der Datenbankname dem Hostnamen entspricht. `list_db = False`, außerdem blockiert nginx `/web/database`.
- **Python/pip im Image**: Zuerst pip aktualisieren (TOM-195, sonst wird `email_bridge_client` als "UNKNOWN" gebaut), `python3-cairo` kommt aus apt (pycairo hat keine Linux-Wheels). `pyOpenSSL~=22.0.0` und `cryptography~=38.0.0` werden danach absichtlich wieder heruntergepinnt.
- `openupgradelib` wird für die Migrationsskripte der OCA-Module bei `-u` gebraucht.
- `web_dialog_size` bleibt nur so lange im Image, bis das Modul in der Produktion deinstalliert ist (ersetzt durch `mikrowerk_widgets`, TOM-71).

## Zielarchitektur: modulare Compose-Struktur

Die bestehende `docker-compose.yaml` ist ein **Monolith**, in dem alles zusammen läuft: Postgres, Odoo, nginx, certbot und Backup. Das ist der Ausgangszustand. Er soll in eine modulare Struktur auf der VPS aufgeteilt werden, damit mehrere Odoo-Instanzen (Kunden) eine gemeinsame Infrastruktur nutzen können:

```
/docker-services/
├── database/                 # Postgres,  ggf. Backup-Service
│   └── compose.yaml
├── odoo-griffity-prod/
│   ├── compose.yaml
│   ├── .env
│   └── config/odoo.conf
├── odoo-kunde2/
│   └── ...
└── ingress/              # Reverse Proxy (nginx + certbot),
```

Die Detail-Spezifikation folgt noch und wird unter `.features/specs/` abgelegt. Bis dahin gelten diese Leitlinien:
- **`infra/`** stellt die gemeinsamen Dienste bereit: Postgres, nginx/certbot und ggf. Backup. Die Kunden-Stacks hängen sich über ein gemeinsames externes Docker-Netzwerk an und definieren diese Dienste nicht noch einmal.
- **Je Kunde ein eigenes Verzeichnis** mit eigener `compose.yaml`, `.env` und `config/odoo.conf` sowie eigenen Volumes, eigener Datenbank und eigenem DB-User. Ein Kunden-Stack muss sich einzeln starten, stoppen und aktualisieren lassen, ohne die anderen Stacks zu berühren.
- **Keine festen `container_name`** und keine öffentlichen Host-Ports für Odoo. nginx erreicht die Instanzen über das Netzwerk, nur nginx veröffentlicht 80 und 443.
- **Postgres nur per SSH-Tunnel von außen:** Den Port nur an Loopback binden (`127.0.0.1:5432:5432`), **nie** `5432:5432` (das wäre `0.0.0.0`, und Docker umgeht dabei ufw/iptables-Regeln). Zugriff von außen (pgAdmin, DBeaver, psql) erfolgt nur über `ssh -L 5432:127.0.0.1:5432 <user>@<vps>`. Die Odoo-Container verbinden sich weiter über das Docker-Netzwerk (`db_host` = Service-Name), nicht über den Host-Port. Derzeit schützt zwar eine externe Firewall den Postgres-Port, darauf darf sich die Konfiguration aber **nicht** verlassen: Die Compose-Dateien müssen auch ohne Firewall sicher sein (gilt genauso für alle anderen internen Dienste).
- **Ressourcen addieren sich:** Die `db_maxconn`-Rechnung (siehe unten) gilt dann für alle Odoo-Instanzen zusammen gegen ein einziges Postgres. Dasselbe gilt für Worker und RAM.
- Neue Compose-Dateien heißen `compose.yaml`, und es wird `docker compose` (v2) verwendet. Die alte `docker-compose.yaml` bleibt als Referenz liegen, bis die Migration abgeschlossen ist.

## Secrets

- **Keine Secrets in versionierten Dateien.** Passwörter, AWS-Keys, `ODOO_CONFIG_ENCRYPTION_KEY`, `admin_passwd` usw. gehören in **`.env`-Dateien** oder **Passwort-Dateien** (Docker secrets / `*_FILE`-Variablen, z. B. `POSTGRESQL_PASSWORD_FILE`), nicht in `compose.yaml` oder `odoo.conf`.
- `.env` und Passwort-Dateien kommen in `.gitignore`. Ins Repo gehört stattdessen eine `.env.example` mit allen Variablen und leeren oder Dummy-Werten.
- Passwort-Dateien bekommen restriktive Rechte (`chmod 600`, Besitzer root bzw. UID 101).
- In `compose.yaml` werden Werte nur per `${VAR}` bzw. `secrets:` referenziert. Werte, die Odoo aus `odoo.conf` braucht (z. B. `admin_passwd`), werden per Umgebungsvariable/Kommandozeile übergeben oder beim Start aus der Passwort-Datei erzeugt.
- Die bestehenden Dateien `docker-compose.yaml` und `odoo.conf` enthalten nur Platzhalter (`***`). Diese bleiben unverändert, echte Werte werden dort nie eingetragen.

## Projektdokumente: `.features/`

Spezifikationen, Pläne und Dokumentation werden im Repo versioniert:

| Verzeichnis | Inhalt |
|---|---|
| `.features/specs/` | Spezifikationen (Was und Warum), z. B. `.features/specs/modular-compose.md` |
| `.features/plans/` | Umsetzungspläne zu einer Spec (Schritte, betroffene Dateien, Migrationsreihenfolge, Rollback) |
| `.features/docs/` | Betriebs- und Architekturdokumentation, z. B. Setup der VPS, Runbooks, neuen Kunden anlegen |

Ein Plan und seine Spec tragen denselben Dateinamen. Ein Plan wird erst erstellt, wenn die Spec vorliegt, und die Umsetzung erfolgt erst nach einem Plan.
