#!/bin/bash

set -e

# === Spinner function for progress indication ===
spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    while kill -0 "$pid" 2>/dev/null; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

# === Run step helper with spinner ===
run_step() {
  echo -n "$1..."
  shift
  "$@" &>/dev/null &
  pid=$!
  spinner $pid
  wait $pid
  if [ $? -ne 0 ]; then
    echo " Error!"
    exit 1
  else
    echo " Done."
  fi
}

# === Ensure the script is run as root ===
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as the root user."
  exit 1
fi

# === Script Confirmation ===
echo "This script will help install and configure the following:"
echo " - Set desired system timezone and locales"
echo " - Chrony (time sync daemon, time server is required)"
echo " - Auditd with custom rules"
echo " - Sysmon for Linux"
read -rp "Do you want to continue? (y/n): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "Aborted by user."
  exit 0
fi

# === Get interactive inputs ===
while true; do
  echo "Please enter your timezone in tz database format (example: Europe/Amsterdam):"
  read -r USER_TIMEZONE
  if [[ "$USER_TIMEZONE" =~ ^[A-Za-z_]+/[A-Za-z_]+$ ]]; then
    break
  else
    echo "Provided invalid timezone format."
  fi
done

while true; do
  echo "Enter 2 desired locales. One for system language, One for date/time format. Seperate them with a space (e.g., en_US.UTF-8 nl_NL.UTF-8):"
  read -r USER_LOCALES
  read -r FIRST_LOCALE SECOND_LOCALE <<< "$USER_LOCALES"
  LOCALE_REGEX='^[a-z]{2}_[A-Z]{2}\.UTF-8$'
  if [[ "$FIRST_LOCALE" =~ $LOCALE_REGEX && "$SECOND_LOCALE" =~ $LOCALE_REGEX ]]; then
    break
  else
    echo "Provided invalid locale(s)."
  fi
done

while true; do
  echo "Enter the IP or hostname of the NTP server (e.g., 10.10.10.1 or time.domain.com):"
  read -r CHRONY_SERVER_IP
  if [[ "$CHRONY_SERVER_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || "$CHRONY_SERVER_IP" =~ ^(([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,})$ ]]; then
    break
  else
    echo "Provided invalid IP or hostname for time server."
  fi
done

while true; do
  echo "Enter your desired Auditd backlog_limit value (e.g., 8192, 16384, 32768, 65535):"
  read -r BACKLOG_LIMIT
  if [[ "$BACKLOG_LIMIT" =~ ^[0-9]+$ ]]; then
    break
  else
    echo "Auditd backlog limit must be an integer."
  fi
done

run_step "Generating locales" locale-gen "$FIRST_LOCALE" "$SECOND_LOCALE"
run_step "Setting locales" update-locale LANG="$FIRST_LOCALE"
for LC_VAR in LC_CTYPE LC_NUMERIC LC_TIME LC_COLLATE LC_MONETARY LC_MESSAGES \
              LC_PAPER LC_NAME LC_ADDRESS LC_TELEPHONE LC_MEASUREMENT LC_IDENTIFICATION; do
  update-locale "$LC_VAR=$SECOND_LOCALE" &>/dev/null
done

run_step "Setting timezone" timedatectl set-timezone "$USER_TIMEZONE"
run_step "Installing chrony" apt install -y chrony wget

CHRONY_CONF="/etc/chrony/chrony.conf"
cp "$CHRONY_CONF" "${CHRONY_CONF}.bak"
TEMP_CHRONY_CONF=$(mktemp)
trap "rm -f $TEMP_CHRONY_CONF" EXIT
grep -vE '^(server|pool)\b' "$CHRONY_CONF" > "$TEMP_CHRONY_CONF"
echo "server $CHRONY_SERVER_IP iburst" >> "$TEMP_CHRONY_CONF"
cat >> "$TEMP_CHRONY_CONF" << EOF
driftfile /var/lib/chrony/chrony.drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
EOF
mv "$TEMP_CHRONY_CONF" "$CHRONY_CONF"
run_step "Enabling chrony" systemctl enable --now chrony
run_step "Restarting chrony" systemctl restart chrony

run_step "Installing auditd" apt-get install -y auditd

AUDITD_CONF="/etc/audit/auditd.conf"
RULES_DIR="/etc/audit/rules.d"
OUTPUT_RULES_FILE="$RULES_DIR/quantum_auditd.rules"
TMP_DIR=$(mktemp -d)
trap "rm -rf $TMP_DIR" EXIT

[ -f "$AUDITD_CONF" ] && cp "$AUDITD_CONF" "${AUDITD_CONF}.bak.$(date +%F_%T)"

run_step "Downloading auditd.conf" wget -q -O "$TMP_DIR/auditd.conf" https://raw.githubusercontent.com/armor/auditd-config/master/config/auditd.conf
cp "$TMP_DIR/auditd.conf" "$AUDITD_CONF"
run_step "Downloading audit rules" wget -q -O "$TMP_DIR/quantum_auditd.rules" https://raw.githubusercontent.com/armor/auditd-config/master/config/quantum_auditd.rules

[ -f "$OUTPUT_RULES_FILE" ] && cp "$OUTPUT_RULES_FILE" "$OUTPUT_RULES_FILE.bak.$(date +%F_%T)"

mv "$TMP_DIR/quantum_auditd.rules" "$OUTPUT_RULES_FILE"
chown root:root "$OUTPUT_RULES_FILE"
chmod 640 "$OUTPUT_RULES_FILE"

grep -q '^-b' "$OUTPUT_RULES_FILE" && \
  sed -i "s/^-b.*/-b ${BACKLOG_LIMIT}/" "$OUTPUT_RULES_FILE" || \
  echo "-b ${BACKLOG_LIMIT}" >> "$OUTPUT_RULES_FILE"

sed -i '381s/^/# /' "$OUTPUT_RULES_FILE" || true

run_step "Validating audit rules" auditctl -R "$OUTPUT_RULES_FILE"
run_step "Loading persistent rules" augenrules --load
run_step "Restarting auditd" systemctl restart auditd

echo "Current audit backlog limit setting:"
auditctl -s | grep "backlog_limit"

# === Sysmon for Linux Setup ===
SYSMON_CONFIG_URL="https://raw.githubusercontent.com/vector-vulture/sysmon/refs/heads/main/ubuntu/sysmon.xml"
SYSMON_CONFIG_PATH="/etc/sysmon/sysmon.xml"
SYSMON_BIN="/usr/bin/sysmon"

if ! dpkg -s sysmonforlinux &>/dev/null; then
  run_step "Downloading MS repo package" wget -q "https://packages.microsoft.com/config/ubuntu/$(lsb_release -rs)/packages-microsoft-prod.deb" -O /tmp/packages-microsoft-prod.deb
  run_step "Installing MS repo package" dpkg -i /tmp/packages-microsoft-prod.deb
  run_step "Updating local package cache" apt-get update
  run_step "Installing sysmonforlinux" apt-get install -y sysmonforlinux
fi

mkdir -p "$(dirname "$SYSMON_CONFIG_PATH")"
run_step "Downloading Sysmon config" curl -fsSL "$SYSMON_CONFIG_URL" -o "$SYSMON_CONFIG_PATH"
run_step "Installing Sysmon" "$SYSMON_BIN" -i "$SYSMON_CONFIG_PATH"
run_step "Enabling Sysmon service" systemctl enable sysmon.service
run_step "Starting Sysmon service" systemctl start sysmon.service

echo "Setup complete. Restart your shell session to correctly apply new locale settings."