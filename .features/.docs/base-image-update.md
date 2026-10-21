# Runbook: Odoo-Basis-Image aktualisieren

Das TOM-Image baut auf einem **eingefrorenen** Multi-Arch-Mirror des offiziellen Odoo-Images auf (TOM-232):

| | |
|---|---|
| Upstream | `docker.io/library/odoo:17.0-<YYYYMMDD>` (Manifest-Liste linux/amd64 + linux/arm64) |
| Mirror | `ghcr.io/mikrowerk/odoo-17-official-multiarch:<YYYYMMDD>` |
| Verwendet in | `Dockerfile`, `ARG BASE_IMAGE=ghcr.io/mikrowerk/odoo-17-official-multiarch:<YYYYMMDD>` |
| Logik | `scripts/mirror-odoo-base.sh` |
| Workflow | `.github/workflows/mirror_odoo_base_image.yml` (wöchentlich montags 04:00 UTC und manuell) |

Regeln:
- Ein gespiegelter Tag wird **nie überschrieben**, auch nicht per Flag. Existiert er, meldet das Skript `skipped` und endet mit Exit 0.
- Die Plattform-Manifeste des Mirrors sind digest-identisch mit upstream. Das Index-Digest weicht ab, weil der Mirror
  die Annotationen `org.opencontainers.image.source`, `.base.name` und `.base.digest` trägt.
- Das Dockerfile wird **nicht automatisch** umgestellt. Der Mirror stellt nur bereit; ein Wechsel ist immer ein eigener Commit.

## 1. Neues Datum spiegeln

**Automatisch:** Der Workflow spiegelt jede Woche den datierten Tag, auf den `odoo:17.0` gerade zeigt.
Das Ergebnis steht in der Step-Summary des Laufs (Upstream-Tag, Index-Digest, `mirrored` oder `skipped`).

**Manuell in GitHub:** Actions → „Mirror official odoo 17 base image“ → *Run workflow*, optional mit `date` (YYYYMMDD).
`workflow_dispatch` und `schedule` gibt es nur für den Default-Branch `main`.

**Lokal**, z. B. für den Bootstrap, solange der Workflow noch nicht auf `main` liegt:
```bash
docker login ghcr.io                                   # Token mit write:packages
scripts/mirror-odoo-base.sh --dry-run                  # zeigt Tag und Digests, pusht nichts
scripts/mirror-odoo-base.sh --date 20260908            # oder ohne --date: Tag hinter 17.0
docker buildx imagetools inspect ghcr.io/mikrowerk/odoo-17-official-multiarch:20260908
```
Erwartet werden die Plattformen `linux/amd64` und `linux/arm64` sowie zwei Attestations (`unknown/unknown`).
Prüfen geht auch mit `tests/image/manifest.sh ghcr.io/mikrowerk/odoo-17-official-multiarch:<datum>`.

**Erster Push eines neuen Pakets:** Das Paket entsteht mit der Standard-Sichtbarkeit der Org. Sichtbarkeit und Repo-Zugriff
(Package settings → *Manage Actions access*: dieses Repo mit Lesezugriff) einmal im GitHub-UI prüfen.

## 2. Dockerfile auf das neue Datum umstellen

1. Branch `feature/TOM-XXX-...` anlegen und im `Dockerfile` das Datum in `ARG BASE_IMAGE` ändern.
2. Lokal bauen und testen (Apple Silicon → arm64):
   ```bash
   docker build -t tom-2-0-odoo-17-image:base-<datum> .
   tests/image/run.sh tom-2-0-odoo-17-image:base-<datum>
   ```
   `smoke.sh` prüft dabei auch `pip3 check`. Neue Paketkonflikte aus dem Basis-Image fallen hier auf. Die Reparatur der
   `python3-pdfminer`-Metadaten im Dockerfile wird übersprungen, sobald upstream das Paket korrigiert.
3. Commit `TOM-XXX: update odoo base image to <datum>`, PR stellen. Der PR-Build testet amd64 und arm64 auf nativen Runnern.
4. Nach dem Merge auf `main` oder `releases/**` pusht CI `latest` und `<hash>` als Manifest-Liste.
   Rollout wie gewohnt über den Hash-Tag.

## 3. Rückweg

Das alte Datum bleibt im Mirror erhalten, weil Tags nie überschrieben werden. Zurück geht es so: `ARG BASE_IMAGE` auf das
alte Datum setzen, committen, CI baut neu. Alternativ das vorherige App-Image über seinen Hash-Tag ausrollen.

## Fehlerbilder

| Meldung | Ursache / Abhilfe |
|---|---|
| `cannot inspect …: 401/403` | Kein oder falsches Login an ghcr.io. Das Skript bricht bewusst ab und wertet das nicht als „Tag fehlt“ |
| `no dated tag 17.0-YYYYMMDD has the digest of 17.0` | Docker Hub hat `17.0` neu gebaut, der datierte Tag fehlt noch. Später erneut laufen lassen oder `--date` angeben |
| `--date must be YYYYMMDD` / `… does not exist` | Datum falsch oder upstream nicht vorhanden; Tags unter hub.docker.com/_/odoo prüfen |
| App-Build: `failed to resolve source metadata for ghcr.io/mikrowerk/odoo-17-official-multiarch:<datum>` | Das Datum im Dockerfile ist noch nicht gespiegelt (Abschnitt 1) oder der Workflow hat keinen Lesezugriff auf das Paket |
