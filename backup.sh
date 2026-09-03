#!/usr/bin/env bash
# Nightly backup: Postgres dump + workflow JSON export.
#
# Install (as the user that owns this directory, not root):
#   chmod +x ~/n8n/backup.sh
#   crontab -e
#   15 3 * * * /home/ubuntu/n8n/backup.sh >> /home/ubuntu/n8n/backup.log 2>&1
#
# A dump on the same disk is not a backup -- it dies with the instance. Set
# BACKUP_S3 to an s3:// prefix (and give the instance a role that can write
# there) so a copy lands off the box.
set -euo pipefail

cd "$(dirname "$0")"

BACKUP_DIR="${BACKUP_DIR:-./backups}"
KEEP_DAYS="${KEEP_DAYS:-14}"
BACKUP_S3="${BACKUP_S3:-}"
STAMP="$(date +%F-%H%M)"

mkdir -p "$BACKUP_DIR"

# Refuse to run if the disk is nearly full -- a truncated dump that overwrites
# a good one is worse than no dump at all.
USED="$(df --output=pcent . | tail -1 | tr -dc '0-9')"
if [ "$USED" -ge 90 ]; then
  echo "$(date -Is) ABORT: disk ${USED}% full, refusing to write a backup" >&2
  exit 1
fi

DUMP="$BACKUP_DIR/n8n-$STAMP.sql.gz"

# Write to .partial first, rename on success. An interrupted dump then never
# looks like a finished one.
docker compose exec -T postgres \
  pg_dump -U "${POSTGRES_USER:-n8n}" "${POSTGRES_DB:-n8n}" \
  | gzip > "$DUMP.partial"
mv "$DUMP.partial" "$DUMP"

# gzip exits 0 on a truncated stream, so verify before trusting this file.
gzip -t "$DUMP"
echo "$(date -Is) dump ok: $DUMP ($(du -h "$DUMP" | cut -f1))"

# Workflow JSON, so the instance is not the only source of truth. Credentials
# are deliberately not included -- that is what N8N_ENCRYPTION_KEY protects.
docker compose exec -T n8n \
  n8n export:workflow --all --separate --output=/files/workflows >/dev/null
echo "$(date -Is) workflow export ok"

if [ -n "$BACKUP_S3" ]; then
  aws s3 cp "$DUMP" "${BACKUP_S3%/}/$(basename "$DUMP")"
  echo "$(date -Is) uploaded to ${BACKUP_S3%/}"
else
  echo "$(date -Is) WARNING: BACKUP_S3 unset, backup is on the same disk as the data it backs up" >&2
fi

find "$BACKUP_DIR" -name 'n8n-*.sql.gz' -mtime "+$KEEP_DAYS" -delete
