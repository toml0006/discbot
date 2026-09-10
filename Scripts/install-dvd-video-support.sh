#!/bin/bash

set -euo pipefail

libdvdcss_version="1.4.3"
libdvdread_version="5.0.3"
dvdbackup_version="0.4.2"

libdvdcss_sha256="233cc92f5dc01c5d3a96f5b3582be7d5cee5a35a52d3a08158745d3d86070079"
libdvdread_sha256="321cdf2dbdc83c96572bc583cd27d8c660ddb540ff16672ecb28607d018ed82b"
dvdbackup_sha256="ef8c56fbb82b15b7eef00d2d3118c8253f9770009ed7bb2a5d4849acf88183e6"

install_root="$HOME/Library/Application Support/Discbot/DVDTools"
mode="install"

usage() {
    /bin/cat <<'EOF'
Usage: install-dvd-video-support.sh [--check | --uninstall]

Builds the GPL-licensed libdvdcss/libdvdread/dvdbackup tools in the current
user's Discbot application-support folder. No root access is required and no
system files are changed. These tools let Discbot create playable ISO images
from CSS-protected DVD-Video discs that Apple's hdiutil cannot read.
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

dvdbackup_path="$install_root/bin/dvdbackup"

if [[ "$mode" == "check" ]]; then
    if [[ -x "$dvdbackup_path" ]]; then
        "$dvdbackup_path" --version 2>&1 | /usr/bin/head -n 1
        /bin/echo "DVD-Video support is installed at $install_root."
        exit 0
    fi
    /bin/echo "DVD-Video support is not installed." >&2
    exit 1
fi

if [[ "$mode" == "uninstall" ]]; then
    if [[ ! -e "$install_root" ]]; then
        /bin/echo "DVD-Video support is already absent."
        exit 0
    fi
    trash_root="$HOME/.Trash"
    timestamp=$(/bin/date +%Y%m%d-%H%M%S)
    destination="$trash_root/Discbot-DVDTools-$timestamp"
    /bin/mkdir -p "$trash_root"
    /bin/mv "$install_root" "$destination"
    /bin/echo "Moved DVD-Video support to $destination."
    exit 0
fi

for tool in /usr/bin/cc /usr/bin/make /usr/bin/curl /usr/bin/shasum /usr/bin/tar; do
    if [[ ! -x "$tool" ]]; then
        /bin/echo "Required build tool is missing: $tool" >&2
        exit 1
    fi
done

build_root=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/discbot-dvdtools.XXXXXX")
downloads="$build_root/downloads"
stage="$build_root/stage"
/bin/mkdir -p "$downloads" "$stage"

download_and_verify() {
    local url="$1"
    local destination="$2"
    local expected="$3"
    /usr/bin/curl -fL --retry 3 --connect-timeout 20 "$url" -o "$destination"
    local actual
    actual=$(/usr/bin/shasum -a 256 "$destination" | /usr/bin/awk '{print $1}')
    if [[ "$actual" != "$expected" ]]; then
        /bin/echo "Checksum mismatch for $url" >&2
        /bin/echo "Expected $expected but received $actual" >&2
        exit 1
    fi
}

download_and_verify \
    "https://download.videolan.org/pub/libdvdcss/$libdvdcss_version/libdvdcss-$libdvdcss_version.tar.bz2" \
    "$downloads/libdvdcss.tar.bz2" \
    "$libdvdcss_sha256"
download_and_verify \
    "https://download.videolan.org/videolan/libdvdread/$libdvdread_version/libdvdread-$libdvdread_version.tar.bz2" \
    "$downloads/libdvdread.tar.bz2" \
    "$libdvdread_sha256"
download_and_verify \
    "https://downloads.sourceforge.net/project/dvdbackup/dvdbackup/dvdbackup-$dvdbackup_version/dvdbackup-$dvdbackup_version.tar.xz" \
    "$downloads/dvdbackup.tar.xz" \
    "$dvdbackup_sha256"

/usr/bin/tar -xjf "$downloads/libdvdcss.tar.bz2" -C "$build_root"
/usr/bin/tar -xjf "$downloads/libdvdread.tar.bz2" -C "$build_root"
/usr/bin/tar -xJf "$downloads/dvdbackup.tar.xz" -C "$build_root"

jobs=$(/usr/sbin/sysctl -n hw.logicalcpu 2>/dev/null || /bin/echo 2)

(
    cd "$build_root/libdvdcss-$libdvdcss_version"
    ./configure --prefix="$stage" --disable-dependency-tracking
    /usr/bin/make -j"$jobs"
    /usr/bin/make install
)

(
    cd "$build_root/libdvdread-$libdvdread_version"
    CPPFLAGS="-I$stage/include" \
    LDFLAGS="-L$stage/lib" \
    ./configure \
        --prefix="$stage" \
        --disable-dependency-tracking \
        --with-libdvdcss \
        CSS_CFLAGS="-I$stage/include" \
        CSS_LIBS="-L$stage/lib -ldvdcss"
    /usr/bin/make -j"$jobs"
    /usr/bin/make install
)

(
    cd "$build_root/dvdbackup-$dvdbackup_version"
    CPPFLAGS="-I$stage/include" \
    LDFLAGS="-L$stage/lib" \
    ./configure --prefix="$stage"
    /usr/bin/make -j"$jobs"
    /usr/bin/make install
)

# Autotools records the staging prefix in Mach-O install names. Replace those
# temporary paths before publishing so the helper remains runnable after the
# build directory is removed (and without relying on DYLD_* environment state).
css_library=$(/usr/bin/find "$stage/lib" -type f -name 'libdvdcss.*.dylib' | /usr/bin/head -n 1)
read_library=$(/usr/bin/find "$stage/lib" -type f -name 'libdvdread.*.dylib' | /usr/bin/head -n 1)
if [[ -z "$css_library" || -z "$read_library" || ! -x "$stage/bin/dvdbackup" ]]; then
    /bin/echo "Expected DVD helper libraries were not produced." >&2
    exit 1
fi

css_destination="$install_root/lib/$(/usr/bin/basename "$css_library")"
read_destination="$install_root/lib/$(/usr/bin/basename "$read_library")"
/usr/bin/install_name_tool -id "$css_destination" "$css_library"
/usr/bin/install_name_tool -id "$read_destination" "$read_library"

old_css=$(/usr/bin/otool -L "$read_library" | /usr/bin/awk '/libdvdcss.*dylib/ { print $1; exit }')
if [[ -n "$old_css" ]]; then
    /usr/bin/install_name_tool -change "$old_css" "$css_destination" "$read_library"
fi

old_read=$(/usr/bin/otool -L "$stage/bin/dvdbackup" | /usr/bin/awk '/libdvdread.*dylib/ { print $1; exit }')
if [[ -n "$old_read" ]]; then
    /usr/bin/install_name_tool -change "$old_read" "$read_destination" "$stage/bin/dvdbackup"
fi
old_css=$(/usr/bin/otool -L "$stage/bin/dvdbackup" | /usr/bin/awk '/libdvdcss.*dylib/ { print $1; exit }')
if [[ -n "$old_css" ]]; then
    /usr/bin/install_name_tool -change "$old_css" "$css_destination" "$stage/bin/dvdbackup"
fi

# Publish as one rename so the app never observes a half-installed toolchain.
publish_root="$build_root/DVDTools"
/bin/mv "$stage" "$publish_root"
/bin/mkdir -p "$(/usr/bin/dirname "$install_root")"
if [[ -e "$install_root" ]]; then
    previous="$build_root/DVDTools.previous"
    /bin/mv "$install_root" "$previous"
fi
/bin/mv "$publish_root" "$install_root"

if [[ ! -x "$dvdbackup_path" ]]; then
    /bin/echo "The DVD-Video helper did not install correctly." >&2
    exit 1
fi

"$dvdbackup_path" --version 2>&1 | /usr/bin/head -n 1
/bin/echo "DVD-Video support installed at $install_root."
/bin/echo "Restart Discbot before starting the next DVD batch."
