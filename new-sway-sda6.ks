# Kickstart file for Fedora 44, UEFI, Sway Wayland desktop environment.
# Fully automated installation with Cloudflare Secure DNS, Avahi disabled, Kernel Debugging/Tracing/Coredumps/Mounts disabled, UK/GB locale, and Greetd/Sway UI auto-boot.

%pre --interpreter=/bin/bash
set -Eeuo pipefail

# Fail closed unless the expected target disk and preserved partitions exist.
for required_device in /dev/sda /dev/sda1 /dev/sda3 /dev/sda6; do
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

# Close any open LUKS mapping on sda6 if active
for dev in /dev/mapper/*; do
    [ -e "$dev" ] || continue
    if cryptsetup status "$dev" 2>/dev/null | grep -q "/dev/sda6"; then
        cryptsetup close "$dev"
    fi
done

# Wipe pre-existing filesystem, LVM, or LUKS signatures on the validated target.
wipefs -a -f /dev/sda6
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
user --name=aslate --password=$6$ZFJZ6ivj7cyevNhI$wSm8TVuOOEE5rhVI1TtL3WMXrZJDXGIb42BLMw2pLcz1S5muUEGDcRpkBSuIGqMAGRHmziPeAVZmvDf4Ggp7a. --iscrypted --groups=wheel --shell=/bin/bash

# Disk partitioning information
ignoredisk --only-use=sda
zerombr
clearpart --none

# EFI ESP partition on sda1 (preserved)
part /boot/efi --fstype="efi" --onpart=/dev/sda1 --noformat

# /boot partition on sda3
part /boot --fstype="ext4" --onpart=/dev/sda3 --noformat

# Encrypted partition on sda6 (re-formatted and re-encrypted)
part btrfs.01 --fstype="btrfs" --encrypted --luks-version=luks2 --pbkdf=argon2id --cipher=aes-xts-plain64 --passphrase=changeme_luks --onpart=/dev/sda6

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
sway-config-minimal
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
systemd-resolved
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

# Enable Vim syntax highlighting and filetype-aware plugins and indentation.
cat << 'EOF' > /home/aslate/.vimrc
if has('syntax')
    syntax enable
endif
filetype plugin indent on
EOF
chmod 0644 /home/aslate/.vimrc
chown aslate:aslate /home/aslate/.vimrc

# Install Codex for the user on the first graphical login with network access.
install -d -o aslate -g aslate -m 0700 \
    /home/aslate/.local/bin \
    /home/aslate/.local/libexec \
    /home/aslate/.local/state
cat << 'EOF' > /home/aslate/.local/libexec/install-codex-cli
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
chmod 0700 /home/aslate/.local/libexec/install-codex-cli
chown -R aslate:aslate /home/aslate/.local

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

systemctl enable greetd.service

# Pre-create the user's Sway configuration directory.
mkdir -p /home/aslate/.config/sway
if [ -f /etc/sway/config ]; then
    cp /etc/sway/config /home/aslate/.config/sway/config
fi
chown -R aslate:aslate /home/aslate/.config

# Disable and mask Brltty services. Missing units are expected and must not
# fail the installation.
systemctl disable brltty.service brltty-udev.service || true
systemctl mask brltty.service brltty-udev.service || true

# Disable and mask systemd user services for the AT-SPI bus and registry.
# Missing units are expected and must not fail the installation.
systemctl disable at-spi-dbus-bus.service at-spi2-registryd.service || true
systemctl mask at-spi-dbus-bus.service at-spi2-registryd.service || true

# Disable and mask PipeWire and WirePlumber globally, including socket
# activation. Missing units are expected and must not fail the installation.
systemctl disable pipewire.service pipewire.socket pipewire-pulse.service pipewire-pulse.socket wireplumber.service || true
systemctl mask pipewire.service pipewire.socket pipewire-pulse.service pipewire-pulse.socket wireplumber.service || true

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

# Disable and mask the BlueZ Bluetooth service. A missing unit is expected
# and must not fail the installation.
systemctl disable bluetooth.service || true
systemctl mask bluetooth.service || true

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

# Disable and mask kdump, systemd-coredump, ABRT services, the debug shell,
# and kernel debug, tracing, and configuration mounts. Missing units are
# expected and must not fail the installation.
systemctl disable kdump.service abrt-ccpp.service abrt-oops.service abrtd.service systemd-coredump.service systemd-coredump.socket systemd-debug-shell.service sys-kernel-debug.mount sys-kernel-tracing.mount sys-kernel-config.mount || true
systemctl mask kdump.service abrt-ccpp.service abrt-oops.service abrtd.service systemd-coredump.service systemd-coredump.socket systemd-debug-shell.service sys-kernel-debug.mount sys-kernel-tracing.mount sys-kernel-config.mount || true

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
