# Spec: Versioniertes Filestore-Backup

> Entwurf, angelegt am 2026-10-06 als Folge von `modular-docker-compose.md` (Folgefrage F5). Muss noch ausgearbeitet werden.

## Background
`tom-backup-image` (`backup.sh`) sichert die Datenbank als Dumps mit Zeitstempel und Retention. Den Filestore spiegelt es dagegen mit `rclone sync`, davon gibt es nur eine Kopie ohne Versionen. Beschädigt ein fehlgeschlagenes Odoo-Update Dateien im Filestore, überschreibt der nächste Backup-Lauf (alle 2 h) die Kopie im S3. Ein Rollback auf einen konsistenten Stand aus DB-Dump und Filestore ist dann nicht mehr möglich.

Bisherige Abhilfe: Das Backup läuft als eigenes Compose-Projekt und wird vor einem Update manuell gestoppt. Das funktioniert nur, wenn jemand vor dem Update daran denkt.

## Goals (Entwurf)
- Ein Filestore-Stand muss sich mindestens für die Dauer von `BACKUP_RETENTION` zu jedem DB-Dump wiederherstellen lassen.
- Mögliche Wege, noch zu bewerten:
  - `rclone sync --backup-dir <remote>/filestore_versions/<zeitstempel>` im Backup-Image, mit eigener Retention.
  - Objekt-Versionierung und Lifecycle-Regeln im S3-Bucket (IONOS/AWS).
- `restore.sh` muss einen bestimmten Zeitpunkt wiederherstellen können.

## Betroffene Repos
- `tom-backup-image` (Branch `feature/build-image-for-odoo-17`)
- ggf. die Bucket-Konfiguration
