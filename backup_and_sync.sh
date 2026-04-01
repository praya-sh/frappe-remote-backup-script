#!/bin/bash
# ── Config ──────────────────────────────────────────────
SITE_NAME="" 
BENCH_PATH="" #eg: /opt/bench/frappe-bench
BACKUP_DIR="" #eg: /home/<user>/frappe-bench/sites/some.site/private/backups
DEST_USER="" #remote user with write access to destination, eg: remoteuser
DEST_HOST="" #remote host or IP, eg: backup.example.com
DEST_PORT="" #remote SSH port, eg: 22
DEST_PATH="" #remote path where backups should be stored, eg: /home/remoteuser/backups
LOG_FILE="" #eg: /home/<user>/backup_sync.log
BENCH="" #path to bench executable, eg: /opt/bench/frappe-bench/env/bin/bench use. use where bench command to check location

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log() {
  echo -e "$1"
  echo -e "$1" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE"
}

echo "" >> "$LOG_FILE"
log "${BOLD}=================================================${RESET}"
log "${BOLD}   FRAPPE BACKUP SYNC — $(date)${RESET}"
log "${BOLD}=================================================${RESET}"

log "\n${CYAN}[1/4] Running Frappe backup for site: ${SITE_NAME}...${RESET}"
cd "$BENCH_PATH"
$BENCH --site "$SITE_NAME" backup --with-files 2>&1 | tee -a "$LOG_FILE"
if [ "${PIPESTATUS[0]}" -ne 0 ]; then
  log "${RED}[FAILED] bench backup command failed.${RESET}"; exit 1
fi
log "${GREEN}[DONE] Frappe backup completed successfully.${RESET}"

log "\n${CYAN}[2/4] Locating latest backup files...${RESET}"
LATEST_TIMESTAMP=$(ls "$BACKUP_DIR"/*-database.sql.gz 2>/dev/null | sort | tail -1 | xargs basename | sed 's/-database\.sql\.gz//')
if [ -z "$LATEST_TIMESTAMP" ]; then
  log "${RED}[FAILED] No backup files found in $BACKUP_DIR${RESET}"; exit 1
fi
log "  ${BOLD}Timestamp :${RESET} $LATEST_TIMESTAMP"

LATEST_DB="$BACKUP_DIR/${LATEST_TIMESTAMP}-database.sql.gz"
LATEST_PUB="$BACKUP_DIR/${LATEST_TIMESTAMP}-files.tar"
LATEST_PRV="$BACKUP_DIR/${LATEST_TIMESTAMP}-private-files.tar"

if [ ! -f "$LATEST_DB" ]; then
  log "${RED}[FAILED] Database file not found.${RESET}"; exit 1
fi
log "  ${BOLD}Database  :${RESET} $(basename "$LATEST_DB")  ($(du -sh "$LATEST_DB" | cut -f1))"

if [ -f "$LATEST_PUB" ]; then
  log "  ${BOLD}Public    :${RESET} $(basename "$LATEST_PUB")  ($(du -sh "$LATEST_PUB" | cut -f1))"
else
  log "  ${YELLOW}Public    : not found — skipping${RESET}"; LATEST_PUB=""
fi

if [ -f "$LATEST_PRV" ]; then
  log "  ${BOLD}Private   :${RESET} $(basename "$LATEST_PRV")  ($(du -sh "$LATEST_PRV" | cut -f1))"
else
  log "  ${YELLOW}Private   : not found — skipping${RESET}"; LATEST_PRV=""
fi
log "${GREEN}[DONE] Backup files identified.${RESET}"

log "\n${CYAN}[3/4] Transferring to destination ${DEST_USER}@${DEST_HOST}:${DEST_PORT}...${RESET}"
log "      ${YELLOW}Uploading new backup files...${RESET}"

FILES_TO_SEND="$LATEST_DB"
[ -n "$LATEST_PUB" ] && FILES_TO_SEND="$FILES_TO_SEND $LATEST_PUB"
[ -n "$LATEST_PRV" ] && FILES_TO_SEND="$FILES_TO_SEND $LATEST_PRV"

rsync -avz --progress \
  -e "ssh -p $DEST_PORT -i /home/erp/.ssh/id_ed25519" \
  $FILES_TO_SEND \
  "$DEST_USER@$DEST_HOST:$DEST_PATH/" 2>&1 | tee -a "$LOG_FILE"

if [ "${PIPESTATUS[0]}" -eq 0 ]; then
  log "${GREEN}[DONE] Transfer completed successfully.${RESET}"
else
  log "${RED}[FAILED] rsync transfer failed.${RESET}"; exit 1
fi

log "      ${YELLOW}Cleaning up old backups on destination (keeping last 3 sets)...${RESET}"
ssh -p "$DEST_PORT" -i /home/erp/.ssh/id_ed25519 "$DEST_USER@$DEST_HOST" "
  cd $DEST_PATH
  for pattern in '*-database.sql.gz' '*-files.tar' '*-private-files.tar'; do
    count=\$(ls -t \$pattern 2>/dev/null | wc -l)
    if [ \$count -gt 3 ]; then
      ls -t \$pattern 2>/dev/null | tail -n +4 | xargs rm -f
    fi
  done
" 2>&1 | tee -a "$LOG_FILE"
log "${GREEN}[DONE] Destination cleanup complete.${RESET}"

log "\n${CYAN}[4/4] Cleaning up old local backups (keeping latest 3)...${RESET}"
DELETED=0

for f in $(ls -t "$BACKUP_DIR"/*-database.sql.gz 2>/dev/null | tail -n +4); do
  log "  ${YELLOW}Deleting: $(basename "$f")${RESET}"; rm -f "$f" && ((DELETED++))
done

for f in $(ls -t "$BACKUP_DIR"/*-files.tar 2>/dev/null | grep -v private | tail -n +4); do
  log "  ${YELLOW}Deleting: $(basename "$f")${RESET}"; rm -f "$f" && ((DELETED++))
done

for f in $(ls -t "$BACKUP_DIR"/*-private-files.tar 2>/dev/null | tail -n +4); do
  log "  ${YELLOW}Deleting: $(basename "$f")${RESET}"; rm -f "$f" && ((DELETED++))
done

for f in $(ls -t "$BACKUP_DIR"/*-site_config_backup.json 2>/dev/null | tail -n +4); do
  log "  ${YELLOW}Deleting: $(basename "$f")${RESET}"; rm -f "$f" && ((DELETED++))
done

[ $DELETED -eq 0 ] && log "  No old backups to delete." || log "${GREEN}[DONE] Deleted $DELETED old backup file(s).${RESET}"

log "\n${BOLD}=================================================${RESET}"
log "${GREEN}${BOLD}   ALL STEPS COMPLETED SUCCESSFULLY${RESET}"
log "${BOLD}   Finished at: $(date)${RESET}"
log "${BOLD}=================================================${RESET}\n"
