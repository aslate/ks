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
user --name=aslate --lock --groups=wheel --shell=/bin/bash

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

# Bootloader settings: Disable IPv6, disable crashkernel (kdump), quiet loglevel, disable kernel debug/trace/debugfs
bootloader --append="ipv6.disable=1 crashkernel=no quiet loglevel=0 debug=0 debugfs=off systemd.coredump=0 kernel.ftrace_enabled=0 rd.systemd.debug_shell=0 ptrace_scope=2"

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
rofi-wayland
brightnessctl
greetd
greetd-tuigreet

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

# Ensure the standard user owns the home directory before creating user files.
chown -R aslate:aslate /home/aslate

# Match the installer operator's Git identity for the installed user.
cat << 'EOF' > /home/aslate/.gitconfig
[user]
	email = 4slate@gmail.com
	name = 4slate
EOF
chmod 0600 /home/aslate/.gitconfig
chown aslate:aslate /home/aslate/.gitconfig

# Require offline rotation of the installation credentials before networking or
# the graphical login can start on the first installed boot.
install -d -m 0755 /usr/local/sbin /var/lib/firstboot-setup
cat << 'EOF' > /usr/local/sbin/firstboot-credential-rotation
#!/usr/bin/env bash
set -Eeuo pipefail

completion_marker=/var/lib/firstboot-setup/credentials-rotated
if [ -e "$completion_marker" ]; then
    exit 0
fi

echo "======================================================="
echo " First boot: secure the installation credentials"
echo " Networking and graphical login are currently blocked."
echo "======================================================="
echo

echo "Set the password for user aslate."
until /usr/bin/passwd aslate; do
    echo "Password update failed; please try again."
done

root_source=$(/usr/bin/findmnt -nro SOURCE /)
root_mapper=$(printf '%s\n' "$root_source" | /usr/bin/sed 's/\[.*$//')
luks_device=$(/usr/bin/cryptsetup status "$root_mapper" |
    /usr/bin/awk '$1 == "device:" { print $2; exit }')

if [ -z "$luks_device" ] || ! /usr/bin/cryptsetup isLuks "$luks_device"; then
    echo "ERROR: Unable to resolve the LUKS device backing /." >&2
    exit 1
fi

echo
echo "Change the temporary LUKS passphrase for $luks_device."
until /usr/bin/cryptsetup luksChangeKey "$luks_device"; do
    echo "LUKS passphrase update failed; please try again."
done

/usr/bin/touch "$completion_marker"
/usr/bin/chmod 0600 "$completion_marker"
/usr/bin/rm -f /root/anaconda-ks.cfg /root/original-ks.cfg

echo
echo "Credential rotation completed. Networking and greetd may now start."
EOF
chmod 0700 /usr/local/sbin/firstboot-credential-rotation
chown root:root /usr/local/sbin/firstboot-credential-rotation

cat << 'EOF' > /etc/systemd/system/firstboot-credential-rotation.service
[Unit]
Description=Rotate installation credentials before networking and login
ConditionPathExists=!/var/lib/firstboot-setup/credentials-rotated
After=local-fs.target
Before=NetworkManager.service greetd.service
Conflicts=getty@tty1.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/firstboot-credential-rotation
StandardInput=tty-force
StandardOutput=tty
StandardError=tty
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes

[Install]
WantedBy=multi-user.target
EOF
chmod 0644 /etc/systemd/system/firstboot-credential-rotation.service
chown root:root /etc/systemd/system/firstboot-credential-rotation.service

install -d -m 0755 \
    /etc/systemd/system/NetworkManager.service.d \
    /etc/systemd/system/greetd.service.d
cat << 'EOF' > /etc/systemd/system/NetworkManager.service.d/10-firstboot-credentials.conf
[Unit]
Requires=firstboot-credential-rotation.service
After=firstboot-credential-rotation.service
EOF
cat << 'EOF' > /etc/systemd/system/greetd.service.d/10-firstboot-credentials.conf
[Unit]
Requires=firstboot-credential-rotation.service
After=firstboot-credential-rotation.service
EOF
chmod 0644 \
    /etc/systemd/system/NetworkManager.service.d/10-firstboot-credentials.conf \
    /etc/systemd/system/greetd.service.d/10-firstboot-credentials.conf
chown root:root \
    /etc/systemd/system/NetworkManager.service.d/10-firstboot-credentials.conf \
    /etc/systemd/system/greetd.service.d/10-firstboot-credentials.conf

# Install the pinned Codex CLI as aslate after networking is permitted. A timer
# avoids blocking boot and retries on later boots until installation succeeds.
install -d -o aslate -g aslate -m 0700 \
    /home/aslate/.cache/npm \
    /home/aslate/.local/bin \
    /home/aslate/.local/libexec \
    /home/aslate/.local/state
cat << 'EOF' > /home/aslate/.local/libexec/install-codex-cli
#!/usr/bin/env bash
set -uo pipefail

readonly codex_version=0.145.0
readonly codex_bin=/home/aslate/.local/bin/codex
readonly completion_marker=/home/aslate/.local/state/codex-0.145.0-installed

if [ -x "$codex_bin" ] &&
    [ "$("$codex_bin" --version 2>/dev/null | /usr/bin/awk '{print $NF}')" = "$codex_version" ]; then
    /usr/bin/touch "$completion_marker"
    exit 0
fi

for attempt in 1 2 3; do
    echo "Installing Codex CLI ${codex_version} as aslate (attempt ${attempt} of 3)..."
    if /usr/bin/timeout 300 /usr/bin/npm install --global \
        --prefix /home/aslate/.local --no-fund "@openai/codex@${codex_version}"; then
        if [ -x "$codex_bin" ] &&
            [ "$("$codex_bin" --version 2>/dev/null | /usr/bin/awk '{print $NF}')" = "$codex_version" ]; then
            /usr/bin/touch "$completion_marker"
            exit 0
        fi
        echo "npm completed but the expected Codex version was not installed." >&2
    else
        echo "Codex CLI installation attempt ${attempt} failed." >&2
    fi

    if [ "$attempt" -lt 3 ]; then
        /usr/bin/sleep 5
    fi
done

echo "Codex CLI was not installed; the timer will retry on the next boot." >&2
exit 1
EOF
chmod 0700 /home/aslate/.local/libexec/install-codex-cli
chown -R aslate:aslate /home/aslate/.cache /home/aslate/.local

cat << 'EOF' > /etc/systemd/system/codex-user-install.service
[Unit]
Description=Install pinned Codex CLI for aslate
Requires=firstboot-credential-rotation.service
After=firstboot-credential-rotation.service network-online.target
Wants=network-online.target
ConditionPathExists=!/home/aslate/.local/state/codex-0.145.0-installed

[Service]
Type=oneshot
User=aslate
Group=aslate
Environment=HOME=/home/aslate
Environment=NPM_CONFIG_CACHE=/home/aslate/.cache/npm
ExecStart=/home/aslate/.local/libexec/install-codex-cli
UMask=0077
NoNewPrivileges=yes
CapabilityBoundingSet=
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/home/aslate/.cache/npm /home/aslate/.local
ProtectControlGroups=yes
ProtectKernelModules=yes
ProtectKernelTunables=yes
RestrictSUIDSGID=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
EOF

cat << 'EOF' > /etc/systemd/system/codex-user-install.timer
[Unit]
Description=Attempt pinned Codex CLI installation after boot

[Timer]
OnBootSec=60
Unit=codex-user-install.service

[Install]
WantedBy=timers.target
EOF
chmod 0644 \
    /etc/systemd/system/codex-user-install.service \
    /etc/systemd/system/codex-user-install.timer
chown root:root \
    /etc/systemd/system/codex-user-install.service \
    /etc/systemd/system/codex-user-install.timer

# Configure UK/GB locale and keyboard layout system-wide
cat << 'EOF' > /etc/locale.conf
LANG=en_GB.UTF-8
LC_ALL=en_GB.UTF-8
EOF

cat << 'EOF' > /etc/vconsole.conf
KEYMAP=gb
FONT=latarcyrheb-sun16
EOF

# Global Sway input configuration for UK keyboard layout
mkdir -p /etc/sway/config.d
cat << 'EOF' > /etc/sway/config.d/input.conf
input * {
    xkb_layout "gb"
}
EOF

# Make the user's local npm binaries available to Sway and all descendants.
install -d -m 0755 /usr/local/libexec
cat << 'EOF' > /usr/local/libexec/start-sway
#!/bin/sh
PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin"
export PATH
exec /usr/bin/sway
EOF
chmod 0755 /usr/local/libexec/start-sway
chown root:root /usr/local/libexec/start-sway

# Configure graphical boot and require an authenticated greetd login into Sway.
systemctl set-default graphical.target

install -d -m 0755 /etc/greetd
cat << 'EOF' > /etc/greetd/config.toml
[default_session]
command = "tuigreet --time --cmd /usr/local/libexec/start-sway"
user = "greeter"
EOF
chmod 0644 /etc/greetd/config.toml
chown root:root /etc/greetd/config.toml

systemctl enable firstboot-credential-rotation.service
systemctl enable codex-user-install.timer
systemctl enable greetd.service

# Pre-create Sway configuration directory for user aslate
mkdir -p /home/aslate/.config/sway
if [ -f /etc/sway/config ]; then
    cp /etc/sway/config /home/aslate/.config/sway/config
fi
chown -R aslate:aslate /home/aslate/.config

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

# Mask and disable kdump, systemd-coredump, ABRT services, and kernel feature mounts
systemctl mask kdump.service abrt-ccpp.service abrt-oops.service abrtd.service systemd-coredump.service systemd-coredump.socket systemd-debug-shell.service sys-kernel-debug.mount sys-kernel-tracing.mount sys-kernel-config.mount 2>/dev/null || true
systemctl disable kdump.service abrt-ccpp.service abrt-oops.service abrtd.service systemd-coredump.service systemd-coredump.socket sys-kernel-debug.mount sys-kernel-tracing.mount 2>/dev/null || true

# Disable systemd coredump storage completely
mkdir -p /etc/systemd/coredump.conf.d
cat << 'EOF' > /etc/systemd/coredump.conf.d/disable-coredump.conf
[Coredump]
Storage=none
ProcessSizeMax=0
ExternalSizeMax=0
EOF

# Set core dump process limits to zero globally
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

# Disable kernel sysrq, core dumps, ftrace, ptrace, and restrict dmesg in sysctl
cat << 'EOF' > /etc/sysctl.d/99-disable-debug-coredump.conf
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
if [ -f /etc/firewalld/firewalld.conf ]; then
    sed -i 's/^DefaultZone=.*/DefaultZone=drop/' /etc/firewalld/firewalld.conf
    if ! grep -q '^DefaultZone=drop$' /etc/firewalld/firewalld.conf; then
        printf '%s\n' 'DefaultZone=drop' >> /etc/firewalld/firewalld.conf
    fi
else
    cat << 'EOF' > /etc/firewalld/firewalld.conf
DefaultZone=drop
CleanupOnExit=yes
Lockdown=no
EOF
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
%end
