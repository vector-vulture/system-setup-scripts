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
echo "This script will install the Elastic Agent"
read -rp "Do you want to continue? (y/n): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "Aborted by user."
  exit 0
fi

echo "Installing Elastic Agent 9.0.3..."
cd /tmp
run_step "Downloading Elastic Agent" curl -s -O https://artifacts.elastic.co/downloads/beats/elastic-agent/elastic-agent-9.0.3-linux-x86_64.tar.gz
run_step "Extracting Elastic Agent" tar xzf elastic-agent-9.0.3-linux-x86_64.tar.gz
cd elastic-agent-9.0.3-linux-x86_64
run_step "Installing & enrolling Elastic Agent" ./elastic-agent install --non-interactive --url=https://elastic.lineit.nl:8220 --enrollment-token="$ENROLL_TOKEN"

echo "Elastic Agent was installed correctly and enrolled with fleet server via the provided enrollment token."
echo "Setup complete. Check Kibana interface for connection status."