#!/bin/bash

# Install the headless server at boot on a Mac with no logged-in Aqua session.
# This requires root only to register the launch daemon; Discbot itself runs as
# the invoking user with the built-in operator group so it can read optical raw
# devices. It retains that user's settings, catalog, and destinations and never
# runs the HTTP server as root.

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Run this installer with sudo." >&2
    exit 77
fi

run_user="${SUDO_USER:-}"
if [[ -z "$run_user" || "$run_user" == "root" ]]; then
    echo "Run with sudo from the account that owns the Discbot catalog." >&2
    exit 64
fi

run_home="$(dscl . -read "/Users/$run_user" NFSHomeDirectory | awk '{print $2}')"
label="com.middleout.Discbot.server"
app_path="$run_home/Applications/Discbot-Server.app"
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
            echo "Usage: sudo $0 [--app /path/to/Discbot.app] [--status|--uninstall]" >&2
            exit 64
            ;;
    esac
done

plist="/Library/LaunchDaemons/$label.plist"
service="system/$label"
executable="$app_path/Contents/MacOS/Discbot"
log_dir="$run_home/Library/Logs/Discbot"

if [[ "$action" == "status" ]]; then
    launchctl print "$service"
    exit $?
fi

if [[ "$action" == "uninstall" ]]; then
    launchctl bootout system "$plist" >/dev/null 2>&1 || true
    rm -f "$plist"
    echo "Removed $label"
    exit 0
fi

if [[ ! -x "$executable" ]]; then
    echo "Discbot executable not found at $executable" >&2
    exit 66
fi

# Catalina's raw optical-device authorization checks group membership rather
# than relying solely on the daemon's effective primary group. Ensure the
# account itself is a member so audio CDs can be read from /dev/rdisk*.
if ! dseditgroup -o checkmember -m "$run_user" operator 2>/dev/null | grep -q 'yes'; then
    dseditgroup -o edit -a "$run_user" -t user operator
fi

mkdir -p "$log_dir"
chown "$run_user":staff "$log_dir"
temporary_plist="$(mktemp /tmp/discbot-launch-daemon.XXXXXX)"
trap 'rm -f "$temporary_plist"' EXIT

cat > "$temporary_plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>UserName</key><string>$run_user</string>
  <key>GroupName</key><string>operator</string>
  <key>ProgramArguments</key><array>
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
launchctl bootout system "$plist" >/dev/null 2>&1 || true

# Gracefully hand off a server that was started manually. The application owns
# safe batch cancellation/return-to-slot and will refuse to exit if cleanup
# cannot be verified, so the installer never escalates to SIGKILL.
server_pattern="^$executable --server$"
server_pids="$(pgrep -f "$server_pattern" || true)"
if [[ -n "$server_pids" ]]; then
    kill -TERM $server_pids
    attempts=0
    while pgrep -f "$server_pattern" >/dev/null 2>&1; do
        attempts=$((attempts + 1))
        if [[ "$attempts" -ge 760 ]]; then
            echo "Existing server refused to stop safely within 190 seconds; daemon was not installed." >&2
            exit 1
        fi
        sleep 0.25
    done
fi

install -o root -g wheel -m 644 "$temporary_plist" "$plist"

# Prevent a future GUI login from also trying to start the per-user agent.
user_plist="$run_home/Library/LaunchAgents/$label.plist"
launchctl bootout "gui/$(id -u "$run_user")" "$user_plist" >/dev/null 2>&1 || true
rm -f "$user_plist"

# Catalina keys the application-firewall rule to the installed bundle. Refresh
# it during every deployment so replacing the executable does not silently
# block the web client again.
firewall=/usr/libexec/ApplicationFirewall/socketfilterfw
if [[ -x "$firewall" ]]; then
    "$firewall" --remove "$app_path" >/dev/null 2>&1 || true
    "$firewall" --add "$app_path"
    "$firewall" --unblockapp "$app_path"
fi

launchctl bootstrap system "$plist"
launchctl kickstart -k "$service"
echo "Installed $label as a system launch daemon running as $run_user:operator"
echo "Logs: $log_dir"
