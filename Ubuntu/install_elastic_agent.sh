#!/bin/bash

set -e

# === Configuration ===
FLEET_URL="https://elastic.fleet.com:8220"    # ← Fleet server URL
ENROLL_TOKEN="REPLACE_WITH_YOUR_TOKEN"        # ← Enrollment token

# === Spinner & Runner ===
spinner() {
    local pid=$1 delay=0.1 spin='|/-\'
    while kill -0 "$pid" 2>/dev/null; do
        printf " [%c]  " "${spin:0:1}"
        spin="${spin:1}${spin:0:1}"
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

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

# === Check for Root ===
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as the root user."
    exit 1
fi

# === Script Confirmation ===
echo "This script will install the latest Elastic Agent."
read -rp "Do you want to continue? (y/n): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Aborted by user."
    exit 0
fi

# === Detect Latest Version ===
echo "Fetching latest Elastic Agent release info from GitHub..."
LATEST_TAG=$(curl -fsSL https://api.github.com/repos/elastic/beats/releases/latest | grep -Po '"tag_name": "\K.*?(?=")')
if [[ -z "$LATEST_TAG" ]]; then
    echo "Failed to detect latest version."
    exit 1
fi

LATEST_VERSION="${LATEST_TAG#v}"
echo "Latest Elastic Agent version detected: $LATEST_VERSION"

# === Download and Install ===
cd /tmp

TARBALL="elastic-agent-${LATEST_VERSION}-linux-x86_64.tar.gz"
DOWNLOAD_URL="https://artifacts.elastic.co/downloads/beats/elastic-agent/${TARBALL}"

echo "Now downloading and extracting..."

run_step "Downloading agent $LATEST_VERSION" curl -s -O "$DOWNLOAD_URL"
run_step "Extracting agent" tar xzf "$TARBALL"
cd "elastic-agent-${LATEST_VERSION}-linux-x86_64"

run_step "Installing & enrolling agent" ./elastic-agent install --non-interactive --url="$FLEET_URL" --enrollment-token="$ENROLL_TOKEN"

echo "Checking Elastic Agent status..."
./elastic-agent status

echo "Elastic Agent $LATEST_VERSION installed and enrolled to fleet server successfully."