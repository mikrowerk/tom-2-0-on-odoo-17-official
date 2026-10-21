# Plan: Multi-Arch-Image (amd64/arm64) für TOM 2.0

- **Spec:** [build-multi-arch-docker-image.md](../.specs/build-multi-arch-docker-image.md) (maßgeblich, inkl. „Entscheidungen“)
- **Ticket:** TOM-232
- **Branch:** `feature/TOM-232-build-multi-arch-image`. Commits von anderen Branches werden per Cherry-pick übernommen.
  Den PR gegen `releases/17-candidate` stellt der User selbst. Kein Push und kein PR durch Claude.
- **Commit-Messages:** `TOM-232: <beschreibung>`. Ein Schritt = ein Commit.

## Rahmen

- **Mirror:** `ghcr.io/mikrowerk/odoo-17-official-multiarch:<YYYYMMDD>` ist eine 1:1-Kopie der Manifest-Liste
  `docker.io/library/odoo:17.0-<YYYYMMDD>` per `docker buildx imagetools create`. Bestehende Tags werden nie überschrieben.
- **Basis des Builds:** `ARG BASE_IMAGE=ghcr.io/mikrowerk/odoo-17-official-multiarch:20260908`. Das Upstream-Index-Digest
  `sha256:8779f8157ddcc37b84014c94646073f46fd4ad776b7a5d95fc3b0dc73a24a8fa` ist inhaltsgleich mit dem heutigen `-amd-64`-Mirror für amd64.
- **App-Image:** `ghcr.io/mikrowerk/tom-2-0-odoo-17-image`, Tags `latest` + kurzer Hash (7 Zeichen wie bisher), als Manifest-Liste.
- **Tests** liegen in `tests/image/`, laufen lokal (arm64, Mac) und in CI (je Architektur nativ):

  | Test | Inhalt | Skript |
  |---|---|---|
  | T1 | Manifest enthält `linux/amd64` + `linux/arm64` | `manifest.sh` |
  | T2 | Architektur, `gs --version` = 10.08.0, Odoo 17.0, Python-Imports, `pip3 check` | `smoke.sh` |
  | T3 | Add-on-Inventar gegen `expected-addons.txt` | `addons.sh` |
  | T4 | `odoo -i <modules.txt> --stop-after-init --without-demo=all` gegen einen frischen Postgres-Container, kein ERROR/Traceback | `install.sh` |

- **Lint:** `shellcheck` (vorhanden). `actionlint` und `hadolint` werden lokal per `brew install` ergänzt; falls nicht
  möglich, per `docker run rhysd/actionlint` bzw. `hadolint/hadolint`.
- **Lokale Einschränkung:** Docker Desktop kann amd64 nicht ausführen („exec format error“). Lokal werden deshalb nur
  arm64-Images gebaut und getestet. amd64 wird in CI geprüft, im PR-Build.

## Baseline

**2026-10-21:**
- **Image:** Stand 3a65c85, lokal für arm64 gebaut:
  `docker build --build-arg BASE_IMAGE=docker.io/library/odoo:17.0-20260908 -t tom-2-0-odoo-17-image:baseline-arm64 .`
  Der Build war vollständig aus dem Cache des gleichen Stands vom 2026-10-20.
- **Ergebnisse:**

  | Test | Ergebnis |
  |---|---|
  | T2 `smoke.sh` | aarch64, gs 10.08.0, `Odoo Server 17.0-20260908`, alle 18 Python-Importe ok; **`pip3 check` rot** |
  | T3 `addons.sh` | 148 Add-ons wie erwartet (Liste aus dem Image, identisch mit den `COPY`-Zeilen/Submodulen) |
  | T4 `install.sh` | 36/36 Module installiert, Exit 0, kein ERROR/CRITICAL/Traceback, 81 WARNING-Zeilen, 1:24 min |
  | T1 `manifest.sh` | gegen `odoo:17.0-20260908` grün (beide Plattformen) |

- **Ursache `pip3 check`:** Das Ubuntu-Paket `python3-pdfminer` (20220319+dfsg-1) im offiziellen Basis-Image hat
  kaputte Metadaten: Version `-VERSION-`, Verzeichnis `pdfminer.six-_VERSION_.egg-info`. pip 26 bricht daran ab.
  Das offizielle Image selbst ist in `pip3 check` ebenfalls rot (zeep → platformdirs; im TOM-Image durch
  additional-requirements behoben). Entscheidung des Users: die Ursache im Dockerfile beheben (neuer Schritt 1a).
- **Negativtests, alle rot wie erwartet:**
  - `document_url` aus der erwarteten Liste entfernt → T3 rot.
  - `EXPECTED_GS_VERSION=10.07.0` → T2 rot. `EXPECTED_ARCH=amd64` auf dem arm64-Image → T2 rot.
  - Unbekanntes Modul in einer Kopie der Modulliste → T4 rot (36/37). Odoo selbst endet hier mit Exit 0 und nur einer WARNING;
    der Zähler fängt das ab.
  - T1 gegen ein Einzel-Plattform-Manifest → rot.
- **Lint:** `shellcheck -x tests/image/*.sh` sauber. Nach den Läufen sind keine Test-Container oder -Netze übrig.

## Schritte

- [x] **0. Vorbereitung**
  - Cherry-pick 57e1332 (`ARG BASE_IMAGE`) von `feature/tom-231-arm64-base-image`.
  - Spec, Plan und die vom User gepflegte `CLAUDE.md` committen.
  - `git status` danach sauber.
  - Dateien: `Dockerfile`, `.features/.specs/build-multi-arch-docker-image.md`, `.features/.plans/build-multi-arch-docker-image.md`, `CLAUDE.md`.
  - Prüfung: `docker buildx build --check .` ohne Warnungen zu `BASE_IMAGE`; `git log` zeigt den Cherry-pick.
  - Commits: Cherry-pick mit Originalnachricht + `TOM-232: add spec and plan for multi-arch image`.
  - **Abweichung:**
    - Reihenfolge getauscht: zuerst der Spec/Plan-Commit (7ebfabe), dann der Cherry-pick (3a65c85).
      Die gestagte `CLAUDE.md` hat den Cherry-pick blockiert.
    - `docker buildx build --check .` braucht ein Login für den ghcr-Mirror. Geprüft wurde deshalb mit
      `--build-arg BASE_IMAGE=docker.io/library/odoo:17.0-20260908`: keine Warnungen.
    - Die Checkbox wurde mit dem Commit von Schritt 1 gesetzt.

- [x] **1. Regressions-Tests gegen den heutigen Stand (vor allen Änderungen)**
  - `tests/image/` anlegen:
    - Skripte: `lib.sh` (gemeinsame Funktionen: Image/Plattform-Parameter, Logprüfung), `smoke.sh` (T2), `addons.sh` (T3),
      `install.sh` (T4), `manifest.sh` (T1), `run.sh` (T2–T4 nacheinander, Abbruch beim ersten Fehler).
    - Listen: `modules.txt` (36 Module gammadata-odoo-17), `expected-addons.txt`.
  - `expected-addons.txt` wird einmalig aus dem heutigen Image erzeugt (`ls /mnt/extra-addons/*/__manifest__.py`) und
    gegen die `COPY`-Zeilen im `Dockerfile` gegengelesen.
  - `install.sh` startet einen eigenen Postgres-Container (`postgres:15`) in einem eigenen Docker-Netz mit eindeutigem
    Namen und räumt ihn per `trap` wieder ab. Gleiches Skript lokal und in CI.
  - Prüfung = **Baseline:**
    - Den heutigen Stand lokal für arm64 bauen
      (`--build-arg BASE_IMAGE=docker.io/library/odoo:17.0-20260908`, Tag `tom-2-0-odoo-17-image:baseline-arm64`).
    - `tests/image/run.sh` grün.
    - Zusätzlich T3 gegen das CI-Image `ghcr.io/mikrowerk/tom-2-0-odoo-17-image:1904ba9` (amd64), nur per Dateisystem-Export
      (`docker create` + `docker export`, kein Start). Ergebnis: Add-on-Listen von amd64 und arm64 identisch.
    - Negativtests:
      - Fehlendes Add-on in `expected-addons.txt` → T3 rot.
      - Falsche erwartete GS-Version → T2 rot.
      - Ungültiges Modul in einer Kopie der Modulliste → T4 rot.
    - `shellcheck tests/image/*.sh` sauber.
  - Ergebnis unter „## Baseline“ mit Datum eintragen.
  - Commit: `TOM-232: add image tests (smoke, addons, install, manifest)`.
  - **Abweichung:**
    - Den T3-Vergleich mit dem amd64-CI-Image 1904ba9 per Export habe ich nicht gemacht: lokal gibt es kein ghcr-Login,
      und das Token von 2026-10-20 ist aufgeräumt.
      Gleichwertig ist T3 in CI auf dem amd64-Runner gegen dieselbe `expected-addons.txt`.
      Zusätzlich wurde die Liste aus `COPY`-Zeilen und Submodulen gegengeprüft: 148 = 148.
    - `expected-addons.txt` hat 148 Einträge, kein `lib.sh`-Executable-Bit (wird nur gesourct).

- [x] **1a. Metadaten von `python3-pdfminer` reparieren** (neu, Entscheidung 2026-10-21, siehe Baseline)
  - Im Dockerfile, als root nach dem pip-Upgrade:
    - Gibt es `pdfminer.six-_VERSION_.egg-info`, wird die Version aus `dpkg-query` (ohne `+dfsg…`) in `PKG-INFO` eingetragen
      und das Verzeichnis umbenannt.
    - Fehlt das Verzeichnis (spätere Basis-Images), passiert nichts.
    - Der Code des Pakets bleibt unverändert.
  - Dateien: `Dockerfile`.
  - Prüfung:
    - arm64-Neubau → `tests/image/run.sh` vollständig grün (`pip3 check`: „No broken requirements found.“).
    - `pip3 show pdfminer.six` meldet 20220319. Add-on-Liste unverändert.
  - Commit: `TOM-232: repair python3-pdfminer metadata so that pip check passes`.
  - **Ergebnis (2026-10-21):**
    - `buildx --check` ohne Warnungen.
    - arm64-Build `tom-2-0-odoo-17-image:tom232-arm64`: `run.sh` vollständig grün.
      `pip3 check` meldet „No broken requirements found“, `pip3 show pdfminer.six` meldet 20220319.
    - 148 Add-ons, 36/36 Module installiert.

- [ ] **2. `.dockerignore`**
  - Hält `.git`, `.idea/`, `.features/`, `.claude/`, `**/.env`, `tests/` sowie die Laufzeitkonfiguration
    (`nginx-conf*/`, `docker-compose.yaml`, `odoo.conf`, `*.sh` im Root) aus dem Build-Kontext.
    Die Submodule bleiben drin, ihr eigenes `.git` (Datei) fällt per `**/.git` weg.
  - Dateien: `.dockerignore`.
  - Prüfung:
    - Größe des Build-Kontexts vorher/nachher protokollieren.
    - Neubau arm64 → `run.sh` grün, `expected-addons.txt` unverändert. Das Image enthält keine `.git`-Einträge
      unter `/mnt/extra-addons` (in T3 aufnehmen).
  - Commit: `TOM-232: add .dockerignore for a lean build context`.

- [ ] **3. Mirror-Skript**
  - `scripts/mirror-odoo-base.sh [--date YYYYMMDD] [--dry-run]`:
    1. Ohne `--date`: Index-Digest von `odoo:17.0` lesen (`imagetools inspect --format '{{json .Manifest}}'`). Dann über die
       Docker-Hub-API (`/v2/namespaces/library/repositories/odoo/tags?name=17.0-`) den datierten Tag `17.0-YYYYMMDD`
       mit demselben Digest suchen. Gibt es keinen: Abbruch mit klarer Meldung.
    2. Mit `--date`: Format prüfen (`^[0-9]{8}$`), Upstream-Tag muss existieren.
    3. Ziel `ghcr.io/mikrowerk/odoo-17-official-multiarch:<datum>` existiert schon → Meldung „übersprungen“ mit beiden Digests, Exit 0.
       Ein Flag zum Überschreiben gibt es nicht.
    4. Sonst `docker buildx imagetools create --tag <ziel> --annotation "index:org.opencontainers.image.source=https://github.com/mikrowerk/<repo>" docker.io/library/odoo:17.0-<datum>`.
       Danach wird geprüft, dass das Ziel beide Plattformen hat und die Plattform-Manifest-Digests mit dem Upstream übereinstimmen.
       Das Index-Digest weicht durch die Annotation ab; das wird geloggt.
    5. Ausgabe von Upstream-Tag, Index-Digest und Plattform-Digests. Ist `GITHUB_STEP_SUMMARY` gesetzt, auch dorthin.
  - Dateien: `scripts/mirror-odoo-base.sh`.
  - Prüfung lokal ohne Push:
    - `--dry-run` ohne Datum ermittelt den Tag zu `17.0` und zeigt Digests sowie den geplanten Befehl.
    - `--dry-run --date 20260908` zeigt Digest `8779f815…`.
    - Ungültiges Datum (`2026-09-08`, `20991231`) → Exit ≠ 0.
    - Prüfung „Ziel existiert“ gegen einen lokalen Test-Registry-Container (`registry:2` auf localhost mit Ziel-Override per
      Umgebungsvariable `MIRROR_TARGET_REPO`): Der erste Lauf kopiert, der zweite meldet „übersprungen“.
      Danach Registry-Container und Volume entfernen.
    - `shellcheck` sauber.
  - Commit: `TOM-232: add script to mirror the official odoo 17 multi-arch image`.

- [ ] **4. Mirror-Workflow**
  - `.github/workflows/mirror_odoo_base_image.yml`:
    - Trigger: `workflow_dispatch` (Input `date`, optional) und `schedule` (wöchentlich, z. B. Montag 04:00 UTC).
    - Ein Job auf `ubuntu-latest`: checkout, `setup-buildx`, Login ghcr mit `secrets.GIT_HUB_TOKEN`,
      dann `scripts/mirror-odoo-base.sh [--date]`.
    - `permissions: contents: read, packages: write`.
    - Alle Actions auf aktuelle Commit-SHAs gepinnt, mit Versionskommentar.
  - Dateien: `.github/workflows/mirror_odoo_base_image.yml`.
  - Prüfung:
    - `actionlint` sauber.
    - Die SHAs werden per `git ls-remote` gegen die Release-Tags der Actions verifiziert.
  - Hinweis: Der Workflow läuft erst, wenn er auf `main` liegt (Entscheidung F1).
  - Commit: `TOM-232: add workflow to mirror the odoo base image`.

- [ ] **5. Bootstrap des Mirrors (User-Aktion)**
  - Der User führt einmal lokal aus: `docker login ghcr.io` (Token mit `write:packages`), dann `scripts/mirror-odoo-base.sh --date 20260908`.
  - Danach prüft der User im UI Sichtbarkeit und Repo-Zugriff von `odoo-17-official-multiarch` (Entscheidung F2).
  - Prüfung durch Claude, nach dem Login: `imagetools inspect ghcr.io/mikrowerk/odoo-17-official-multiarch:20260908`
    zeigt `linux/amd64` + `linux/arm64`, und die Plattform-Digests sind gleich wie bei `odoo:17.0-20260908`.
  - Kein Commit, Ergebnis im Plan notieren.
  - Schritt 6 setzt diesen Schritt voraus.

- [ ] **6. Dockerfile auf den Multi-Arch-Mirror umstellen**
  - Standardwert von `ARG BASE_IMAGE` wird `ghcr.io/mikrowerk/odoo-17-official-multiarch:20260908`.
  - Kommentar anpassen (kein `--build-arg` mehr nötig, die Plattform wählt BuildKit).
  - Die Stufe `gs-build` bleibt unverändert (multi-arch, nativ pro Runner).
  - Labels `org.opencontainers.image.base.name` und `org.opencontainers.image.source` setzen.
  - Dateien: `Dockerfile`.
  - Prüfung:
    - `docker buildx build --check .` sauber; `hadolint Dockerfile` ohne neue Befunde gegenüber dem Stand vor dem Schritt.
    - Lokaler Build ohne `--build-arg` und ohne `--platform` auf dem Mac → arm64-Image.
    - `run.sh` grün, Add-on-Liste identisch zur Baseline.
  - Commit: `TOM-232: build on the multi-arch odoo base mirror`.

- [ ] **7. App-Workflow: Multi-Arch-Build mit Tests**
  - `.github/workflows/build_publish_image.yml` neu aufbauen.
  - Trigger: `push` auf `main` und `releases/**` sowie `pull_request`. `rc/**` entfällt.
  - Job `build` (Matrix, Runner `ubuntu-latest`/amd64 und `ubuntu-24.04-arm`/arm64):
    1. Checkout mit Submodulen (`GIT_HUB_TOKEN`), `setup-buildx`, Login ghcr.
    2. Build mit `load: true` und Cache `type=gha,scope=<arch>` (`mode=max`).
    3. Tests: `tests/image/run.sh` (T2–T4) gegen das geladene Image.
    4. Nur bei Push: dasselbe Build-Ergebnis per Digest pushen (`push-by-digest=true`), aus dem Cache, ohne Neubau.
       Digest als Artefakt hochladen.
  - Job `merge` (nur bei Push, `needs: build`):
    1. `metadata-action` mit den Tags `latest` und `type=sha,format=short` (7 Zeichen, wie bisher `prompt/actions-commit-hash`).
    2. `imagetools create` aus beiden Digests.
    3. T1 (`tests/image/manifest.sh`).
    4. `actions/attest-build-provenance` für das Index-Digest (`push-to-registry: true`).
  - `rc-03-2025` und `prompt/actions-commit-hash` entfallen. `actions/checkout` wird auf die aktuelle Version gehoben.
    Alle Actions auf SHAs gepinnt.
  - `permissions` pro Job minimal (`packages: write`, `attestations: write`, `id-token: write` nur im `merge`/`build`-Push-Pfad).
  - Bei `pull_request`: kein Login-Push und kein `merge`. Pull Requests aus Forks haben keine Secrets: Der Checkout der Submodule
    schlägt dort fehl, das wird bewusst hingenommen und im Workflow kommentiert.
  - Dateien: `.github/workflows/build_publish_image.yml`.
  - Prüfung:
    - `actionlint` sauber, SHAs verifiziert.
    - Trockenprüfung der Tag-Logik: `metadata-action`-Konfiguration gegen die bisherige Hash-Länge abgleichen
      (`git rev-parse --short=7 HEAD`).
    - Lokal simuliert: Build arm64 mit `--cache-to/--cache-from type=local`, dann `run.sh`.
    - Der echte CI-Lauf erfolgt erst im PR durch den User; siehe Schritt 9.
  - Commit: `TOM-232: build and test multi-arch image in CI on native runners`.

- [ ] **8. Doku**
  - `CLAUDE.md`, Abschnitt „Image bauen“:
    - Multi-Arch-Tags `latest`/`<hash>`.
    - Lokaler Build auf Apple Silicon ohne `--platform`.
    - Tests mit `tests/image/run.sh`.
    - Mirror-Workflow und Basisdatum.
  - Tabelle „Aufbau“ ergänzen: `tests/image/`, `scripts/`, `.dockerignore`, Mirror-Workflow. Die CI-Zeile korrigieren (Trigger).
  - Neues Runbook `.features/.docs/base-image-update.md`:
    - Mirror manuell oder automatisch.
    - Bootstrap.
    - Sichtbarkeit prüfen.
    - Basisdatum im Dockerfile bumpen und Tests laufen lassen.
    - Rückweg: altes Datum.
    - Nie überschreiben.
  - Dateien: `CLAUDE.md`, `.features/.docs/base-image-update.md`.
  - Prüfung: alle genannten Pfade, Befehle und Workflow-Namen existieren (per `grep`/`ls` gegengeprüft).
  - Commit: `TOM-232: document multi-arch build and base image update`.

- [ ] **9. Abschlussverifikation**
  - Lokal:
    - `shellcheck` (`tests/image/*.sh`, `scripts/*.sh`), `actionlint` (beide Workflows), `hadolint`, `docker buildx build --check .`
    - Frischer arm64-Build ohne Cache → `tests/image/run.sh` grün.
    - Add-on-Liste identisch zur Baseline (Schritt 1).
  - `git status` sauber, alle Commits vorhanden, Checkboxen vollständig.
  - Aufräumen:
    - Lokale Test-Images (`baseline-arm64`, Zwischen-Builds), Test-Registry, Postgres-Container und -Netze sowie Build-Cache
      dieses Features entfernen.
    - Nur, was nachweislich in diesem Feature angelegt wurde.
  - **CI-Abnahme (User, nach dem PR):** PR-Build grün auf beiden Runnern (T2–T4).
    Nach dem Merge auf `releases/17-candidate`: `merge`-Job grün, T1 grün, Tags `latest` und `<hash>` als Manifest-Liste mit
    beiden Plattformen, Attestation vorhanden.
  - Der Mirror-Workflow wird erst nach dem Merge nach `main` per `workflow_dispatch` geprüft (erwartet: „übersprungen“ für `20260908`).

## Offene Punkte / Folgearbeiten (nicht im Scope)

- Infra-Repo `saas_docker_compose_infa`: Molecule-Szenario `gammadata17` auf `ghcr.io/mikrowerk/tom-2-0-odoo-17-image:<hash>` (arm64) umstellen.
- Ob `latest`/`97037c3` im Altpaket `odoo-17-official-image` noch gebraucht werden, klärt der User.
