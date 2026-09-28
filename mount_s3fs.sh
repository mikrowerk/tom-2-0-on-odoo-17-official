# --- Konfiguration ---

# Der Name deines Ionos S3 Buckets
BUCKET_NAME="griffity-test"

# Das lokale Verzeichnis (Mount-Punkt)
MOUNT_POINT="/mnt/odoo/external-storage/filestore"

# Die Passwort-Datei, die du in Schritt 1b erstellt hast
# WICHTIG: Verwende den absoluten Pfad!
PASSWD_FILE="$HOME/.passwd-s3fs-ionos"

# Der Ionos S3 Endpoint.
# Dieser MUSS zur Region deines Buckets passen!
# Beispiele:
# Deutschland (Frankfurt): s3-eu-central-1.ionoscloud.com
# USA (Las Vegas):         s3-us-west-1.ionoscloud.com
# UK (London):             s3-eu-south-2.ionoscloud.com
S3_URL="https://s3.eu-central-3.ionoscloud.com"

# --- Skript-Logik ---

echo "Prüfe, ob s3fs installiert ist..."
if ! command -v s3fs &> /dev/null; then
    echo "Fehler: s3fs ist nicht installiert."
    echo "Bitte installiere es mit 'sudo apt install s3fs' oder 'sudo dnf install s3fs'."
    exit 1
fi

echo "Prüfe Mount-Punkt: $MOUNT_POINT"
if [ ! -d "$MOUNT_POINT" ]; then
    echo "Mount-Punkt existiert nicht. Versuche, ihn zu erstellen..."
    sudo mkdir -p "$MOUNT_POINT"
    if [ $? -ne 0 ]; then
        echo "Fehler: Mount-Punkt konnte nicht erstellt werden."
        exit 1
    fi
fi

echo "Prüfe Passwort-Datei: $PASSWD_FILE"
if [ ! -f "$PASSWD_FILE" ]; then
    echo "Fehler: Passwort-Datei '$PASSWD_FILE' nicht gefunden."
    echo "Bitte erstelle sie (siehe Anleitung Schritt 1b)."
    exit 1
fi

echo "Versuche, '$BUCKET_NAME' nach '$MOUNT_POINT' zu mounten..."

# Der Mount-Befehl
# Wir verwenden sudo, da wir nach /mnt mounten
sudo s3fs "$BUCKET_NAME" "$MOUNT_POINT" \
    -o passwd_file="$PASSWD_FILE" \
    -o url="$S3_URL" \
    -o use_path_request_style \
    -o allow_other \
    -o nonempty \
    -o uid=101,gid=101 # Optional: Setzt Besitzer auf den ausführenden User

# Überprüfung
if mountpoint -q "$MOUNT_POINT"; then
    echo "✅ Erfolgreich gemountet!"
    echo "Inhalt von $MOUNT_POINT:"
    ls -l "$MOUNT_POINT" | head -n 5 # Zeige die ersten 5 Einträge
else
    echo "❌ Fehler beim Mounten. Bitte überprüfe deine Einstellungen und die System-Logs (z.B. 'journalctl -xe')."
    exit 1
fi