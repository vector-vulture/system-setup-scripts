#!/bin/bash

set -e

# === Spinner & Runner for background commands that exit ===
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

# === Run command in foreground without spinner ===
run_step_fg() {
    echo -n "$1..."
    shift
    "$@"
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
read -erp "Do you want to continue? (y/n): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Aborted by user."
    exit 0
fi

# === Prompt for Fleet URL with validation ===
while true; do
    read -erp "Enter the Fleet server URL or IP (e.g., https://elastic.fleet.com:8220 or 10.10.10.10:8220): " FLEET_URL
    if [[ "$FLEET_URL" =~ ^https?://(([a-zA-Z0-9-]+\.)*[a-zA-Z0-9-]+|\b([0-9]{1,3}\.){3}[0-9]{1,3}\b)(:[0-9]{1,5})?$ ]]; then
        break
    else
        echo "Invalid URL or IP. Please try again."
    fi
done

# === Prompt for Enrollment Token with validation ===
while true; do
    read -erp "Enter the Elastic Agent Fleet Server enrollment token (min 32 characters): " ENROLL_TOKEN
    if [[ ${#ENROLL_TOKEN} -ge 32 ]]; then
        break
    else
        echo "Enrollment token must be at least 32 characters long. Please try again."
    fi
done

echo "Using Fleet URL: $FLEET_URL"
echo "Using Enrollment Token: $ENROLL_TOKEN"

# === Detect Latest Version ===
echo "Fetching latest Elastic Agent release info from GitHub..."
LATEST_TAG=$(curl -fsSL https://api.github.com/repos/elastic/beats/releases/latest | grep -Po '"tag_name": "\K.*?(?=")')
if [[ -z "$LATEST_TAG" ]]; then
    echo "Failed to detect latest Agent version."
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

echo -n "Installing & enrolling agent to Fleet..."
./elastic-agent install --non-interactive --url="$FLEET_URL" --enrollment-token="$ENROLL_TOKEN" &>/dev/null
if [ $? -ne 0 ]; then
    echo " Error!"
    exit 1
else
    echo " Done."
fi

echo "Waiting for the Elastic Agent to initialize..."
sleep 15

echo "Checking Elastic Agent systemd service status:"
if systemctl is-active --quiet elastic-agent; then
    echo "Elastic Agent service is running."
    elastic-agent status || echo "Elastic Agent status check failed."

    echo "Cleaning up the old installation files..."
    rm -f /tmp/elastic-agent-*-linux-x86_64.tar.gz
    find /tmp -maxdepth 1 -type d -name "elastic-agent-*-linux-x86_64" -exec rm -rf {} +
    echo "Cleanup done."
else
    echo "Elastic Agent service is not running yet. Skipping cleanup."
fi

