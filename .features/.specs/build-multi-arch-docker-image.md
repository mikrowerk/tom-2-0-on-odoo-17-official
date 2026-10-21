# Spec Build multi architecture amd64/arm64 image for jobcontrol odoo apps

## Background
In addition to the existing amd64 build we need an image for the arm64 platform so that we have an image for Mac silicon and other arm64 platforms.

## Goals
- have a new github workflow which pulls and retags the most recent stable odoo-17 images, so that they are frozen and available on ghcr.io/mikrowerk/odoo-17-official-image-<arch>:tag
- add to the existing build files like Dockerfile, github-actions the means to have a multiplattform build for amd64 and arm64 keeping the application as in the current dockerfile
- propose reasonable test to check the build images

## Review (2026-10-21)

Abgeglichen mit `Dockerfile`, `.github/workflows/build_publish_image.yml`, `additional-requirements.txt`, CLAUDE.md und
der Vorarbeit auf `feature/tom-231-arm64-base-image` (Commit 57e1332).

### Ist-Stand

- **Basis-Image:** `FROM ghcr.io/mikrowerk/odoo-17-official-image-amd-64:20260908`. Für den Mirror gibt es keinen
  Workflow und kein Skript; er wurde offenbar von Hand erstellt. Er ist inhaltsgleich mit `odoo:17.0-20260908` (amd64).
  Das offizielle Image `odoo:17.0[-YYYYMMDD]` ist eine Manifest-Liste mit `linux/amd64` und `linux/arm64/v8` sowie
  Attestations (`unknown/unknown`).
- **Vorarbeit 57e1332:** `ARG BASE_IMAGE=ghcr.io/mikrowerk/odoo-17-official-image-amd-64:20260908` und
  `FROM ${BASE_IMAGE}`. Damit wurde lokal ein arm64-Image gebaut, mit `--build-arg BASE_IMAGE=docker.io/library/odoo:17.0-20260908`.
  Das Image lief im Molecule-Szenario `gammadata17` (Repo saas_docker_compose_infa) grün: 36 Module, Kontenrahmen, Health, Websocket.
  arm64 funktioniert also **ohne** Änderungen an Add-ons und pip-Paketen. pycairo kommt per apt, für lxml,
  cryptography 38 und rapidfuzz gibt es aarch64-Wheels.
- **Stufe `gs-build`:** `FROM ubuntu:jammy` ist multi-arch, Ghostscript wird pro Plattform aus den Quellen kompiliert.
  Unter QEMU-Emulation auf einem amd64-Runner dauert das für arm64 voraussichtlich ein Vielfaches (Größenordnung 30–60 min).
- **CI:**
  - Ein Job auf `ubuntu-latest`, nur amd64, ohne `setup-qemu`/`setup-buildx`, ohne Build-Cache.
  - Tags: `latest`, `rc-03-2025`, kurzer Commit-Hash.
  - Trigger: Push auf `main`, `releases/**`, `rc/**` (CLAUDE.md nennt zusätzlich `main*`, siehe Commit 3cca396; der Workflow enthält das nicht).
  - `actions/checkout@v2` ist veraltet. `attestations: write`/`id-token: write` sind gesetzt, werden aber nicht genutzt.
  - Es gibt keinen Test-Schritt: Das Image wird gepusht, ohne dass es je gestartet wurde.
- **Arbeitskopie:**
  - Die Spec liegt unter `.features/` und nicht unter `.features/.specs/`.
  - `CLAUDE.md` ist als neue Datei gestaged und beschreibt den Stand von `feature/modular-docker-compose`
    (`deployment/docker-services/`, `archive/`, `.dockerignore`). Auf diesem Branch gibt es diese Dateien nicht.
    Ohne `.dockerignore` geht `.git` mit allen Submodulen in den Build-Kontext.
  - `feature/TOM-232-build-multi-arch-image` steht auf 1904ba9; das ist der Stand von `origin/releases/17-candidate`.

### Lücken und Risiken

- **Benennung:** Der bestehende Mirror heißt `...-amd-64` (mit Bindestrich), die Spec schreibt `...-<arch>`. Docker liefert
  `TARGETARCH` = `amd64`/`arm64`. Für ein `FROM` pro Architektur braucht es also entweder ein einheitliches Schema oder ein Mapping.
- **„Most recent stable“** ist nicht definiert: Tag `17.0` (beweglich) oder neuester datierter Tag `17.0-YYYYMMDD`. Offen ist auch,
  wann der Workflow läuft und ob vorhandene Tags überschrieben werden dürfen. „Frozen“ heißt eigentlich: nie überschreiben.
- **Bumpen des Basisdatums:** Offen ist, ob der Mirror-Workflow das Datum im Dockerfile anpasst (Commit/PR) oder ob das manuell bleibt.
- **Bestehende Funktionalität:**
  - Die Produktion (VPS, amd64) zieht `tom-2-0-odoo-17-image:<hash>`. Wird der Tag zur Manifest-Liste, bleibt das transparent.
  - Kommen dagegen per-Arch-Suffixe dazu oder ändert sich der amd64-Inhalt (neues Basisdatum), betrifft das den Rollout.
  - Der Build darf für amd64 nicht inhaltlich vom heutigen Image abweichen.
- **Laufzeit/Kosten der CI:** QEMU auf einem Runner oder native arm64-Runner (`ubuntu-24.04-arm`) mit getrennten Jobs und Merge
  der Manifeste. Für private Repos sind arm64-Runner kostenpflichtig bzw. planabhängig.
- **Tests:** Die Spec verlangt nur einen Vorschlag. Es fehlen Abbruchkriterium und Ort (CI vor dem Push oder separat).
- **Folgearbeit im Infra-Repo:** Das Molecule-Szenario `gammadata17` baut heute lokal mit `-arm64`-Tag. Es könnte künftig
  aus ghcr ziehen, das ist aber nicht Teil dieses Repos.

## Fragen

1. **Ablage:** Die Spec nach `.features/.specs/build-multi-arch-docker-image.md` verschieben (Konvention der Skills) und den Plan nach `.features/.plans/` legen?
   > Antwort: ja

2. **Branch und Vorarbeit:** Commit 57e1332 per Cherry-pick auf `feature/TOM-232-build-multi-arch-image` übernehmen (Ticket TOM-232)?
   `feature/tom-231-arm64-base-image` würde dann verworfen. Und ist `releases/17-candidate` der Basis-/Ziel-Branch?
   > Antwort: `feature/TOM-232-build-multi-arch-image` ist der Arbeitsbranch, commits von anderen branches per cherry-pick übernehmen, PR gegen `releases/17-candidate` mach ich selbst

3. **CLAUDE.md und `.dockerignore`:** Die gestagte CLAUDE.md beschreibt `feature/modular-docker-compose`. Wie damit umgehen?
   (a) unstagen und aus diesem Feature heraushalten,
   (b) committen und nur den Abschnitt „Image bauen“ ergänzen,
   (c) erst `feature/modular-docker-compose` integrieren.
   Soll eine `.dockerignore` (mindestens `.git`, `.features/`, `.idea/`) Teil dieses Features sein?
   > Antwort: `feature/modular-docker-compose` ist out-of-scope, ich habe die notwendigen Anweisungen in das aktuelle CLAUDE.md kopiert. Ergänzungen die sinnvoll sind für den image-Build Zweck gerne ergänzen.

4. **Mirror-Schema:**
   (a) pro Architektur `ghcr.io/mikrowerk/odoo-17-official-image-amd64:<datum>` und `...-arm64:<datum>`
       (der bestehende `...-amd-64` bleibt unverändert liegen),
   (b) das bestehende `-amd-64` beibehalten und neu `-arm-64`,
   (c) zusätzlich oder stattdessen ein Multi-Arch-Mirror `ghcr.io/mikrowerk/odoo-17-official-image:<datum>` (Manifest-Liste).
       Dann reicht im Dockerfile ein einziges `FROM`, und die Plattform wählt BuildKit.
   Welche Variante? (Empfehlung: c, ggf. zusätzlich a für Einzelzugriffe.)
   > Antwort: Wenn odoo ein multi-Arch Version 17 image hat, dieses in das ghcr.io/mikrowerk repo spiegel und als basis image für den build verwenden

5. **Tag-Format:** Soll das Datum des Mirrors exakt dem Docker-Hub-Tag `17.0-YYYYMMDD` folgen (also `:20260908` wie heute)?
   Zusätzlich auch das Digest des Upstreams in Label/Log festhalten?
   > Antwort: ja

6. **„Most recent stable“:** Ist damit der neueste datierte Tag `17.0-YYYYMMDD` auf Docker Hub gemeint, ermittelt per Hub-API?
   Oder der Tag, auf den `17.0` gerade zeigt? Bei Abweichung zwischen beiden: was gilt?
   > Antwort: der Tag, auf den `17.0` gerade zeigt

7. **Trigger des Mirror-Workflows:**
   - Nur manuell (`workflow_dispatch` mit optionalem Datum), zusätzlich zeitgesteuert (z. B. wöchentlich), oder beides?
   - Existiert der Ziel-Tag schon: überspringen (frozen) oder abbrechen?
   - Überschreiben nie erlauben, auch nicht per Flag?
   > Antwort: alles mit Ja

8. **Kopierverfahren:** Mit `docker buildx imagetools create` kopieren? Das kopiert Manifeste und Layer registry-zu-registry,
   ohne Pull. Die Digests bleiben identisch, und mit Variante 4c bleibt die Manifest-Liste erhalten.
   Alternative ist `docker pull --platform` + `tag` + `push` pro Architektur; das erzeugt neue Digests.
   Attestations des Upstreams mitkopieren oder verwerfen?
   > Antwort: Mit `docker buildx imagetools create`

9. **Basisdatum im Dockerfile:** Bleibt es manuell gepflegt (`ARG BASE_IMAGE`/`ARG BASE_DATE` im Dockerfile)?
   Oder soll der Mirror-Workflow einen PR mit dem neuen Datum öffnen? Beim ersten Multi-Arch-Build bei `20260908` bleiben,
   damit amd64 inhaltsgleich bleibt?
   > Antwort: Beim ersten Multi-Arch-Build bei `20260908` bleiben

10. **Build-Strategie in CI:**
    (a) ein Job mit QEMU + buildx für `linux/amd64,linux/arm64` (einfach, aber langsam wegen Ghostscript-Kompilierung),
    (b) native Runner pro Architektur (`ubuntu-latest` + `ubuntu-24.04-arm`) und danach ein Job, der die Manifeste zusammenführt (schnell).
    Ist das Repo öffentlich oder privat, und sind arm64-Runner im GitHub-Plan verfügbar?
    Soll ein Build-Cache (`type=gha` oder Registry-Cache) genutzt werden?
    > Antwort: b) + Build-Cache

11. **Tags des Anwendungs-Images:**
    - Bleiben `latest`, `rc-03-2025` und der kurze Hash, jeweils als Manifest-Liste für beide Architekturen?
    - Sollen zusätzlich per-Arch-Tags (`<hash>-amd64`, `<hash>-arm64`) entstehen?
    - Soll `rc-03-2025` bei der Gelegenheit ersetzt oder entfernt werden?
    > Antwort: `latest` und der kurze Hash,  `rc-03-2025` entfernen

12. **Trigger des App-Builds:**
    - Bleibt es bei Push auf `main`, `releases/**`, `rc/**`? Soll `main*` (laut CLAUDE.md/Commit 3cca396) ergänzt werden?
    - Soll zusätzlich bei Pull Requests gebaut und getestet werden, ohne Push?
    - Soll `workflow_dispatch` dazukommen, damit Feature-Branches wie dieser vor dem Merge gebaut werden können?
    > Antwort: Push auf `main`, `releases/**`, zusätzlich bei Pull Requests gebaut und getestet werden, ohne Push?

13. **Tests – Umfang.** Vorschlag, pro Architektur:
    - (T1) Manifest-Prüfung: `imagetools inspect` enthält `linux/amd64` und `linux/arm64`.
    - (T2) Smoke-Test im Container:
      - `uname -m` passt zur Plattform,
      - `gs --version` = `10.08.0`,
      - `odoo --version` meldet 17.0,
      - `python3 -c "import factur_x, pypdf, lxml, schwifty, unidecode, rlPyCairo, edi_invoice_parser, google.genai, thefuzz, email_bridge_client, markdown, openupgradelib, cairo"`,
      - `pip3 check`.
    - (T3) Add-on-Inventar: Alle erwarteten Module liegen unter `/mnt/extra-addons` und haben ein `__manifest__.py`.
    - (T4) Install-Test gegen einen Postgres-Service-Container: `odoo -d test -i <modulliste> --stop-after-init --without-demo=all`,
      ohne `ERROR`/Traceback im Log.
    - (T5) Start-Test:
      - Odoo mit `workers: 2` starten,
      - `/web/health` gibt 200,
      - `/websocket` gibt 101 auf 8072.
    Welche davon? (Empfehlung: T1–T3 immer, T4 in CI für beide Architekturen, T5 optional.) Welche Modulliste für T4:
    die 36 Module von gammadata-odoo-17 (Infra-Repo) oder eine eigene, kleinere Liste?
    > Antwort: wie vorgeschlagen ohne T5

14. **Tests – Ort und Abbruch:** Sollen die Tests in CI **vor** dem Push der finalen Tags laufen?
    Ablauf wäre: Build → Push eines temporären Tags bzw. Laden lokal → Tests → Retag. Ein roter Test verhindert dann `latest`/`<hash>`.
    Sollen die Tests zusätzlich als Skript im Repo liegen (z. B. `tests/image/smoke.sh`), damit sie lokal auf dem Mac (arm64) laufen?
    > Antwort: ja, für alle Fragen

15. **Actions-Pflege:**
    - Bei der Gelegenheit `actions/checkout@v2` auf eine aktuelle Version heben?
    - `docker/setup-qemu-action`/`setup-buildx-action` und `metadata-action` ergänzen?
    - Wie bisher auf Commit-SHAs pinnen?
    - Build-Provenance-Attestation (`actions/attest-build-provenance`) aktivieren, da die Rechte schon gesetzt sind, oder die Rechte entfernen?
    > Antwort: alles ja

16. **Token und Paket-Rechte:**
    - Soll der Mirror-Workflow wie der App-Build `secrets.GIT_HUB_TOKEN` nutzen oder `GITHUB_TOKEN` mit `packages: write`?
    - Neue ghcr-Pakete (z. B. `odoo-17-official-image` / `-arm64`) müssen mit dem Repo verknüpft werden und brauchen die passende
      Sichtbarkeit (privat wie der bestehende Mirror?). Legst du das in der Org an, oder soll der Workflow sie beim ersten Push erzeugen?
    > Antwort: Mirror-Workflow wie der App-Build `secrets.GIT_HUB_TOKEN` nutzen, der Workflow die Sichtbarkeit beim ersten Push erzeugen?

17. **Nicht im Scope (zur Bestätigung):**
    - Keine Änderung an Add-ons, pip-Paketen oder Ghostscript-Version.
    - Kein Rollout auf der VPS.
    - Keine Änderung im Infra-Repo: Das Umstellen des Molecule-Szenarios `gammadata17` auf das ghcr-arm64-Image kommt als eigener Schritt später.
    - Keine weiteren Architekturen (z. B. `arm/v7`).
    Korrekt?
    > Antwort: OK

18. **Doku:** CLAUDE.md, Abschnitt „Image bauen“, aktualisieren:
    - lokaler Build auf Apple Silicon ohne `--platform`,
    - Multi-Arch-Tags,
    - Mirror-Workflow.
    Zusätzlich ein kurzes Runbook „Basis-Image aktualisieren“ unter `.features/.docs/`?
    > Antwort: OK

## Entscheidungen (2026-10-21)

Aus den Antworten auf die Fragen 1–18:

1. **Ablage:** Die Spec liegt unter `.features/.specs/build-multi-arch-docker-image.md`, der Plan unter
   `.features/.plans/build-multi-arch-docker-image.md`.
2. **Branch:** Arbeitsbranch ist `feature/TOM-232-build-multi-arch-image`, Ticket TOM-232. Commits von anderen Branches
   werden per Cherry-pick übernommen, zuerst 57e1332 (`ARG BASE_IMAGE`). Den PR gegen `releases/17-candidate` stellt der User selbst.
3. **CLAUDE.md:** `feature/modular-docker-compose` ist out of scope. Die aktuelle CLAUDE.md ist maßgeblich und wird
   für den Image-Build-Zweck ergänzt. Eine `.dockerignore` ist eine sinnvolle Ergänzung für den Build und gehört deshalb in den Scope.
4. **Basis-Image:** Das offizielle Multi-Arch-Image `odoo:17.0-<datum>` (linux/amd64 + linux/arm64) wird als Manifest-Liste nach
   `ghcr.io/mikrowerk/odoo-17-official-image:<datum>` gespiegelt und ist Basis des Builds. Der Name stammt aus Variante 4c.
   Der bestehende `...-amd-64`-Mirror bleibt unverändert liegen.
5. **Tag und Digest:** Das Tag-Format folgt dem Docker-Hub-Tag: `17.0-YYYYMMDD` → `:YYYYMMDD`, z. B. `:20260908`.
   Das Upstream-Digest wird im Workflow-Log und in der Step-Summary festgehalten.
6. **„Most recent stable“** ist der datierte Tag, auf den `17.0` gerade zeigt, also derjenige mit gleichem Index-Digest.
7. **Trigger Mirror:** `workflow_dispatch` mit optionalem Datum und zusätzlich zeitgesteuert (wöchentlich).
   Existiert der Ziel-Tag schon, wird übersprungen. Überschreiben ist nie erlaubt, auch nicht per Flag.
8. **Kopie:** per `docker buildx imagetools create`, registry-zu-registry. Die Manifest-Liste bleibt erhalten, die Digests sind identisch.
9. **Basisdatum:** wird im Dockerfile manuell gepflegt. Der erste Multi-Arch-Build bleibt bei `20260908`.
10. **CI-Build:**
    - Native Runner pro Architektur: `ubuntu-latest` (amd64) und `ubuntu-24.04-arm` (arm64).
    - Danach führt ein Job die per Digest gepushten Images zur Manifest-Liste zusammen.
    - Build-Cache aktiv (`type=gha`, Scope pro Architektur).
11. **Tags:** `latest` und der kurze Commit-Hash, jeweils als Manifest-Liste. `rc-03-2025` entfällt. Es gibt keine per-Arch-Tags.
12. **Trigger App-Build:**
    - Push auf `main` und `releases/**`.
    - Pull Requests: bauen und testen, ohne Push.
    - `rc/**` entfällt (nicht mehr genannt).
13. **Tests:** T1–T4 wie vorgeschlagen, ohne T5:
    - T1: Manifest enthält beide Plattformen.
    - T2: Smoke-Test (Architektur, Ghostscript 10.08.0, Odoo 17.0, Python-Imports, `pip3 check`).
    - T3: Add-on-Inventar.
    - T4: Installation gegen Postgres ohne ERROR/Traceback, in CI für beide Architekturen.
14. **Testablauf:**
    - Die Tests laufen in CI vor dem Push der finalen Tags. Ein roter Test verhindert `latest`/`<hash>`.
    - Sie liegen zusätzlich als Skripte im Repo (`tests/image/`) und laufen lokal auf dem Mac (arm64).
15. **Actions:**
    - `actions/checkout` auf aktuelle Version heben.
    - `setup-qemu`/`setup-buildx`/`metadata-action` ergänzen.
    - Alle Actions auf Commit-SHAs pinnen.
    - Build-Provenance-Attestation (`actions/attest-build-provenance`) aktivieren.
16. **Token:**
    - Der Mirror-Workflow nutzt wie der App-Build `secrets.GIT_HUB_TOKEN`.
    - Neue ghcr-Pakete entstehen beim ersten Push durch den Workflow.
17. **Nicht im Scope:**
    - Keine Änderung an Add-ons, pip-Paketen oder Ghostscript-Version.
    - Kein Rollout auf der VPS.
    - Keine Änderung im Infra-Repo (Umstellung des Molecule-Szenarios `gammadata17` später).
    - Keine weiteren Architekturen.
18. **Doku:**
    - CLAUDE.md, Abschnitt „Image bauen“: lokaler Build auf Apple Silicon ohne `--platform`, Multi-Arch-Tags, Mirror-Workflow.
    - Neues Runbook „Basis-Image aktualisieren“ unter `.features/.docs/`.

## Folgefragen (2026-10-21)

F1. **Bootstrap des Mirrors.** GitHub führt `workflow_dispatch` und `schedule` nur für Workflows aus, die auf dem
    **Default-Branch `main`** liegen. Dein PR geht aber gegen `releases/17-candidate`. Solange der Mirror
    `odoo-17-official-image:20260908` nicht existiert, schlägt der App-Build fehl, auch der PR-Build. Möglichkeiten:
    - (a) Die Logik des Mirrors liegt als Skript im Repo (`scripts/mirror-odoo-base.sh`), und der Workflow ruft nur dieses Skript auf.
      Du führst das Skript **einmal lokal** aus, mit einem Token mit `write:packages` und Datum `20260908`, bevor der PR gebaut wird.
      Der Workflow übernimmt erst, wenn er auf `main` liegt.
    - (b) Der Mirror-Workflow bekommt zusätzlich einen `push`-Trigger auf seine eigene Datei bzw. das Skript.
      Dann läuft er beim Push dieses Branches einmal mit dem Default-Datum aus dem Dockerfile.
    - (c) Der Mirror-Workflow geht vorab in einem eigenen kleinen PR nach `main`.
    Welche Variante? (Empfehlung: a, ggf. zusätzlich b. Wie kommen Änderungen sonst von `releases/17-candidate` nach `main`?)
    > Antwort:

F2. **Sichtbarkeit neuer Pakete.** Ein Workflow kann die Sichtbarkeit eines ghcr-Pakets nicht setzen; dafür gibt es keine API.
    Beim ersten Push entsteht das Paket mit der Standard-Sichtbarkeit der Org (in der Regel privat).
    Mit der Annotation `org.opencontainers.image.source` wird es mit dem Repo verknüpft.
    Ok, dass du Sichtbarkeit und Repo-Zugriff von `odoo-17-official-image` nach dem ersten Push einmal im UI prüfst
    (als Schritt im Runbook)?
    > Antwort:

F3. **Modulliste für T4.** Vorschlag: `tests/image/modules.txt` in diesem Repo mit den 36 Modulen von gammadata-odoo-17
    (inkl. `l10n_de`), Stand services.yml im Infra-Repo. Gepflegt wird die Liste hier. Ok, oder eine andere Liste
    (z. B. alle Module unter `/mnt/extra-addons` mit `installable: True`)?
    > Antwort:

## Entscheidungen zu den Folgefragen (2026-10-21)

- **F1 (Variante a):**
  - Die Mirror-Logik liegt als Skript `scripts/mirror-odoo-base.sh` im Repo, und der Workflow ruft nur dieses Skript auf.
  - Der User führt das Skript einmal lokal aus (Token mit `write:packages`, Datum `20260908`), bevor der PR gebaut wird.
  - Ab dem Merge nach `main` übernimmt der Workflow.
- **F2:** Der Workflow setzt die Annotation `org.opencontainers.image.source`. Sichtbarkeit und Repo-Zugriff des Pakets prüft
  der User nach dem ersten Push einmal im UI; das steht als Schritt im Runbook.
- **F3:** Die Modulliste für T4 liegt in `tests/image/modules.txt`: 36 Module von gammadata-odoo-17 inkl. `l10n_de`,
  gepflegt in diesem Repo.

## Folgefrage (2026-10-21)

F4. **Der Paketname `ghcr.io/mikrowerk/odoo-17-official-image` ist schon belegt.** Lokal liegen davon drei Tags, die
    nicht aus dieser Session stammen:
    - `:latest` und `:97037c3`: amd64, erstellt am 2025-07-21. Labels `ubuntu`/`22.04`, also kein offizielles Odoo-Image.
      Vermutlich ein älterer eigener Build.
    - `:20260908`: lokal arm64, inhaltsgleich mit `odoo:17.0-20260908`. Die RepoDigest
      `ghcr.io/mikrowerk/odoo-17-official-image@sha256:aa16942e…` zeigt, dass der Tag gepusht wurde.
      Das Upstream-Index-Digest ist aber `sha256:8779f815…`.
      Möglicherweise liegt auf ghcr also nur die arm64-Variante als Einzel-Image und keine Manifest-Liste.
      Wegen „nie überschreiben“ (Entscheidung 7) würde der Mirror diesen Tag überspringen. Der amd64-Build stünde dann auf einem arm64-Basis-Image.
    Ich kann ghcr ohne Login nicht prüfen. Bitte einmal ausführen:
    `! docker login ghcr.io` und danach
    `! docker buildx imagetools inspect ghcr.io/mikrowerk/odoo-17-official-image:20260908`
    Wie weiter?
    - (a) Neuer, unbelegter Name für den Mirror, z. B. `ghcr.io/mikrowerk/odoo-17-official-multiarch:<datum>`.
      Am bestehenden Paket ändert sich nichts.
    - (b) Das bestehende Paket nutzen. Ist `:20260908` dort kein Multi-Arch-Index mit Digest `8779f815…`, löschst du den Tag
      einmal von Hand im UI, und der Mirror legt ihn neu an.
    - (c) Das bestehende Paket nutzen und als einzige Ausnahme vom Überschreibverbot erlauben, ein Einzel-Image durch den
      Upstream-Index zu ersetzen.
    (Empfehlung: a, weil es nichts Bestehendes berührt. `latest`/`97037c3` werden evtl. noch irgendwo referenziert.)
    > Antwort:

## Entscheidung zu F4 (2026-10-21)

- **Variante a:** Der Mirror heißt `ghcr.io/mikrowerk/odoo-17-official-multiarch:<datum>`. Das ersetzt den Namen aus Entscheidung 4.
  Das bestehende Paket `odoo-17-official-image` (`latest`, `97037c3`, `20260908`) bleibt unberührt, ebenso `...-amd-64`.
- Keine Fragen mehr offen.
