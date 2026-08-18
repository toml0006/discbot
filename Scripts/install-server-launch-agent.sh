#!/bin/bash

set -euo pipefail

label="com.middleout.Discbot.server"
app_path="$HOME/Applications/Discbot-Server.app"
action="install"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)
            app_path="$2"
            shift 2
            ;;
        --uninstall)
            action="uninstall"
            shift
            ;;
        --status)
            action="status"
            shift
            ;;
        *)
            echo "Usage: $0 [--app /path/to/Discbot.app] [--status|--uninstall]" >&2
            exit 64
            ;;
    esac
done

uid="$(id -u)"
if launchctl print "gui/$uid" >/dev/null 2>&1; then
    domain="gui/$uid"
else
    domain="user/$uid"
fi
service="$domain/$label"
plist="$HOME/Library/LaunchAgents/$label.plist"
executable="$app_path/Contents/MacOS/Discbot"
log_dir="$HOME/Library/Logs/Discbot"
daemon_plist="/Library/LaunchDaemons/$label.plist"
loopback_key="$HOME/.ssh/discbot_loopback_ed25519"
loopback_known_hosts="$HOME/.ssh/discbot_loopback_known_hosts"

if [[ "$action" == "status" ]]; then
    launchctl print "$service"
    exit $?
fi

if [[ "$action" == "uninstall" ]]; then
    launchctl bootout "$domain" "$plist" >/dev/null 2>&1 || true
    rm -f "$plist"
    echo "Removed $label from $domain"
    exit 0
fi

if [[ ! -x "$executable" ]]; then
    echo "Discbot executable not found at $executable" >&2
    exit 66
fi

# Catalina only grants cddafs mounting to the logged-in user bootstrap domain.
# Migrate an older system LaunchDaemon install before registering this agent.
# Administrator authorization is used only to remove that root-owned service;
# Discbot itself continues to run as the current user.
if [[ -f "$daemon_plist" ]]; then
    echo "Removing the legacy system LaunchDaemon (administrator authorization required)..."
    sudo launchctl bootout system "$daemon_plist" >/dev/null 2>&1 || true
    sudo rm -f "$daemon_plist"
fi

mkdir -p "$(dirname "$plist")" "$log_dir"

# Catalina grants the direct cddafs mount used for audio ripping only inside a
# login session. A localhost-only SSH hop creates that session while launchd
# still supervises the process. The dedicated key never leaves this Mac and is
# restricted to loopback connections with all forwarding disabled.
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
if [[ ! -f "$loopback_key" ]]; then
    ssh-keygen -q -t ed25519 -N "" -C "discbot-loopback" -f "$loopback_key"
fi
touch "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys" "$loopback_key"
loopback_public_key="$(cat "$loopback_key.pub")"
if ! grep -Fq "discbot-loopback" "$HOME/.ssh/authorized_keys"; then
    printf 'from="127.0.0.1,::1",restrict %s\n' "$loopback_public_key" >> "$HOME/.ssh/authorized_keys"
fi
ssh -T \
    -i "$loopback_key" \
    -o BatchMode=yes \
    -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=no \
    -o "UserKnownHostsFile=$loopback_known_hosts" \
    127.0.0.1 true

temporary_plist="$(mktemp "${TMPDIR:-/tmp}/discbot-launch-agent.XXXXXX")"
trap 'rm -f "$temporary_plist"' EXIT

cat > "$temporary_plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array>
    <string>/usr/bin/ssh</string>
    <string>-T</string>
    <string>-i</string>
    <string>$loopback_key</string>
    <string>-o</string><string>BatchMode=yes</string>
    <string>-o</string><string>IdentitiesOnly=yes</string>
    <string>-o</string><string>StrictHostKeyChecking=no</string>
    <string>-o</string><string>UserKnownHostsFile=$loopback_known_hosts</string>
    <string>-o</string><string>ServerAliveInterval=30</string>
    <string>-o</string><string>ServerAliveCountMax=3</string>
    <string>127.0.0.1</string>
    <string>$executable</string>
    <string>--server</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$log_dir/server.log</string>
  <key>StandardErrorPath</key><string>$log_dir/server-error.log</string>
</dict></plist>
EOF

plutil -lint "$temporary_plist" >/dev/null
launchctl bootout "$domain" "$plist" >/dev/null 2>&1 || true
install -m 600 "$temporary_plist" "$plist"
launchctl bootstrap "$domain" "$plist"
launchctl kickstart -k "$service"
echo "Installed $label in $domain"
echo "Audio-CD cddafs access is available through a localhost login session while this user is logged in."
echo "Logs: $log_dir"
