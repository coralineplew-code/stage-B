#!/bin/bash
############################################
# Raspberry Pi Zero W – Mesh BATMAN-adv (Bookworm)
# Usage: sudo bash setup-mesh-batman.sh [BOARD_ID]
############################################

### --- Sécurité ---
if [ "$EUID" -ne 0 ]; then
  echo "Lancer ce script avec sudo"
  exit 1
fi

if [ -z "$1" ]; then
  echo "Usage: sudo bash setup-mesh-batman.sh [BOARD_ID]"
  exit 1
fi

BOARD_ID="$1"
IP="10.0.0.$BOARD_ID"
ESSID="mesh-test"
CHANNEL_FREQ="2437"   # canal 6

echo "========================================="
echo " Mesh BATMAN-adv Node $BOARD_ID ($IP)"
echo "========================================="

############################################
# Logging & status
############################################
LOGFILE="/var/log/logmaj.txt"

mkdir -p /var/log
touch "$LOGFILE"
chmod 644 "$LOGFILE"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGFILE"
}

step_start() {
  STEP_NAME="$1"
  STEP_ID="$2"
  log "[STEP $STEP_ID] $STEP_NAME : START"
}

step_ok() {
  log "[STEP $STEP_ID] $STEP_NAME : OK"
}

step_fail() {
  log "[STEP $STEP_ID] $STEP_NAME : FAIL"
  log "Arrêt du script (erreur bloquante)"
  exit 1
}

run() {
  "$@" >>"$LOGFILE" 2>&1 || step_fail
}

############################################
# Systemd logging helpers
############################################
log_systemd_status() {
  SERVICE="$1"
  {
    echo "------ systemd status : $SERVICE ------"
    systemctl is-enabled "$SERVICE" 2>&1 || true
    systemctl is-active  "$SERVICE" 2>&1 || true
    systemctl status     "$SERVICE" --no-pager -l 2>&1
    echo "---------------------------------------"
  } >>"$LOGFILE"
}

log "===== DÉMARRAGE INSTALLATION MESH BATMAN-adv ====="
log "BOARD_ID=$BOARD_ID"

############################################
# [1/16] Paquets requis
############################################
echo "[1/16] Installation des dépendances..."
step_start "[1/16] Installation des dépendances..." "1/16"

# if [ -f /etc/apt/apt.conf.d/95proxy ]; then
#     rm /etc/apt/apt.conf.d/95proxy
# fif 95proxy ]; then
#     cp 95proxy /etc/apt/apt.conf.d/
# fi

#date -s "04 JUN 2026 10:00:00"

apt update

apt install -y \
  iw iproute2 netcat-openbsd \
  batctl \
  bridge-utils \
  systemd \
  nmap \
  arp-scan \
  nftables \
  rsyslog \
  chrony \
  jq \
  iputils-ping \
  net-tools \
  sshpass

echo "apt pleinement installé"

# Vérification que batctl est disponible
if ! command -v batctl >/dev/null 2>&1; then
  log "ERREUR : batctl introuvable après installation"
  step_fail
fi

log "batctl disponible : $(batctl -v)"
step_ok
echo "Etape 1 OK."

############################################
# [2/16] Désactivation NetworkManager / WPA
############################################
echo "[2/16] Désactivation services conflictuels..."
step_start "[2/16] Désactivation services conflictuels..." "2/16"

log "[ACTION] Désactivation NetworkManager"
systemctl disable --now NetworkManager >>"$LOGFILE" 2>&1 || true
log_systemd_status NetworkManager

log "[ACTION] Désactivation wpa_supplicant"
systemctl disable --now wpa_supplicant >>"$LOGFILE" 2>&1 || true
log_systemd_status wpa_supplicant

step_ok
echo "Etape 2 OK."

############################################
# [3/16] Activation systemd-networkd
############################################
echo "[3/16] Activation systemd-networkd..."
step_start "[3/16] Activation systemd-networkd..." "3/16"

systemctl enable systemd-networkd >>"$LOGFILE" 2>&1
systemctl start systemd-networkd >>"$LOGFILE" 2>&1
log_systemd_status systemd-networkd

step_ok
echo "Etape 3 OK."

############################################
# [4/16] Synchronisation Date & Heure – Mesh Chrony
############################################
echo "[4/16] Configuration NTP Mesh (chrony)..."
step_start "[4/16] Configuration NTP Mesh (chrony)..." "4/16"

systemctl disable --now systemd-timesyncd >/dev/null 2>&1 || true

if [ "$BOARD_ID" -eq 1 ]; then
  log "NTP Mesh : configuration NOEUD MAÎTRE (10.0.0.1)"

  cat > /etc/chrony/chrony.conf <<EOF
# === Chrony MASTER – Mesh 10.0.0.0/24 ===

# Ce noeud est la référence de temps locale
local stratum 10

# Autoriser les clients du mesh
allow 10.0.0.0/24

# Corriger l'heure brutalement au boot si nécessaire
makestep 1.0 3

# Logs
logdir /var/log/chrony
EOF

else
  log "NTP Mesh : configuration NOEUD CLIENT (sync sur 10.0.0.1)"

  cat > /etc/chrony/chrony.conf <<EOF
# === Chrony CLIENT – Mesh ===

# Serveur NTP unique
server 10.0.0.1 iburst

# Correction rapide si dérive importante
makestep 1.0 3

# Logs
logdir /var/log/chrony
EOF
fi

systemctl enable chrony >>"$LOGFILE" 2>&1
systemctl restart chrony >>"$LOGFILE" 2>&1
log_systemd_status chrony

cat > /usr/local/bin/mesh-ntp-sync.sh <<'EOF'
#!/bin/bash

LOG="/var/log/mesh-ntp.log"
echo "=== Mesh NTP sync $(date) ===" >> "$LOG"

# Attente IP mesh sur bat0
for i in {1..30}; do
  if ip addr show bat0 | grep -q "10.0.0."; then
    break
  fi
  sleep 1
done

# Resynchronisation forcée
chronyc -a makestep >> "$LOG" 2>&1
chronyc tracking >> "$LOG" 2>&1
EOF

chmod +x /usr/local/bin/mesh-ntp-sync.sh

cat > /etc/systemd/system/mesh-ntp-sync.service <<EOF
[Unit]
Description=Mesh NTP Resynchronisation (chrony)
After=mesh-batman.service
Wants=mesh-batman.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/mesh-ntp-sync.sh

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload >>"$LOGFILE" 2>&1
systemctl enable mesh-ntp-sync.service >>"$LOGFILE" 2>&1

step_ok
echo "Etape 4 OK."

############################################
# [5/16] Chargement du module batman-adv
############################################
echo "[5/16] Configuration module batman-adv..."
step_start "[5/16] Configuration module batman-adv..." "5/16"

# Chargement immédiat
if ! modprobe batman-adv >>"$LOGFILE" 2>&1; then
  log "ERREUR : impossible de charger le module batman-adv"
  log "Vérifiez que le module est bien présent : modinfo batman-adv"
  step_fail
fi

# Persistance au boot
echo "batman-adv" > /etc/modules-load.d/batman-adv.conf
log "Module batman-adv chargé et persistant"

# Vérification
if lsmod | grep -q "^batman_adv"; then
  log "Module batman_adv actif : $(lsmod | grep batman_adv)"
else
  log "AVERTISSEMENT : module batman_adv non visible dans lsmod"
fi

# Paramètres kernel pour le routage mesh
cat > /etc/sysctl.d/99-mesh-routing.conf <<EOF
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1

net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0

net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0

net.ipv4.conf.all.accept_source_route=1
net.ipv4.conf.default.accept_source_route=1

# ICMP broadcast pour découverte des voisins
net.ipv4.icmp_echo_ignore_broadcasts=0
EOF

sysctl --system >>"$LOGFILE" 2>&1

step_ok
echo "Etape 5 OK."

############################################
# [6/16] Exclure wlan0 et bat0 de systemd-networkd
############################################
echo "[6/16] Exclusion de wlan0 et bat0 de systemd-networkd..."
step_start "[6/16] Exclusion wlan0/bat0 de systemd-networkd..." "6/16"

rm -f /etc/systemd/network/*wlan0*.network
rm -f /etc/systemd/network/*bat0*.network
rm -f /etc/systemd/network/99-ignore-wlan0.link
rm -f /etc/systemd/network/99-ignore-bat0.link

cat > /etc/systemd/network/99-ignore-wlan0.link <<EOF
[Match]
OriginalName=wlan0

[Link]
Unmanaged=yes
LinkLocalAddressing=no
DHCP=no
IPv6AcceptRA=no
EOF

cat > /etc/systemd/network/99-ignore-bat0.link <<EOF
[Match]
OriginalName=bat0

[Link]
Unmanaged=yes
LinkLocalAddressing=no
DHCP=no
IPv6AcceptRA=no
EOF

log "[ACTION] Restart systemd-networkd"
systemctl restart systemd-networkd >>"$LOGFILE" 2>&1
log_systemd_status systemd-networkd

step_ok
echo "Etape 6 OK."

############################################
# [7/16] Désactivation IPv4 link-local (évite les 169.254.x.x)
############################################
echo "[7/16] Désactivation IPv4 link-local..."
step_start "[7/16] Désactivation IPv4 link-local..." "7/16"

cat > /etc/sysctl.d/99-mesh-no-ipv4ll.conf <<EOF
net.ipv4.conf.all.autoconf=0
net.ipv4.conf.default.autoconf=0
net.ipv4.conf.wlan0.autoconf=0
net.ipv4.conf.all.accept_local=0
net.ipv4.conf.default.accept_local=0
EOF

sysctl --system >>"$LOGFILE" 2>&1

step_ok
echo "Etape 7 OK."

############################################
# [8/16] Script principal BATMAN-adv
############################################
echo "[8/16] Script de configuration BATMAN-adv..."
step_start "[8/16] Script BATMAN-adv..." "8/16"

cat > /usr/local/bin/setup-batman.sh <<'BATSCRIPT'
#!/bin/bash
# setup-batman.sh — mesh BATMAN-adv pour BCM43438 (Pi Zero W)
#
# SÉQUENCE FINALE VALIDÉE :
#   1. rfkill reset
#   2. iw set type ibss
#   3. iw ibss join + attente association stable (10s)
#   4. batctl if add (sur wlan0 DÉJÀ en IBSS stable)
#   5. bat0 up + IP
#
# Le ibss join DOIT être fait AVANT batctl if add, sinon batman-adv
# perd wlan0 quand le driver fait un reset interne lors du join.

LOG="/var/log/mesh-batman-setup.log"
echo "=== Setup BATMAN-adv $(date) ===" >> "$LOG"

BOARD_ID=$(cat /etc/mesh-id 2>/dev/null)
if [ -z "$BOARD_ID" ]; then
  echo "ERREUR : /etc/mesh-id introuvable" >> "$LOG"
  exit 1
fi

IP="10.0.0.$BOARD_ID"
ESSID="mesh-test"
CHANNEL_FREQ="2437"

echo "BOARD_ID=$BOARD_ID  IP=$IP" >> "$LOG"

# ── ETAPE 1 : reset firmware ──────────────────────────────────────────────────
echo "[1/5] Reset firmware BCM43438..." >> "$LOG"

batctl if del wlan0 2>>"$LOG" || true
sleep 1

ip link set wlan0 down 2>>"$LOG" || true
sleep 1

rfkill block wifi 2>>"$LOG"
sleep 2
rfkill unblock wifi 2>>"$LOG"
sleep 3

for i in $(seq 1 10); do
  if ip link show wlan0 >/dev/null 2>&1; then
    echo "    wlan0 OK après ${i}s" >> "$LOG"
    break
  fi
  sleep 1
done

# ── ETAPE 2 : mode IBSS ───────────────────────────────────────────────────────
echo "[2/5] Mode IBSS..." >> "$LOG"

ip link set wlan0 down 2>>"$LOG"
sleep 1

iw dev wlan0 set type ibss 2>>"$LOG"
echo "    RC set type ibss : $?" >> "$LOG"

ip link set wlan0 up 2>>"$LOG"
sleep 1

# Augmenter le MTU pour batman-adv (requis 1532, défaut 1500)
echo "    MTU wlan0 → 1532 (requis batman-adv)..." >> "$LOG"
ip link set wlan0 mtu 1532 2>>"$LOG"
echo "    RC set mtu : $?" >> "$LOG"

sleep 1

# ── ETAPE 3 : ibss join AVANT batctl if add ───────────────────────────────────
# CRITIQUE : wlan0 doit être stable en IBSS avant que batman la prenne
echo "[3/5] ibss join (AVANT batctl if add)..." >> "$LOG"

JOINED=false
for attempt in 1 2 3; do
  echo "    Tentative $attempt..." >> "$LOG"
  iw dev wlan0 ibss join "$ESSID" "$CHANNEL_FREQ" 2>>"$LOG"
  echo "    RC ibss join : $?" >> "$LOG"

  # Attendre association stable (10s max)
  for wait in $(seq 1 10); do
    sleep 1
    LINK=$(iw dev wlan0 link 2>/dev/null)
    if echo "$LINK" | grep -qi "Joined\|Connected"; then
      BSSID=$(echo "$LINK" | awk '/Joined IBSS/{print $3}')
      echo "    Association OK après ${wait}s — BSSID : $BSSID" >> "$LOG"
      JOINED=true
      break 2
    fi
  done
  
  echo "    Pas associé, nouvelle tentative..." >> "$LOG"
  iw dev wlan0 ibss leave 2>>"$LOG" || true
  sleep 2
done

if [ "$JOINED" = false ]; then
  echo "    ERREUR : association IBSS échouée après 3 tentatives" >> "$LOG"
  exit 1
fi

# Laisser l'association se stabiliser AVANT de passer à batman
echo "    Stabilisation association..." >> "$LOG"
sleep 5

echo "    État wlan0 avant batctl if add :" >> "$LOG"
iw dev wlan0 info >> "$LOG" 2>&1
iw dev wlan0 link >> "$LOG" 2>&1

# ── ETAPE 4 : batctl if add (sur wlan0 DÉJÀ stable) ───────────────────────────
echo "[4/5] batctl if add wlan0 (wlan0 déjà en IBSS stable)..." >> "$LOG"

batctl if add wlan0 2>>"$LOG"
echo "    RC batctl if add : $?" >> "$LOG"
sleep 2

# Vérification critique
BATMAN_IF=$(batctl if 2>/dev/null)
echo "    Interfaces batman : ${BATMAN_IF:-VIDE}" >> "$LOG"

if [ -z "$BATMAN_IF" ]; then
  echo "    ERREUR : batman n'a pas pris wlan0" >> "$LOG"
  exit 1
fi

MASTER=$(ip link show wlan0 2>/dev/null | grep -o "master [^ ]*" | awk '{print $2}')
echo "    wlan0 master : ${MASTER:-aucun}" >> "$LOG"

# Attendre que batman stabilise wlan0 (important)
sleep 5

# Vérifier que batman n'a pas perdu wlan0
BATMAN_IF_CHECK=$(batctl if 2>/dev/null)
if [ -z "$BATMAN_IF_CHECK" ]; then
  echo "    ERREUR : batman a perdu wlan0 après 5s (voir dmesg)" >> "$LOG"
  dmesg | grep batman_adv | tail -10 >> "$LOG"
  exit 1
fi

echo "    Batman a gardé wlan0 — OK" >> "$LOG"

# Flush IP wlan0 pour éviter 169.254.x.x
ip addr flush dev wlan0 2>>"$LOG" || true

# ── ETAPE 5 : bat0 up + IP ────────────────────────────────────────────────────
echo "[5/5] Configuration bat0 avec IP ${IP}/24..." >> "$LOG"

ip link set bat0 up 2>>"$LOG"
sleep 1
ip addr flush dev bat0 2>>"$LOG"
ip addr add "${IP}/24" dev bat0 2>>"$LOG"
echo "    RC ip addr add : $?" >> "$LOG"

# ── Résumé ───────────────────────────────────────────────────────────────────
echo "=== Résumé final ===" >> "$LOG"
echo "--- iw dev ---" >> "$LOG"
iw dev >> "$LOG" 2>&1
echo "--- wlan0 link ---" >> "$LOG"
ip link show wlan0 >> "$LOG" 2>&1
echo "--- bat0 ---" >> "$LOG"
ip addr show bat0 >> "$LOG" 2>&1
echo "--- batman interfaces ---" >> "$LOG"
batctl if >> "$LOG" 2>&1
echo "--- batman neighbors (attendre 10s) ---" >> "$LOG"
sleep 10
batctl neighbors >> "$LOG" 2>&1
echo "=== Fin setup $(date) ===" >> "$LOG"

exit 0
BATSCRIPT

chmod +x /usr/local/bin/setup-batman.sh
log "Script BATMAN-adv prêt"

step_ok
echo "Etape 8 OK."

############################################
# [9/16] Service systemd – BATMAN-adv
############################################
echo "[9/16] Service systemd BATMAN-adv..."
step_start "[9/16] Service systemd BATMAN-adv..." "9/16"

cat > /etc/systemd/system/mesh-batman.service <<EOF
[Unit]
Description=Mesh BATMAN-adv Network (wlan0 + bat0)
After=sys-subsystem-net-devices-wlan0.device
Requires=sys-subsystem-net-devices-wlan0.device

[Service]
Type=oneshot
ExecStart=/usr/local/bin/setup-batman.sh
RemainAfterExit=yes
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

log "[ACTION] systemd daemon-reload"
systemctl daemon-reload >>"$LOGFILE" 2>&1

log "[ACTION] Activation mesh-batman.service"
systemctl enable mesh-batman.service >>"$LOGFILE" 2>&1
log_systemd_status mesh-batman.service

step_ok
echo "Etape 9 OK."

############################################
# [10/16] Ping broadcast périodique
############################################
echo "[10/16] Ping broadcast mesh..."
step_start "[10/16] Ping broadcast mesh..." "10/16"

cat > /usr/local/bin/mesh-broadcast-ping.sh <<'EOF'
#!/bin/bash

INTERFACE="bat0"
BROADCAST_IP="10.0.0.255"
INTERVAL=10

echo "=== Mesh broadcast ping started $(date) ==="
echo "Interface  : $INTERFACE"
echo "Broadcast  : $BROADCAST_IP"
echo "Intervalle : ${INTERVAL}s"

# Attente bat0 UP
while true; do
  if ip link show "$INTERFACE" 2>/dev/null | grep -q "UP"; then
    break
  fi
  sleep 1
done

sysctl -w net.ipv4.icmp_echo_ignore_broadcasts=0 >/dev/null

while true; do
  ping -b -c 1 -W 1 "$BROADCAST_IP" >/dev/null 2>&1
  sleep "$INTERVAL"
done
EOF

chmod +x /usr/local/bin/mesh-broadcast-ping.sh

cat > /etc/systemd/system/mesh-broadcast-ping.service <<EOF
[Unit]
Description=Mesh Broadcast Ping (10.0.0.255)
After=mesh-batman.service
Wants=mesh-batman.service

[Service]
Type=simple
ExecStart=/usr/local/bin/mesh-broadcast-ping.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable mesh-broadcast-ping.service >>"$LOGFILE" 2>&1
systemctl start mesh-broadcast-ping.service >>"$LOGFILE" 2>&1

step_ok
echo "Etape 10 OK."

############################################
# [11/16] Script de vérification BATMAN-adv post-boot
############################################
echo "[11/16] Script vérification BATMAN-adv post-boot..."
step_start "[11/16] Script vérification BATMAN-adv post-boot..." "11/16"

cat > /usr/local/bin/mesh-check-batman.sh <<'EOF'
#!/bin/bash

LOG="/var/log/mesh-batman-check.log"
echo "=== Vérification BATMAN-adv $(date) ===" >> "$LOG"

# Attente bat0 UP
for i in {1..30}; do
  if ip link show bat0 2>/dev/null | grep -q "UP"; then
    break
  fi
  sleep 1
done

# Attente IP configurée sur bat0
for i in {1..30}; do
  if ip addr show bat0 | grep -q "10.0.0."; then
    break
  fi
  sleep 1
done

sleep 5

# Vérification module
if ! lsmod | grep -q "^batman_adv"; then
  echo "ERREUR : module batman_adv non chargé, tentative..." >> "$LOG"
  modprobe batman-adv
  sleep 2
fi

# Vérification service actif
if ! systemctl is-active --quiet mesh-batman.service; then
  echo "ERREUR: mesh-batman.service inactif, redémarrage..." >> "$LOG"
  systemctl restart mesh-batman.service
  sleep 10
fi

# Affichage voisins BATMAN-adv
echo "--- Voisins BATMAN-adv ---" >> "$LOG"
batctl neighbors >> "$LOG" 2>&1

# Affichage table de routage
echo "--- Table de routage BATMAN-adv ---" >> "$LOG"
batctl routing_algo >> "$LOG" 2>&1
batctl tg >> "$LOG" 2>&1

# Vérification forwarding
if [ "$(cat /proc/sys/net/ipv4/ip_forward)" != "1" ]; then
  echo "ERREUR: Forwarding désactivé, correction..." >> "$LOG"
  sysctl -w net.ipv4.ip_forward=1
fi

echo "=== Fin vérification $(date) ===" >> "$LOG"
EOF

chmod +x /usr/local/bin/mesh-check-batman.sh

cat > /etc/systemd/system/mesh-check-batman.service <<EOF
[Unit]
Description=Mesh BATMAN-adv Post-Boot Check
After=mesh-batman.service
Wants=mesh-batman.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/mesh-check-batman.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload >>"$LOGFILE" 2>&1
systemctl enable mesh-check-batman.service >>"$LOGFILE" 2>&1

step_ok
echo "Etape 11 OK."

############################################
# [12/16] Logs ICMP + HOPS Mesh (JSON)
############################################
echo "[12/16] Logs ICMP + HOPS Mesh JSON..."
step_start "[12/16] Logs ICMP + HOPS Mesh JSON..." "12/16"

cat > /usr/local/bin/mesh-icmp-json.sh <<'EOF'
#!/bin/bash

LOG_JSON="/var/log/mesh-icmp.json"
INTERFACE="bat0"
PING_INTERVAL=1
DURATION=600
HOPS_CACHE_TTL=5 

START_EPOCH="$1"

if [ -z "$START_EPOCH" ]; then
    echo "Usage: mesh-icmp-json.sh <start_epoch>"
    exit 1
fi

BOARD_ID=$(cat /etc/mesh-id 2>/dev/null)
NODE_IP="10.0.0.$BOARD_ID"

STOP_FLAG="/tmp/mesh-icmp-stop-$BOARD_ID"
LOG_DEBUG="/var/log/mesh-icmp-debug.log"

rm -f "$STOP_FLAG"

cleanup() {
    echo "[$(date)] Signal reçu, arrêt propre en cours..." >> "$LOG_DEBUG"
    touch "$STOP_FLAG"
}

trap cleanup SIGINT SIGTERM

while true; do
    NOW=$(date +%s)
    [ "$NOW" -ge "$START_EPOCH" ] && break
    sleep 0.02
done

REAL_START_EPOCH=$(date +%s)
REAL_START_HUMAN=$(date '+%Y-%m-%d %H:%M:%S')

echo "[$(date)] Démarrage acquisition - Node $NODE_IP" >> "$LOG_DEBUG"

TMP_FILE="/tmp/mesh-icmp-full.tmp"

echo "{" > "$TMP_FILE"
echo "  \"node\": \"$NODE_IP\"," >> "$TMP_FILE"
echo "  \"scheduled_start_epoch\": $START_EPOCH," >> "$TMP_FILE"
echo "  \"real_start_epoch\": $REAL_START_EPOCH," >> "$TMP_FILE"
echo "  \"real_start_time\": \"$REAL_START_HUMAN\"," >> "$TMP_FILE"
echo "  \"iterations\": [" >> "$TMP_FILE"

ITER=0
END_TIME=$((REAL_START_EPOCH + DURATION))

declare -A HOPS_CACHE
declare -A HOPS_CACHE_TIME

while [ "$(date +%s)" -lt "$END_TIME" ] && [ ! -f "$STOP_FLAG" ]; do

    ITER_START_MS=$(date +%s%3N)
    
    [ $ITER -gt 0 ] && echo "," >> "$TMP_FILE"

    echo "    {" >> "$TMP_FILE"
    echo "      \"timestamp\": \"$(date '+%Y-%m-%d %H:%M:%S')\"," >> "$TMP_FILE"
    echo "      \"epoch\": $(date +%s)," >> "$TMP_FILE"
    echo "      \"neighbors\": [" >> "$TMP_FILE"

    ACTIVE_NEIGH_LINES=$(ip neigh show dev "$INTERFACE" 2>/dev/null | awk '/REACHABLE|STALE|DELAY/ {print $1" "$5}')
    # Build ordered list of active IPs (preserve order seen in neighbour table)
    ACTIVE_IPS=$(echo "$ACTIVE_NEIGH_LINES" | awk '{print $1}' | grep '^10\.0\.0\.' || true)

    # Build IP -> MAC table once per iteration
    declare -A IP_TO_MAC=()
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        IP_ADDR=$(echo "$line" | awk '{print $1}')
        MAC_ADDR=$(echo "$line" | awk '{print $2}' | tr '[:upper:]' '[:lower:]')

        # If MAC missing, try a single arping to populate the neighbour table then re-read
        if [ -z "$MAC_ADDR" ] || ! [[ "$MAC_ADDR" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]]; then
            arping -I "$INTERFACE" -c 1 "$IP_ADDR" >/dev/null 2>&1 || true
            MAC_ADDR=$(ip neigh show dev "$INTERFACE" "$IP_ADDR" 2>/dev/null | grep -oE '([0-9a-f]{2}:){5}[0-9a-f]{2}' | tr '[:upper:]' '[:lower:]')
        fi

        [ -z "$MAC_ADDR" ] && MAC_ADDR="unknown"
        IP_TO_MAC["$IP_ADDR"]="$MAC_ADDR"
    done <<< "$ACTIVE_NEIGH_LINES"

    FIRST=true

    # Iterate in the original neighbour order
    for IP in $ACTIVE_IPS; do
        MAC=${IP_TO_MAC[$IP]:-unknown}

        # Start ping and traceroute in parallel for performance
        LAT=0
        NEXT_HOP="unknown"
        HOPS="unknown"

        # Use temp files so child processes cannot "lose" results (subshells can't export vars to parent)
        TMP_PING=$(mktemp)
        TMP_TR=$(mktemp)

        # ping (capture latency) -> background
        ping -I "$INTERFACE" -c 1 -W 1 "$IP" >"$TMP_PING" 2>&1 & PID_PING=$!

        # traceroute -> background (write output to temp file)
        if [ "$MAC" != "unknown" ]; then
            ( batctl traceroute "$MAC" 2>"$TMP_TR".err > "$TMP_TR" ) &
            PID_TR=$!
        else
            echo "" > "$TMP_TR"
            PID_TR=$!
        fi

        # Wait both
        wait $PID_PING $PID_TR 2>/dev/null || true

        # Parse ping latency
        PING_OUT=$(cat "$TMP_PING" 2>/dev/null || true)
        LAT=$(echo "$PING_OUT" | grep -oE 'time=[0-9\.]+' | sed -E 's/time=//' || true)
        [ -z "$LAT" ] && LAT=0

        # Parse traceroute output in parent process
        TR_OUT=$(cat "$TMP_TR" 2>/dev/null || true)
        mapfile -t MACS < <(echo "$TR_OUT" | grep -oE '([0-9a-f]{2}:){5}[0-9a-f]{2}' | tr '[:upper:]' '[:lower:]')

        if [ ${#MACS[@]} -gt 0 ]; then
            HOPS=${#MACS[@]}
            last_idx=$((HOPS - 1))
            last_mac=${MACS[$last_idx]}
            if [ "$last_mac" = "$MAC" ] && [ $last_idx -ge 1 ]; then
                NEXT_HOP=${MACS[$((last_idx-1))]}
            else
                NEXT_HOP=$last_mac
            fi
        else
            NEXT_HOP="unknown"
            HOPS="unknown"
        fi

        # Cleanup temp files
        rm -f "$TMP_PING" "$TMP_TR" "$TMP_TR".err || true

        if [ "$FIRST" = true ]; then
            FIRST=false
        else
            echo "," >> "$TMP_FILE"
        fi

        # Write JSON for this neighbor (guarantee no empty values)
        echo "        {" >> "$TMP_FILE"
        echo "          \"IP\": \"$IP\"," >> "$TMP_FILE"
        echo "          \"MAC\": \"$MAC\"," >> "$TMP_FILE"
        echo "          \"Next_Hop\": \"$NEXT_HOP\"," >> "$TMP_FILE"
        if [ "$HOPS" = "unknown" ]; then
            echo "          \"HOPS\": \"unknown\"," >> "$TMP_FILE"
        else
            echo "          \"HOPS\": $HOPS," >> "$TMP_FILE"
        fi
        echo "          \"LATENCY_MS\": $LAT" >> "$TMP_FILE"
        echo -n "        }" >> "$TMP_FILE"

    done

    echo "" >> "$TMP_FILE"
    echo "      ]" >> "$TMP_FILE"
    echo -n "    }" >> "$TMP_FILE"

    ITER=$((ITER+1))

    ITER_END_MS=$(date +%s%3N)
    ELAPSED_MS=$((ITER_END_MS - ITER_START_MS))
    ELAPSED_S=$((ELAPSED_MS / 1000))
    
    SLEEP_TIME=$((PING_INTERVAL - ELAPSED_S))
    
    if [ "$SLEEP_TIME" -gt 0 ]; then
        sleep "$SLEEP_TIME"
    elif [ "$SLEEP_TIME" -lt 0 ]; then
        echo "[WARN] Itération $ITER trop lente : ${ELAPSED_S}s (seuil ${PING_INTERVAL}s)" >> "$LOG_DEBUG"
    fi
done

echo "" >> "$TMP_FILE"
echo "  ]," >> "$TMP_FILE"
echo "  \"total_duration_s\": $DURATION" >> "$TMP_FILE"
echo "}" >> "$TMP_FILE"

# Déplacement vers le fichier JSON final
mv "$TMP_FILE" "$LOG_JSON"

echo "[$(date)] Acquisition terminée - Node $NODE_IP" >> "$LOG_DEBUG"
EOF

chmod +x /usr/local/bin/mesh-icmp-json.sh

cat > /etc/systemd/system/mesh-icmp-json.service <<EOF
[Unit]
Description=Mesh ICMP JSON Logging (600s)
After=mesh-batman.service
Wants=mesh-batman.service

[Service]
Type=simple
ExecStart=/usr/local/bin/mesh-icmp-json.sh
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl disable mesh-icmp-json.service

log "Service ICMP JSON prêt (manuel uniquement)"

step_ok
echo "Etape 12 OK."

############################################
# [13/16] Script maître – Déclenchement ICMP global
############################################
echo "[13/16] Préparation déclenchement ICMP global (manuel)..."
step_start "[13/16] Déclenchement ICMP global manuel" "13/16"

if [ "$BOARD_ID" -eq 1 ]; then

cat > /usr/local/bin/mesh-run-icmp <<'EOF'
#!/bin/bash

USER="rpi"
PASS="rpi"
NETWORK="10.0.0.0/24"
DURATION=600
START_DELAY=30
LOG="/var/log/mesh-master-sync.log"
LOCAL_DIR="/home/pi/mesh-logs"

mkdir -p "$LOCAL_DIR"

echo "===================================" | tee -a "$LOG"
echo "Déclenchement synchronisé $(date)" | tee -a "$LOG"
echo "===================================" | tee -a "$LOG"

START_EPOCH=$(( $(date +%s) + START_DELAY ))
HUMAN_START=$(date -d @$START_EPOCH '+%Y-%m-%d %H:%M:%S')

echo "Départ programmé à $HUMAN_START (epoch $START_EPOCH)" | tee -a "$LOG"

NODES=$(nmap -sn $NETWORK | awk '/Nmap scan report/{print $5}' | grep 10.0.0.)

for IP in $NODES; do
    echo "Envoi ordre à $IP" | tee -a "$LOG"

    sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
        $USER@$IP \
        "sudo /usr/local/bin/mesh-icmp-json.sh $START_EPOCH > /dev/null 2>&1 &" &
done

wait

echo "Tous les ordres envoyés" | tee -a "$LOG"
echo "Attente fin acquisition..." | tee -a "$LOG"

sleep $((START_DELAY + DURATION + 5))

for IP in $NODES; do
    ID=$(echo $IP | awk -F. '{print $4}')
    DEST="$LOCAL_DIR/log.$ID.json"

    sshpass -p "$PASS" scp -o StrictHostKeyChecking=no \
        $USER@$IP:/var/log/mesh-icmp.json \
        "$DEST" > /dev/null 2>&1

    if [ -f "$DEST" ]; then
        echo "Récupéré $DEST" | tee -a "$LOG"
    else
        echo "Echec récupération $IP" | tee -a "$LOG"
    fi
done

echo "Synchronisation terminée $(date)" | tee -a "$LOG"
EOF

chmod +x /usr/local/bin/mesh-run-icmp

echo "alias mesh-run-icmp='sudo /usr/local/bin/mesh-run-icmp'" >> /home/pi/.bashrc

log "Commande disponible : sudo mesh-run-icmp"

fi

step_ok
echo "Etape 13 OK."

############################################
# [14/16] Reset IP bat0 après boot
############################################
echo "[14/16] Reset IP bat0 après boot..."
step_start "[14/16] Reset IP bat0 après boot..." "14/16"

cat > /usr/local/bin/mesh-reset-ip.sh <<'EOF'
#!/bin/bash

LOG="/var/log/mesh-reset-ip.log"
echo "=== Mesh reset IP $(date) ===" >> "$LOG"

sleep 15

if [ ! -f /etc/mesh-id ]; then
    echo "Erreur : /etc/mesh-id introuvable" >> "$LOG"
    exit 1
fi
BOARD_ID=$(cat /etc/mesh-id)
IP="10.0.0.$BOARD_ID"
echo "BOARD_ID=$BOARD_ID, IP=$IP" >> "$LOG"

# Vérification bat0
if ! ip link show bat0 >/dev/null 2>&1; then
    echo "Erreur : bat0 introuvable, relance du service mesh-batman..." >> "$LOG"
    systemctl restart mesh-batman.service
    sleep 10
fi

# Nettoyage wlan0 : flush IP uniquement, PAS de DOWN
# batman-adv a besoin que wlan0 reste UP comme lien physique radio
echo "Flush IP wlan0 (reste UP pour batman-adv)..." >> "$LOG"
ip addr flush dev wlan0 2>>"$LOG" || true
sysctl -w net.ipv4.conf.wlan0.autoconf=0 >> "$LOG" 2>&1

echo "Flush IP bat0..." >> "$LOG"
ip addr flush dev bat0 2>>"$LOG" || true

sleep 2

echo "Remise IP ${IP}/24 sur bat0..." >> "$LOG"
ip link set bat0 up 2>>"$LOG"
ip addr add "${IP}/24" dev bat0 2>>"$LOG"

echo "=== Etat final ===" >> "$LOG"
ip addr show wlan0 >> "$LOG" 2>&1
ip addr show bat0  >> "$LOG" 2>&1
batctl if          >> "$LOG" 2>&1
batctl neighbors   >> "$LOG" 2>&1

echo "=== Fin Mesh reset IP $(date) ===" >> "$LOG"
EOF

chmod +x /usr/local/bin/mesh-reset-ip.sh

cat > /etc/systemd/system/mesh-reset-ip.service <<EOF
[Unit]
Description=Reset IP bat0 after boot
After=mesh-batman.service
Wants=mesh-batman.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/mesh-reset-ip.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload >>"$LOGFILE" 2>&1
systemctl enable mesh-reset-ip.service >>"$LOGFILE" 2>&1

step_ok
echo "Etape 14 OK."

############################################
# [15/16] Script de diagnostic mesh-info + alias
############################################
echo "[15/16] Alias de diagnostic BATMAN-adv..."
step_start "[15/16] Alias de diagnostic..." "15/16"

cat > /usr/local/bin/mesh-info <<'MESHINFO'
#!/bin/bash
# mesh-info : diagnostic complet du mesh BATMAN-adv

IFACE="bat0"
RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'
BLU='\033[1;34m'; CYN='\033[0;36m'; NC='\033[0m'

board_id=$(cat /etc/mesh-id 2>/dev/null || echo "?")

echo ""
echo -e "${BLU}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BLU}║     Mesh BATMAN-adv  —  Noeud $board_id              ║${NC}"
echo -e "${BLU}╚══════════════════════════════════════════════╝${NC}"
echo ""

# ── Interfaces ──────────────────────────────────────────────
echo -e "${YEL}── Interfaces reseau ──────────────────────────${NC}"
printf "  %-8s  %-28s  %s\n" "IF" "Adresses IPv4" "Etat"
echo "  ──────────────────────────────────────────────────────"

for IF in wlan0 bat0; do
    STATE=$(cat /sys/class/net/$IF/operstate 2>/dev/null || echo "absent")
    ADDRS=$(ip -4 addr show $IF 2>/dev/null | awk '/inet /{print $2}' | tr '\n' ' ')
    LL=$(ip -4 addr show $IF 2>/dev/null | awk '/inet 169\./{print $2}' | tr '\n' ' ')

    [ "$STATE" = "up" ] && S="${GRN}UP${NC}" || S="${RED}$STATE${NC}"
    [ -n "$LL" ]        && WARN="${RED}  << WARN: 169.254 presente !${NC}" || WARN=""
    [ -z "$ADDRS" ]     && ADDRS="—"

    printf "  %-8s  %-28s  " "$IF" "$ADDRS"
    echo -e "$S$WARN"
done

# Avertissement explicite wlan0
LL_WLAN=$(ip -4 addr show wlan0 2>/dev/null | awk '/169\./{print $2}')
if [ -n "$LL_WLAN" ]; then
    echo ""
    echo -e "  ${RED}[!] wlan0 a toujours : $LL_WLAN${NC}"
    echo -e "  ${YEL}    Corriger avec : mesh-wlan0-clean${NC}"
fi

ADDRS6=$(ip -6 addr show bat0 2>/dev/null | awk '/inet6 /{print $2}' | grep -v '^fe80' | tr '\n' ' ')
[ -n "$ADDRS6" ] && echo -e "  bat0 IPv6 : ${CYN}${ADDRS6}${NC}"
echo ""

# ── Voisins BATMAN-adv avec IP et latence ──────────────────
echo -e "${YEL}── Voisins BATMAN-adv (MAC, IP, latence) ───────${NC}"
printf "  %-19s  %-16s  %-14s  %s\n" "MAC voisin" "IP 10.0.0.x" "Latence moy." "Vu il y a"
echo "  ──────────────────────────────────────────────────────"

# Table ARP bat0 : MAC → IP (source la plus fiable)
declare -A ARP_MAC
while IFS= read -r line; do
    IP=$(echo "$line"  | awk '{print $1}')
    MAC=$(echo "$line" | awk '{print $5}')
    [[ "$IP" =~ ^10\.0\.0\. ]] && [ -n "$MAC" ] && ARP_MAC["$MAC"]="$IP"
done < <(ip neigh show dev "$IFACE" 2>/dev/null)

# Translation table batman : MAC → IP (fallback)
declare -A TG_MAC
while IFS= read -r line; do
    MAC=$(echo "$line" | awk '{print $1}')
    IP=$(echo "$line"  | grep -oP '10\.0\.0\.[0-9]+' | head -1)
    [ -n "$MAC" ] && [ -n "$IP" ] && TG_MAC["$MAC"]="$IP"
done < <(batctl tg 2>/dev/null | tail -n +3)

HAS=false
while IFS= read -r line; do
    # Ignorer lignes vides et header
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "$line" =~ ^\[B\.A\.T\.M\.A\.N ]] && continue
    [[ "$line" =~ ^IF[[:space:]] ]] && continue
    
    # Colonnes : $1=wlan0, $2=MAC, $3=last-seen
    MAC=$(echo "$line"  | awk '{print $2}')
    SEEN=$(echo "$line" | awk '{print $3}')
    
    # Vérifier que MAC ressemble à une adresse MAC
    [[ ! "$MAC" =~ ^[0-9a-f]{2}:[0-9a-f]{2} ]] && continue

    TARGET="${ARP_MAC[$MAC]:-${TG_MAC[$MAC]:-}}"

    if [ -n "$TARGET" ]; then
        POUT=$(ping -I "$IFACE" -c 2 -W 1 -q "$TARGET" 2>/dev/null)
        LAT=$(echo "$POUT" | grep -oP 'rtt.+= \K[0-9.]+(?=/[0-9.]+/[0-9.]+)')
        [ -z "$LAT" ] && LAT=$(echo "$POUT" | grep -oP '[0-9.]+/\K[0-9.]+(?=/[0-9.]+/[0-9.]+)')
        if [ -n "$LAT" ]; then
            LAT_STR="${GRN}${LAT} ms${NC}"
        else
            LAT_STR="${RED}injoignable${NC}"
        fi
    else
        TARGET="— (ARP vide)"
        LAT_STR="${YEL}—${NC}"
    fi

    printf "  %-19s  %-16s  " "$MAC" "$TARGET"
    echo -e "${LAT_STR}          ${SEEN}"
    HAS=true
done < <(batctl neighbors 2>/dev/null)

$HAS || echo -e "  ${RED}Aucun voisin BATMAN-adv detecte${NC}"
echo ""

# ── Routes actives ─────────────────────────────────────────
echo -e "${YEL}── Routes actives (bat0) ───────────────────────${NC}"
ip route show dev bat0 2>/dev/null | sed 's/^/  /' || echo "  —"
echo ""

echo -e "${CYN}  Commandes disponibles :${NC}"
echo "    mesh-info          → ce resume"
echo "    batctl tg          → translation table complete"
echo "    batctl ping <MAC>  → ping L2 vers un voisin"
echo "    mesh-wlan0-clean   → supprimer 169.254.x.x sur wlan0"
echo "    mesh-log           → log setup en direct"
echo ""
MESHINFO

chmod +x /usr/local/bin/mesh-info

cat >> /etc/bash.bashrc <<'ALIASES'

# === Alias mesh BATMAN-adv ===
alias mesh-info='/usr/local/bin/mesh-info'
alias mesh-neigh='batctl neighbors'
alias mesh-tg='batctl tg'
alias mesh-ping='batctl ping'
alias mesh-status='systemctl status mesh-batman.service mesh-broadcast-ping.service mesh-reset-ip.service'
alias mesh-log='tail -f /var/log/mesh-batman-setup.log'
alias mesh-wlan0-clean='ip addr flush dev wlan0 2>/dev/null; sysctl -w net.ipv4.conf.wlan0.autoconf=0 >/dev/null; echo "wlan0 : IPs flushees (reste UP pour batman-adv)"'
ALIASES

step_ok
echo "Etape 15 OK." 

############################################
# [16/16] Identité & logs
############################################
echo "[16/16] Finalisation..."
step_start "[16/16] Finalisation..." "16/16"

echo "$BOARD_ID" > /etc/mesh-id
mkdir -p /var/log
touch /var/log/mesh-adhoc.log

step_ok

echo "========================================="
echo " INSTALLATION TERMINÉE"
echo " Node ID  : $BOARD_ID"
echo " IP       : $IP (sur bat0)"
echo " ESSID    : $ESSID"
echo " Proto    : BATMAN-adv"
echo "========================================="
echo ""
echo " Commandes utiles post-boot :"
echo "   batctl neighbors     → voisins directs"
echo "   batctl tg            → table de routage"
echo "   batctl ping <IP MAC> → ping couche 2"
echo "   mesh-run-icmp        → lancer acquisition (noeud 1 seulement)"
echo ""
echo "Redémarrage dans 30 secondes..."
sleep 30
reboot