#!/usr/bin/env bash
set -euo pipefail

# ===== Config =====

# Rilevamento AUTOMATICO Screen
# Nota: Rileva tutti gli screen attivi. Assicurati siano solo server Minecraft!
SCREENS=()
if command -v screen &> /dev/null; then
    # Cattura l'output di screen -ls, filtra le righe con PID e estrae il nome
    raw_screens=$(screen -ls | grep -E '^\s*[0-9]+\.' | awk '{print $1}' || true)
    
    for s in $raw_screens; do
        # Rimuove il PID (es. 12345.hub -> hub)
        clean_name=$(echo "$s" | cut -d. -f2)
        SCREENS+=("$clean_name")
    done
fi

echo "[INFO] Screen rilevati: ${SCREENS[*]}"

# Percorsi Server
BACKUP_SRC="/home/imperium"
# ATTENZIONE: Percorso della cartella ROOT di Velocity
VELOCITY_DIR="${BACKUP_SRC}/velocity"

# Backup SERVER
BACKUP_SERVER_DIR="/home/backup/server"
BACKUP_SERVER_PREFIX="imperium"
BACKUP_DATE_FMT_DASH="+%d-%m-%Y"
BACKUP_RETENTION_DAYS=7

# Backup DATABASE
DB_NAME="impdata"
BACKUP_DB_DIR="/home/backup/database"
BACKUP_DB_PREFIX="impdata"
BACKUP_DATE_FMT_COMPACT="+%d%m%Y"

# Cartella Aggiornamento Mirato
PLUGIN_UPDATE_ROOT="/home/pluginupdate"

# Database Dump Utility
DUMP_BIN="$(command -v mariadb-dump || command -v mysqldump)"
DUMP_OPTS=(
  --defaults-file=/root/.my.cnf
  --single-transaction
  --quick
  --routines
  --triggers
  --events
  --hex-blob
  --no-tablespaces
  --default-character-set=utf8mb4
  --databases "${DB_NAME}"
)

# ====== GOOGLE DRIVE (rclone) ======
GDRIVE_REMOTE="gdrive"
GDRIVE_SERVER_DIR="Backups/server"
GDRIVE_DB_DIR="Backups/database"
# Retention remota (in giorni)
GDRIVE_RETENTION="30d"

RCLONE_OPTS=(--transfers=4 --checkers=8 --checksum --retries=5 --low-level-retries=10 --drive-chunk-size=64M)

# ===== Utility =====
screen_exists() {
  local name="$1"
  screen -list | grep -q "\.${name}[[:space:]]"
}

send_to_screen() {
  local name="$1"
  local cmd="$2"
  if screen_exists "$name"; then
    screen -S "$name" -p 0 -X stuff "$cmd$(printf '\r')"
    echo "[OK] Inviato a $name: $cmd"
  else
    echo "[WARN] Screen $name non trovato, salto '$cmd'"
  fi
}

send_to_all() {
  local cmd="$1"
  if [[ ${#SCREENS[@]} -eq 0 ]]; then return; fi
  
  for s in "${SCREENS[@]}"; do
    send_to_screen "$s" "$cmd"
  done
}

quit_all_screens() {
  local current_screens
  current_screens=$(screen -ls | grep -E '^\s*[0-9]+\.' | awk '{print $1}' || true)
  
  for s in $current_screens; do
      screen -S "$s" -X quit || true
  done
}

check_dependencies() {
  if ! command -v jq &> /dev/null || ! command -v wget &> /dev/null || ! command -v sha256sum &> /dev/null; then
      echo "[WARN] Dipendenze mancanti. Installazione di jq, wget e coreutils..."
      export DEBIAN_FRONTEND=noninteractive
      apt-get update && apt-get install -y jq wget coreutils
  fi
}

# ===== Funzioni Aggiornamento Plugin =====

# 1. Aggiornamento automatico ViaVersion/ViaBackwards (Online)
update_via_plugins_online() {
  echo "[INFO] Inizio controllo aggiornamenti ViaVersion e ViaBackwards (Online)..."
  check_dependencies

  local temp_dir="/tmp/via_updates"
  mkdir -p "$temp_dir"

  # --- FASE 1: Raccolta informazioni Online (TIMEOUT 15s) ---
  local vv_json
  vv_json=$(curl -sSL --max-time 15 "https://hangar.papermc.io/api/v1/projects/ViaVersion/versions?limit=1&channel=Release&platform=PAPER" || echo "")
  if [[ -z "$vv_json" ]]; then echo "[ERROR] API ViaVersion offline."; rm -rf "$temp_dir"; return 1; fi

  local vv_ver
  vv_ver=$(echo "$vv_json" | jq -r '.result[0].name // empty')
  local vv_url
  vv_url=$(echo "$vv_json" | jq -r '.result[0].downloads.PAPER.downloadUrl // empty')

  local vb_json
  vb_json=$(curl -sSL --max-time 15 "https://hangar.papermc.io/api/v1/projects/ViaBackwards/versions?limit=1&channel=Release&platform=PAPER" || echo "")
  if [[ -z "$vb_json" ]]; then echo "[ERROR] API ViaBackwards offline."; rm -rf "$temp_dir"; return 1; fi

  local vb_ver
  vb_ver=$(echo "$vb_json" | jq -r '.result[0].name // empty')
  local vb_url
  vb_url=$(echo "$vb_json" | jq -r '.result[0].downloads.PAPER.downloadUrl // empty')

  if [[ -z "$vv_ver" || -z "$vb_ver" || -z "$vv_url" || -z "$vb_url" ]]; then
    echo "[ERROR] Dati API incompleti."
    rm -rf "$temp_dir"
    return 1
  fi

  if [[ "$vv_ver" != "$vb_ver" ]]; then
    echo "[WARN] MISMATCH! ViaVersion ($vv_ver) != ViaBackwards ($vb_ver). Skip."
    rm -rf "$temp_dir"
    return 0
  fi

  # --- FASE 2: Download e Installazione ---
  local names=("ViaVersion" "ViaBackwards")
  local urls=("$vv_url" "$vb_url")
  local version="$vv_ver"

  for i in 0 1; do
    local proj="${names[$i]}"
    local url="${urls[$i]}"
    local dest_file="$temp_dir/$proj-$version.jar"

    if ! wget -q --timeout=20 -O "$dest_file" "$url"; then
      echo "[ERROR] Download fallito per $proj."
      continue
    fi

    if [[ ! -s "$dest_file" ]]; then echo "[ERROR] File vuoto $proj."; continue; fi

    find "$BACKUP_SRC" -type d -name "plugins" | while read -r plugin_dir; do
      # Esclusioni fisse
      if [[ "$plugin_dir" == *"/velocity/"* || "$plugin_dir" == *"/velocity" ]]; then continue; fi
      if [[ "$plugin_dir" == *"/debug/"* || "$plugin_dir" == *"/debug" ]]; then continue; fi

      local old_files
      old_files=$(find "$plugin_dir" -maxdepth 1 -type f -iname "${proj}*.jar")

      if [[ -n "$old_files" ]]; then
        local current_local_ver
        current_local_ver=$(basename "$old_files" | sed -E 's/.*-([0-9]+\.[0-9]+(\.[0-9]+)*.*)\.jar$/\1/')
        if [[ "$current_local_ver" == "$(basename "$old_files")" ]]; then current_local_ver="unknown"; fi

        if [[ "$current_local_ver" != "$version" ]]; then
           echo "[UPDATE] $proj in $(basename "$(dirname "$plugin_dir")"): $current_local_ver -> $version"
           # shellcheck disable=SC2086
           rm -f $old_files
           cp "$dest_file" "$plugin_dir/"
        fi
      fi
    done
  done
  rm -rf "$temp_dir"
  return 0
}

# 2. Aggiornamento/Installazione Locale MIRATA
update_local_targeted_plugins() {
  echo "[INFO] Controllo aggiornamenti locali mirati in $PLUGIN_UPDATE_ROOT..."

  if [[ ! -d "$PLUGIN_UPDATE_ROOT" ]]; then
    mkdir -p "$PLUGIN_UPDATE_ROOT"
    return 0
  fi

  for server_update_dir in "$PLUGIN_UPDATE_ROOT"/*; do
    if [[ ! -d "$server_update_dir" ]]; then continue; fi

    local server_name
    server_name=$(basename "$server_update_dir")
    
    local dest_plugins_dir
    dest_plugins_dir="${BACKUP_SRC}/${server_name}/plugins"

    if [[ ! -d "$dest_plugins_dir" ]]; then
        echo "[WARN] Trovata cartella aggiornamento '$server_name' ma la destinazione '$dest_plugins_dir' non esiste. Salto."
        continue
    fi

    echo "--- Processando aggiornamenti per: $server_name ---"

    shopt -s nullglob
    local update_jars=("$server_update_dir"/*.jar)
    shopt -u nullglob

    if [[ ${#update_jars[@]} -eq 0 ]]; then
        echo "[INFO] Nessun jar trovato per $server_name."
        continue
    fi

    for new_jar in "${update_jars[@]}"; do
        local filename
        filename=$(basename "$new_jar")
        local base_name
        base_name=$(echo "$filename" | sed -E 's/(-[0-9].*)?\.jar$//')

        echo "[INFO] -> Gestione file: $filename"

        local existing_files
        existing_files=$(find "$dest_plugins_dir" -maxdepth 1 -type f -iname "${base_name}*.jar")

        if [[ -n "$existing_files" ]]; then
            echo "   [UPDATE] Trovata versione vecchia. Rimozione..."
            # shellcheck disable=SC2086
            rm -f $existing_files
            cp "$new_jar" "$dest_plugins_dir/"
            echo "   [OK] Aggiornato."
        else
            echo "   [NEW] Nessuna versione precedente. Installazione nuova..."
            cp "$new_jar" "$dest_plugins_dir/"
            echo "   [OK] Installato."
        fi
    done
    
    echo "[INFO] Pulizia file aggiornamento per $server_name..."
    rm -f "$server_update_dir"/*.jar

  done
  
  return 0
}

# 3. Auto-Update Velocity PROXY (Core)
update_velocity_core_online() {
  echo "[INFO] Controllo aggiornamento Velocity Proxy (Core)..."
  check_dependencies

  if [[ ! -d "$VELOCITY_DIR" ]]; then
      echo "[WARN] Cartella Velocity $VELOCITY_DIR non trovata."
      return 0
  fi

  # API Calls (Timeout 15s)
  local versions_json
  versions_json=$(curl -sSL --max-time 15 "https://api.papermc.io/v2/projects/velocity" || echo "")
  local latest_version
  latest_version=$(echo "$versions_json" | jq -r '.versions[-1] // empty')
  
  if [[ -z "$latest_version" ]]; then echo "[ERROR] API Velocity offline."; return 1; fi

  local builds_json
  builds_json=$(curl -sSL --max-time 15 "https://api.papermc.io/v2/projects/velocity/versions/${latest_version}" || echo "")
  local latest_build
  latest_build=$(echo "$builds_json" | jq -r '.builds[-1] // empty')

  if [[ -z "$latest_build" ]]; then echo "[ERROR] Build non trovata."; return 1; fi

  local download_json
  download_json=$(curl -sSL --max-time 15 "https://api.papermc.io/v2/projects/velocity/versions/${latest_version}/builds/${latest_build}" || echo "")
  local file_name
  file_name=$(echo "$download_json" | jq -r '.downloads.application.name // empty')
  local remote_sha256
  remote_sha256=$(echo "$download_json" | jq -r '.downloads.application.sha256 // empty')

  if [[ -z "$file_name" || -z "$remote_sha256" ]]; then echo "[ERROR] Dettagli download mancanti."; return 1; fi

  local velocity_jar_path="${VELOCITY_DIR}/velocity.jar"

  # Hash Check
  if [[ -f "$velocity_jar_path" ]]; then
      local local_sha256
      local_sha256=$(sha256sum "$velocity_jar_path" | cut -d' ' -f1)
      if [[ "$local_sha256" == "$remote_sha256" ]]; then
          echo "[SKIP] Velocity Core già aggiornato."
          return 0
      fi
      echo "[UPDATE] Velocity Core update disponibile ($latest_version b$latest_build)."
  else
      echo "[NEW] Installazione Velocity Core..."
  fi

  local download_url="https://api.papermc.io/v2/projects/velocity/versions/${latest_version}/builds/${latest_build}/downloads/${file_name}"
  local temp_jar="/tmp/velocity.jar"

  if ! wget -q --timeout=20 -O "$temp_jar" "$download_url"; then
      echo "[ERROR] Download Velocity fallito."; rm -f "$temp_jar"; return 1
  fi

  local temp_sha256
  temp_sha256=$(sha256sum "$temp_jar" | cut -d' ' -f1)
  if [[ "$temp_sha256" != "$remote_sha256" ]]; then
      echo "[FATAL] Hash mismatch Velocity!"; rm -f "$temp_jar"; return 1
  fi

  mv "$temp_jar" "$velocity_jar_path"
  echo "[OK] Velocity Core aggiornato."
  return 0
}

# ===== Backup FILE server =====
perform_server_backup() {
  echo "[INFO] Backup server ${BACKUP_SRC} -> ${BACKUP_SERVER_DIR}"
  mkdir -p "${BACKUP_SERVER_DIR}"
  local today out_file
  today="$(date "${BACKUP_DATE_FMT_DASH}")"
  out_file="${BACKUP_SERVER_DIR}/${BACKUP_SERVER_PREFIX}${today}.tar.gz"
  tar -I pigz -cf "${out_file}" -C /home imperium
  echo "[OK] Creato: ${out_file}"
  find "${BACKUP_SERVER_DIR}" -type f -name "${BACKUP_SERVER_PREFIX}*.tar.gz" -mtime +"${BACKUP_RETENTION_DAYS}" -print -delete || true
  echo "[OK] Pulizia backup server completata"
}

# ===== Backup DATABASE =====
perform_db_backup() {
  echo "[INFO] Backup DB '${DB_NAME}' -> ${BACKUP_DB_DIR}"
  mkdir -p "${BACKUP_DB_DIR}"
  local today out_file tmp_sql
  today="$(date "${BACKUP_DATE_FMT_COMPACT}")"
  out_file="${BACKUP_DB_DIR}/${BACKUP_DB_PREFIX}${today}.sql.gz"
  tmp_sql="$(mktemp "/tmp/${BACKUP_DB_PREFIX}.XXXXXX.sql")"
  echo "[INFO] Dump DB..."
  if ! ${DUMP_BIN} "${DUMP_OPTS[@]}" > "${tmp_sql}"; then
    echo "[ERROR] Dump DB fallito." >&2; rm -f "${tmp_sql}"; exit 1
  fi
  if [[ ! -s "${tmp_sql}" ]]; then
    echo "[ERROR] Dump DB vuoto."; rm -f "${tmp_sql}"; exit 1
  fi
  pigz -c "${tmp_sql}" > "${out_file}"
  rm -f "${tmp_sql}"
  echo "[OK] Creato: ${out_file}"
  find "${BACKUP_DB_DIR}" -type f -name "${BACKUP_DB_PREFIX}*.sql.gz" -mtime +"${BACKUP_RETENTION_DAYS}" -print -delete || true
  echo "[OK] Pulizia backup DB completata"
}

# ===== Upload su Google Drive =====
upload_to_gdrive() {
  # === NUOVO: Pulizia preventiva Drive ===
  echo "[INFO] Pulizia backup remoti Google Drive (> $GDRIVE_RETENTION)..."
  
  # Usiamo '|| echo' per impedire che un errore di cancellazione fermi l'upload dei backup nuovi
  rclone delete --min-age "$GDRIVE_RETENTION" "${GDRIVE_REMOTE}:${GDRIVE_SERVER_DIR}" "${RCLONE_OPTS[@]}" \
    || echo "[WARN] Errore durante pulizia GDrive Server. Procedo comunque."
    
  rclone delete --min-age "$GDRIVE_RETENTION" "${GDRIVE_REMOTE}:${GDRIVE_DB_DIR}" "${RCLONE_OPTS[@]}" \
    || echo "[WARN] Errore durante pulizia GDrive DB. Procedo comunque."
  # =======================================

  echo "[INFO] Upload su Google Drive..."
  rclone copy "${BACKUP_SERVER_DIR}" "${GDRIVE_REMOTE}:${GDRIVE_SERVER_DIR}" "${RCLONE_OPTS[@]}"
  rclone copy "${BACKUP_DB_DIR}"     "${GDRIVE_REMOTE}:${GDRIVE_DB_DIR}"     "${RCLONE_OPTS[@]}"
  echo "[OK] Upload completato."
}

# ===== Sequenze programmate =====
warn_5_min() {
  send_to_all 'broadcast &c&lRIAVVIO MATTUTINO TRA 5 MINUTI.'
}
warn_2_min() {
  send_to_all 'broadcast &c&lRIAVVIO MATTUTINO TRA 2 MINUTI.'
}

maintenance_and_upgrade() {
  if [[ ${#SCREENS[@]} -eq 0 ]]; then
      echo "[WARN] Nessuno screen rilevato! Procedo comunque con backup e update sistema, ma salto stop/kick."
  else
      send_to_all 'whitelist on'
      sleep 1
      send_to_all 'whitelist reload'
      sleep 1
      send_to_all 'kickall'
      sleep 60
      send_to_all 'stop'

      # Attesa dinamica chiusura
      for i in {1..18}; do
        any_left=0
        if screen -ls | grep -q -E '^\s*[0-9]+\.'; then any_left=1; fi
        [[ "$any_left" -eq 0 ]] && break
        sleep 5
      done
      quit_all_screens
  fi

  # === FASE AGGIORNAMENTI (SAFE MODE) ===
  set +e 
  echo "[INFO] Manutenzione plugin (Safe Mode)..."
  sleep 5
  
  update_velocity_core_online
  update_via_plugins_online
  update_local_targeted_plugins

  echo "[INFO] Manutenzione plugin terminata."
  set -e
  # ======================================

  perform_server_backup
  perform_db_backup
  upload_to_gdrive || echo "[WARN] Upload GDrive fallito, ma procedo al reboot."

  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a
  apt-get update
  apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confnew" dist-upgrade
  apt-get -y autoremove --purge
  
  echo "[INFO] Riavvio sistema..."
  reboot
}

# ===== CLI =====
usage() {
  cat <<EOF
Uso: $(basename "$0") <comando>
  warn5      -> broadcast 5 minuti
  warn2      -> broadcast 2 minuti
  maintain   -> Stop -> Update (Targeted & Online) -> Backup -> SysUpdate -> Reboot
EOF
}

cmd="${1:-}"
case "$cmd" in
  warn5) warn_5_min ;;
  warn2) warn_2_min ;;
  maintain) maintenance_and_upgrade ;;
  *) usage; exit 1 ;;
esac