#!/usr/bin/env bash
# Záloha databáze (schéma + data) do komprimovaného souboru.
# Použití: DATABASE_URL="postgresql://postgres:HESLO@db.xxxx.supabase.co:5432/postgres" ./scripts/backup.sh [cilovy_adresar]
# Připojovací řetězec najdete v Supabase: Project Settings → Database → Connection string (URI).
set -euo pipefail
: "${DATABASE_URL:?Nastavte DATABASE_URL}"
OUT_DIR="${1:-backups}"
mkdir -p "$OUT_DIR"
STAMP=$(date +%Y-%m-%d_%H%M)
pg_dump "$DATABASE_URL" --no-owner --no-privileges --schema=public --schema=auth --format=custom \
  --file="$OUT_DIR/ivancice-mapa_$STAMP.dump"
echo "Záloha uložena: $OUT_DIR/ivancice-mapa_$STAMP.dump"
# Obnova (do prázdné databáze): pg_restore --no-owner -d "$DATABASE_URL" soubor.dump
