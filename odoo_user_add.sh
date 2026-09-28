#!/bin/bash

# Name des Benutzers und der Gruppe
APP_USER="odoo"
APP_GROUP="odoo"

# Feste IDs (Standardmäßig oft 101 oder 1000, hier 1001 als Beispiel)
# Wichtig für Docker-Mounts!
TARGET_ID=101

echo "Starte Einrichtung für User: $APP_USER..."

# 1. Gruppe erstellen, falls sie noch nicht existiert
if ! getent group "$APP_GROUP" >/dev/null; then
    groupadd -g "$TARGET_ID" "$APP_GROUP"
    echo "Gruppe '$APP_GROUP' mit GID $TARGET_ID erstellt."
else
    echo "Gruppe '$APP_GROUP' existiert bereits."
fi

# 2. System-User erstellen
# -u: Spezifische UID
# -g: Primäre Gruppe
# -s: Shell auf /bin/false setzen (Sicherheitsaspekt: kein Login möglich)
# -m: Home-Verzeichnis erstellen (optional, oft für Configs nötig)
if ! id -u "$APP_USER" >/dev/null 2>&1; then
    useradd -u "$TARGET_ID" -g "$APP_GROUP" \
            -m -s /bin/false \
            -c "Odoo Docker User" "$APP_USER"
    echo "Benutzer '$APP_USER' mit UID $TARGET_ID erstellt."
else
    echo "Benutzer '$APP_USER' existiert bereits."
fi

echo "Fertig. Details zum User:"
id "$APP_USER"