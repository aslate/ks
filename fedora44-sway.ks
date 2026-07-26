# Kickstart file for Fedora 44, UEFI, Sway Wayland desktop environment.
# Fully automated installation with Cloudflare Secure DNS, Avahi disabled, Kernel Debugging/Tracing/Coredumps/Mounts disabled, UK/GB locale, and Greetd/Sway UI auto-boot.

%pre --interpreter=/bin/bash
set -Eeuo pipefail

# Fail closed unless the expected target disk and preserved partitions exist.
for required_device in /dev/sda /dev/sda1 /dev/sda3 /dev/sda5; do
    if [ ! -b "$required_device" ]; then
        echo "ERROR: Required target device $required_device does not exist." >&2
        exit 1
    fi
done

# Never wipe the disk that backs local installation media.
install_source=$(findmnt -nro SOURCE /run/install/repo 2>/dev/null || true)
case "$install_source" in
    /dev/sda|/dev/sda[0-9]*)
        echo "ERROR: /dev/sda appears to contain the installation source." >&2
        exit 1
        ;;
esac

# Close any open LUKS mapping on sda5 if active
for dev in /dev/mapper/*; do
    [ -e "$dev" ] || continue
    if cryptsetup status "$dev" 2>/dev/null | grep -q "/dev/sda5"; then
        cryptsetup close "$dev"
    fi
done

# Wipe pre-existing filesystem, LVM, or LUKS signatures on the validated target.
wipefs -a -f /dev/sda5
udevadm settle
%end

text
url --url="https://download.fedoraproject.org/pub/fedora/linux/releases/44/Everything/x86_64/os/"
repo --name=fedora-updates --baseurl=https://download.fedoraproject.org/pub/fedora/linux/updates/44/Everything/x86_64/ --install
firstboot --disable
eula --agreed
reboot

lang en_GB.UTF-8
keyboard --vckeymap=gb --xlayouts='gb'
timezone Europe/London --utc

network --bootproto=dhcp --device=link --activate --hostname=fedora-sway --noipv6
firewall --enabled
selinux --enforcing

rootpw --lock
user --name=changeme --lock --groups=wheel --shell=/bin/bash

# Disk partitioning information
ignoredisk --only-use=sda
zerombr
clearpart --none

# EFI ESP partition on sda1 (preserved)
part /boot/efi --fstype="efi" --onpart=/dev/sda1 --noformat

# /boot partition on sda3
part /boot --fstype="ext4" --onpart=/dev/sda3

# Encrypted partition on sda5 (re-formatted and re-encrypted)
part btrfs.01 --fstype="btrfs" --encrypted --luks-version=luks2 --pbkdf=argon2id --cipher=aes-xts-plain64 --passphrase=changeme_luks --onpart=/dev/sda5

# Main Btrfs volume container
btrfs none --label=fedora btrfs.01

# Btrfs subvolumes
btrfs / --subvol --name=@ fedora
btrfs /home --subvol --name=@home fedora
btrfs /var --subvol --name=@var fedora
btrfs /tmp --subvol --name=@tmp fedora
btrfs /.snapshots --subvol --name=@snapshots fedora

# Limit kernel command-line hardening to settings that apply during early boot.
bootloader --append="ipv6.disable=1 crashkernel=no quiet loglevel=3 rd.systemd.debug_shell=0"

# System services
services --enabled=NetworkManager,firewalld,systemd-resolved,greetd --disabled=avahi-daemon,avahi-daemon.socket,kdump,abrtd,abrt-ccpp,abrt-oops,brltty,brltty-udev,sys-kernel-debug.mount,sys-kernel-tracing.mount

%packages --excludedocs --inst-langs=en_GB.UTF-8
@core
glibc-langpack-en

# Core Sway & Wayland Display Environment & Greeter
sway
swaybg
swaylock
swayidle
waybar
mako
rofi
brightnessctl
greetd
tuigreet

# Screenshots & Clipboard Utilities
grim
slurp
wl-clipboard

# System Essentials, Networking, Audio & DNS
NetworkManager
network-manager-applet
systemd-resolved
pipewire
pipewire-pulseaudio
wireplumber
bash-completion
ca-certificates
cryptsetup
curl
git
gparted
nodejs24-bin
nodejs24-npm-bin
polkit
pykickstart
xdg-utils
lxqt-policykit

# Wayland Integration & Portals
xdg-desktop-portal
xdg-desktop-portal-wlr
xdg-desktop-portal-gtk

# Applications & Editors
firefox
chromium
Thunar
foot
vim
nano

# Exclude Braille support, TTS & unwanted components
-brltty
-espeak-ng
-speech-dispatcher
-orca
-kexec-tools
-abrt
-abrt-cli
-abrt-addon-kerneloops
-abrt-addon-ccpp
-evolution
-thunderbird
%end

%post --erroronfail --log=/root/kickstart-post.log
set -Eeuo pipefail

# Ensure the temporary standard user owns the home directory before creating user files.
chown -R changeme:changeme /home/changeme

# Match the installer operator's Git identity for the installed user.
cat << 'EOF' > /home/changeme/.gitconfig
[user]
	email = 4slate@gmail.com
	name = 4slate
EOF
chmod 0600 /home/changeme/.gitconfig
chown changeme:changeme /home/changeme/.gitconfig

# Enable Vim syntax highlighting and filetype-aware plugins and indentation.
cat << 'EOF' > /home/changeme/.vimrc
if has('syntax')
    syntax enable
endif
filetype plugin indent on
EOF
chmod 0644 /home/changeme/.vimrc
chown changeme:changeme /home/changeme/.vimrc

# Require offline rotation of the installation credentials before networking can
# start on the first installed boot. Greetd remains independent on TTY1.
install -d -m 0755 /usr/local/sbin
cat << 'EOF' > /usr/local/sbin/firstboot-credential-rotation
#!/usr/bin/bash
set -euo pipefail

readonly marker=/var/lib/firstboot-credential-rotation.complete
readonly old_user=changeme
readonly state_dir=/var/lib/firstboot-credential-rotation
readonly new_user_file="$state_dir/new-username"
readonly luks_marker="$state_dir/luks.complete"
readonly account_marker="$state_dir/account-rename.complete"

if [[ -e "$marker" ]]; then
    exit 0
fi

install -d -o root -g root -m 0700 "$state_dir"

clear
printf '%s\n' \
    "Initial security setup" \
    "Networking will remain disabled until this completes." \
    ""

if [[ -e "$new_user_file" ]]; then
    IFS= read -r new_user < "$new_user_file"

    if [[ ! "$new_user" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        echo "Persisted username is invalid; refusing to continue." >&2
        exit 1
    fi
else
    while :; do
        read -r -p "New username: " new_user

        if [[ "$new_user" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
            break
        fi

        echo "Enter a valid lowercase Linux username."
    done

    tmp=$(mktemp "$state_dir/.new-username.XXXXXX")
    trap '[[ -z "${tmp:-}" ]] || rm -f "$tmp"' EXIT
    printf '%s\n' "$new_user" > "$tmp"
    chmod 0600 "$tmp"
    chown root:root "$tmp"
    mv "$tmp" "$new_user_file"
    tmp=
    sync
fi

if [[ ! -e "$luks_marker" ]]; then
    root_source=$(findmnt -nro SOURCE /)
    root_mapper=$(printf '%s\n' "$root_source" | sed 's/\[.*$//')
    luks_device=$(cryptsetup status "$root_mapper" |
        awk '$1 == "device:" { print $2; exit }')

    if [[ -z "$luks_device" ]] || ! cryptsetup isLuks "$luks_device"; then
        echo "Unable to resolve the LUKS device backing /." >&2
        exit 1
    fi

    printf '\nChange the temporary LUKS passphrase for %s.\n' "$luks_device"
    cryptsetup luksChangeKey "$luks_device"

    touch "$luks_marker"
    chmod 0600 "$luks_marker"
    sync
fi

if [[ ! -e "$account_marker" ]]; then
    if [[ "$new_user" == "$old_user" ]]; then
        if ! id "$old_user" >/dev/null 2>&1; then
            echo "Expected initial user '$old_user' does not exist." >&2
            exit 1
        fi
    elif id "$old_user" >/dev/null 2>&1; then
        if id "$new_user" >/dev/null 2>&1; then
            echo "Both '$old_user' and '$new_user' exist; refusing to rename." >&2
            exit 1
        fi

        if getent group "$old_user" >/dev/null &&
            getent group "$new_user" >/dev/null; then
            echo "Both '$old_user' and '$new_user' groups exist; refusing to rename." >&2
            exit 1
        fi

        usermod \
            --login "$new_user" \
            --home "/home/$new_user" \
            --move-home \
            "$old_user"
    elif ! id "$new_user" >/dev/null 2>&1; then
        echo "Neither '$old_user' nor '$new_user' exists." >&2
        exit 1
    fi

    if [[ "$new_user" != "$old_user" ]] &&
        getent group "$old_user" >/dev/null; then
        if getent group "$new_user" >/dev/null; then
            echo "Both '$old_user' and '$new_user' groups exist; refusing to rename." >&2
            exit 1
        fi

        groupmod --new-name "$new_user" "$old_user"
    fi

    touch "$account_marker"
    chmod 0600 "$account_marker"
    sync
fi

passwd "$new_user"

touch "$marker"
chmod 0600 "$marker"

sync

printf '\nCredential rotation completed successfully.\n'
EOF
chmod 0700 /usr/local/sbin/firstboot-credential-rotation
chown root:root /usr/local/sbin/firstboot-credential-rotation

cat << 'EOF' > /usr/local/sbin/cleanup-firstboot-credential-rotation
#!/usr/bin/bash
set -euo pipefail

readonly marker=/var/lib/firstboot-credential-rotation.complete
readonly unit=firstboot-credential-rotation.service

[[ -e "$marker" ]] || {
    echo "Refusing cleanup: completion marker is absent." >&2
    exit 1
}

systemctl disable "$unit"

rm -f /etc/systemd/system/NetworkManager.service.d/10-firstboot-gate.conf

systemctl daemon-reload

/usr/bin/chvt 1 || true
EOF
chmod 0700 /usr/local/sbin/cleanup-firstboot-credential-rotation
chown root:root /usr/local/sbin/cleanup-firstboot-credential-rotation

cat << 'EOF' > /etc/systemd/system/firstboot-credential-rotation.service
[Unit]
Description=Mandatory first-boot credential rotation
ConditionPathExists=!/var/lib/firstboot-credential-rotation.complete

After=local-fs.target systemd-remount-fs.service
Wants=local-fs.target

Before=network-pre.target network.target
Before=NetworkManager.service NetworkManager-wait-online.service

Conflicts=getty@tty2.service

[Service]
Type=oneshot
ExecStartPre=/usr/bin/chvt 2
ExecStart=/usr/local/sbin/firstboot-credential-rotation
ExecStartPost=/usr/local/sbin/cleanup-firstboot-credential-rotation

StandardInput=tty
StandardOutput=tty
StandardError=tty
TTYPath=/dev/tty2
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes

RemainAfterExit=yes

[Install]
WantedBy=network-pre.target
EOF
chmod 0644 /etc/systemd/system/firstboot-credential-rotation.service
chown root:root /etc/systemd/system/firstboot-credential-rotation.service

install -d -m 0755 /etc/systemd/system/NetworkManager.service.d
cat << 'EOF' > /etc/systemd/system/NetworkManager.service.d/10-firstboot-gate.conf
[Unit]
Requires=firstboot-credential-rotation.service
After=firstboot-credential-rotation.service
EOF
chmod 0644 /etc/systemd/system/NetworkManager.service.d/10-firstboot-gate.conf
chown root:root /etc/systemd/system/NetworkManager.service.d/10-firstboot-gate.conf

test -x /usr/bin/chvt
systemd-analyze verify \
    /etc/systemd/system/firstboot-credential-rotation.service \
    /usr/lib/systemd/system/NetworkManager.service \
    /usr/lib/systemd/system/greetd.service

# Install Codex for the renamed user on the first graphical login with network access.
install -d -o changeme -g changeme -m 0700 \
    /home/changeme/.local/bin \
    /home/changeme/.local/libexec \
    /home/changeme/.local/state
cat << 'EOF' > /home/changeme/.local/libexec/install-codex-cli
#!/usr/bin/env bash
set -Eeuo pipefail

readonly installer_url=https://chatgpt.com/codex/install.sh
readonly lock_file="$HOME/.local/state/codex-install.lock"

if command -v codex >/dev/null 2>&1; then
    exit 0
fi

exec 9>"$lock_file"
if ! /usr/bin/flock -n 9; then
    exit 0
fi

# Another login may have completed the installation while this process waited.
if command -v codex >/dev/null 2>&1; then
    exit 0
fi

installer=$(/usr/bin/mktemp --tmpdir codex-install.XXXXXX)
trap '/usr/bin/rm -f "$installer"' EXIT

echo "Downloading the Codex CLI installer..."
/usr/bin/curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --retry 5 \
    --retry-all-errors \
    --connect-timeout 10 \
    --max-time 120 \
    "$installer_url" \
    --output "$installer"

echo "Installing Codex CLI..."
CODEX_NON_INTERACTIVE=1 /usr/bin/sh "$installer"

if ! command -v codex >/dev/null 2>&1; then
    echo "Codex installer completed, but codex is not available on PATH." >&2
    exit 1
fi

codex --version
EOF
chmod 0700 /home/changeme/.local/libexec/install-codex-cli
chown -R changeme:changeme /home/changeme/.local

# Configure UK/GB locale and keyboard layout system-wide
cat << 'EOF' > /etc/locale.conf
LANG=en_GB.UTF-8
LC_ALL=en_GB.UTF-8
EOF

cat << 'EOF' > /etc/vconsole.conf
KEYMAP=gb
EOF

# Global Sway input configuration for UK keyboard layout
mkdir -p /etc/sway/config.d
cat << 'EOF' > /etc/sway/config.d/input.conf
input * {
    xkb_layout "gb"
}
EOF

# Make the user's local binaries available and install Codex in the background
# on login so a slow or unavailable network does not block the Sway session.
install -d -m 0755 /usr/local/libexec
cat << 'EOF' > /usr/local/libexec/start-sway
#!/bin/sh
PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin"
export PATH
"$HOME/.local/libexec/install-codex-cli" \
    >>"$HOME/.local/state/codex-install.log" 2>&1 &
exec /usr/bin/sway
EOF
chmod 0755 /usr/local/libexec/start-sway
chown root:root /usr/local/libexec/start-sway

# Configure graphical boot and require an authenticated greetd login into Sway.
systemctl set-default graphical.target

install -d -m 0755 /etc/greetd
cat << 'EOF' > /etc/greetd/config.toml
[terminal]
vt = 1

[default_session]
command = "tuigreet --time --cmd /usr/local/libexec/start-sway"
user = "greeter"
EOF
chmod 0644 /etc/greetd/config.toml
chown root:root /etc/greetd/config.toml

systemctl enable firstboot-credential-rotation.service
systemctl enable greetd.service

# Pre-create Sway configuration directory for the temporary user.
mkdir -p /home/changeme/.config/sway
if [ -f /etc/sway/config ]; then
    cp /etc/sway/config /home/changeme/.config/sway/config
fi
chown -R changeme:changeme /home/changeme/.config

# Mask and disable Brltty & AT-SPI Accessibility services globally
systemctl mask brltty.service brltty-udev.service 2>/dev/null || true
systemctl disable brltty.service brltty-udev.service 2>/dev/null || true

# Mask systemd user services for AT-SPI bus and registry
mkdir -p /etc/systemd/user
ln -sf /dev/null /etc/systemd/user/at-spi-dbus-bus.service
ln -sf /dev/null /etc/systemd/user/at-spi2-registryd.service
systemctl --global mask at-spi-dbus-bus.service at-spi2-registryd.service 2>/dev/null || true

# Disable and mask PipeWire and WirePlumber user services globally
ln -sf /dev/null /etc/systemd/user/pipewire.service
ln -sf /dev/null /etc/systemd/user/pipewire.socket
ln -sf /dev/null /etc/systemd/user/pipewire-pulse.service
ln -sf /dev/null /etc/systemd/user/pipewire-pulse.socket
ln -sf /dev/null /etc/systemd/user/wireplumber.service
systemctl --global disable pipewire.service pipewire.socket pipewire-pulse.service pipewire-pulse.socket wireplumber.service 2>/dev/null || true
systemctl --global mask pipewire.service pipewire.socket pipewire-pulse.service pipewire-pulse.socket wireplumber.service 2>/dev/null || true

# Mask DBus auto-activation for AT-SPI accessibility bus
mkdir -p /etc/dbus-1/services
ln -sf /dev/null /etc/dbus-1/services/org.a11y.Bus.service 2>/dev/null || true
ln -sf /dev/null /etc/dbus-1/services/org.a11y.atspi.Registry.service 2>/dev/null || true

# Disable GTK, Qt, and AT-SPI accessibility bridge globally
cat << 'EOF' > /etc/profile.d/disable-accessibility.sh
export NO_AT_BRIDGE=1
export QT_ACCESSIBILITY=0
export GTK_A11Y=none
EOF
chmod +x /etc/profile.d/disable-accessibility.sh

# Mask and disable Avahi mDNS services persistently
systemctl mask avahi-daemon.service avahi-daemon.socket 2>/dev/null || true
systemctl disable avahi-daemon.service avahi-daemon.socket 2>/dev/null || true

# Disable Precision Time Protocol synchronization without disabling Ethernet.
systemctl mask ptp4l.service ptp4l@.service phc2sys.service phc2sys@.service timemaster.service 2>/dev/null || true
cat > /etc/udev/rules.d/99-z-disable-ptp.rules <<'UDEV'
# Keep the Ethernet interface, but deny access to its PTP hardware clock and
# prevent systemd from generating a .device unit for it.
SUBSYSTEM=="ptp", MODE="0000", TAG-="systemd"
UDEV

# Disable binfmt_misc activation and prevent the Intel SPI flash devices from appearing.
systemctl mask proc-sys-fs-binfmt_misc.automount systemd-binfmt.service 2>/dev/null || true
cat > /etc/modprobe.d/disable-intel-spi.conf <<'MODPROBE'
blacklist intel_spi_pci
blacklist intel_spi_platform
install intel_spi_pci /bin/false
install intel_spi_platform /bin/false
MODPROBE

# Use systemd masks to disable services and debug, tracing, and configfs mounts.
systemctl mask kdump.service abrt-ccpp.service abrt-oops.service abrtd.service systemd-coredump.service systemd-coredump.socket systemd-debug-shell.service sys-kernel-debug.mount sys-kernel-tracing.mount sys-kernel-config.mount 2>/dev/null || true
systemctl disable kdump.service abrt-ccpp.service abrt-oops.service abrtd.service systemd-coredump.service systemd-coredump.socket sys-kernel-debug.mount sys-kernel-tracing.mount 2>/dev/null || true

# Disable core dumps through native systemd configuration and process limits.
mkdir -p /etc/systemd/coredump.conf.d
cat << 'EOF' > /etc/systemd/coredump.conf.d/disable-coredump.conf
[Coredump]
Storage=none
ProcessSizeMax=0
ExternalSizeMax=0
EOF

mkdir -p /etc/security/limits.d
cat << 'EOF' > /etc/security/limits.d/10-disable-coredumps.conf
* hard core 0
* soft core 0
EOF

cat << 'EOF' > /etc/profile.d/disable-coredumps.sh
ulimit -c 0
EOF
chmod +x /etc/profile.d/disable-coredumps.sh

# Disable IPv6 via sysctl persistently
cat << 'EOF' > /etc/sysctl.d/90-disable-ipv6.conf
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF

# Apply runtime kernel restrictions through sysctl.
cat << 'EOF' > /etc/sysctl.d/99-kernel-hardening.conf
kernel.sysrq = 0
kernel.core_pattern = /dev/null
fs.suid_dumpable = 0
kernel.dmesg_restrict = 1
kernel.ftrace_enabled = 0
kernel.kptr_restrict = 2
kernel.yama.ptrace_scope = 2
EOF

# Configure NetworkManager to use systemd-resolved and disable IPv6 connections by default
mkdir -p /etc/NetworkManager/conf.d
cat << 'EOF' > /etc/NetworkManager/conf.d/10-dns-resolved.conf
[main]
dns=systemd-resolved
EOF

cat << 'EOF' > /etc/NetworkManager/conf.d/90-disable-ipv6.conf
[connection]
ipv6.method=disabled
EOF

# Configure Cloudflare Secure DNS (DNS-over-TLS over IPv4) in systemd-resolved
mkdir -p /etc/systemd/resolved.conf.d
cat << 'EOF' > /etc/systemd/resolved.conf.d/cloudflare-dns-over-tls.conf
[Resolve]
DNS=1.1.1.1#cloudflare-dns.com 1.0.0.1#cloudflare-dns.com
FallbackDNS=1.1.1.1 1.0.0.1
DNSOverTLS=yes
DNSSEC=yes
MulticastDNS=no
LLMNR=no
EOF

# Enable systemd-resolved and link stub resolver to /etc/resolv.conf
systemctl enable systemd-resolved
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# Lockdown Firewalld: Set default zone to 'drop' with zero exposed services or ports
mkdir -p /etc/firewalld/zones
if [[ ! -f /etc/firewalld/firewalld.conf ]]; then
    echo "ERROR: Packaged /etc/firewalld/firewalld.conf is missing." >&2
    exit 1
fi

if grep -q '^DefaultZone=' /etc/firewalld/firewalld.conf; then
    sed -i 's/^DefaultZone=.*/DefaultZone=drop/' \
        /etc/firewalld/firewalld.conf
else
    printf '%s\n' 'DefaultZone=drop' \
        >> /etc/firewalld/firewalld.conf
fi

cat << 'EOF' > /etc/firewalld/zones/drop.xml
<?xml version="1.0" encoding="utf-8"?>
<zone target="DROP">
  <short>Drop</short>
  <description>Strict lockdown zone. All incoming traffic is dropped silently with zero exposed services or ports.</description>
</zone>
EOF

cat << 'EOF' > /etc/firewalld/zones/public.xml
<?xml version="1.0" encoding="utf-8"?>
<zone target="DROP">
  <short>Public</short>
  <description>Strict lockdown zone. All incoming traffic is dropped silently with zero exposed services or ports.</description>
</zone>
EOF

chmod 0644 \
    /etc/firewalld/firewalld.conf \
    /etc/firewalld/zones/drop.xml \
    /etc/firewalld/zones/public.xml
chown root:root \
    /etc/firewalld/firewalld.conf \
    /etc/firewalld/zones/drop.xml \
    /etc/firewalld/zones/public.xml
firewall-offline-cmd --check-config

systemd-sysusers

getent passwd greeter >/dev/null
test -x /usr/local/libexec/start-sway
command -v greetd >/dev/null
command -v tuigreet >/dev/null
command -v sway >/dev/null

grep -q '^\[terminal\]$' /etc/greetd/config.toml
grep -q '^vt = 1$' /etc/greetd/config.toml

systemctl is-enabled greetd.service >/dev/null

greetd_unit=$(systemctl show \
    --property=FragmentPath \
    --value \
    greetd.service)

if [[ -z "$greetd_unit" || ! -f "$greetd_unit" ]]; then
    echo "ERROR: Unable to locate greetd.service unit file." >&2
    exit 1
fi

systemd-analyze verify "$greetd_unit"

/usr/lib/systemd/systemd-sysctl --cat-config >/dev/null
test -f /etc/sysctl.d/99-kernel-hardening.conf
test -f /etc/systemd/coredump.conf.d/disable-coredump.conf
test -f /etc/security/limits.d/10-disable-coredumps.conf
%end
