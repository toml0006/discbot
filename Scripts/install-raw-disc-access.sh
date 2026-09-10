#!/bin/bash

set -euo pipefail

group_name="operator"
mode="install"
target_user="${SUDO_USER:-$(/usr/bin/id -un)}"

usage() {
    /bin/cat <<'EOF'
Usage: install-raw-disc-access.sh [--check | --uninstall] [--user USER]

Adds a macOS user to the built-in operator group so RIPT/Discbot can read raw
audio-CD sectors without running the app as root. Run without sudo; the script
will request administrator authorization only when it needs to change the group.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)
            mode="check"
            shift
            ;;
        --uninstall)
            mode="uninstall"
            shift
            ;;
        --user)
            if [[ $# -lt 2 ]]; then
                usage >&2
                exit 2
            fi
            target_user="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
done

case "$target_user" in
    ""|-*)
        /bin/echo "Invalid user name: $target_user" >&2
        exit 2
        ;;
esac

if ! /usr/bin/id "$target_user" >/dev/null 2>&1; then
    /bin/echo "macOS user does not exist: $target_user" >&2
    exit 2
fi

directory_member() {
    /usr/sbin/dseditgroup -o checkmember -m "$target_user" "$group_name" 2>&1 \
        | /usr/bin/grep -q "^yes "
}

active_member() {
    if [[ "$target_user" != "$(/usr/bin/id -un)" ]]; then
        return 1
    fi
    /usr/bin/id -Gn | /usr/bin/tr ' ' '\n' \
        | /usr/bin/grep -qx "$group_name"
}

show_status() {
    if directory_member; then
        /bin/echo "Directory membership: $target_user is in $group_name."
    else
        /bin/echo "Directory membership: $target_user is not in $group_name."
    fi

    if [[ "$target_user" != "$(/usr/bin/id -un)" ]]; then
        /bin/echo "Login membership:     check from a new login as $target_user."
    elif active_member; then
        /bin/echo "Login membership:     $group_name is active for $target_user."
    else
        /bin/echo "Login membership:     $group_name is not active for $target_user."
    fi
}

if [[ "$mode" == "check" ]]; then
    show_status
    if directory_member && active_member; then
        exit 0
    fi
    exit 1
fi

if [[ "$mode" == "uninstall" ]]; then
    if directory_member; then
        /usr/bin/sudo /usr/sbin/dseditgroup -o edit -d "$target_user" -t user "$group_name"
        /bin/echo "Removed $target_user from $group_name."
        /bin/echo "Sign out and back in (or reboot) to remove it from new processes."
    else
        /bin/echo "$target_user is already absent from $group_name; nothing changed."
    fi
    exit 0
fi

if directory_member; then
    /bin/echo "$target_user is already a member of $group_name; nothing changed."
else
    /bin/echo "This grants $target_user read access to macOS raw disk devices."
    /usr/bin/sudo /usr/sbin/dseditgroup -o edit -a "$target_user" -t user "$group_name"
    if ! directory_member; then
        /bin/echo "Could not verify $target_user membership in $group_name." >&2
        exit 1
    fi
    /bin/echo "Added $target_user to $group_name."
fi

if active_member; then
    /bin/echo "Raw-disc access is active for new RIPT/Discbot processes."
else
    /bin/echo "Sign out and back in (or reboot) before running RIPT/Discbot."
fi
