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
git-core
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

# Install the Codex CLI when the npm registry is reachable. Keep the helper
# available so installation can be retried safely after first boot.
cat << 'EOF' > /usr/local/sbin/install-codex-cli
#!/usr/bin/env bash
set -uo pipefail

for attempt in 1 2 3; do
    echo "Installing Codex CLI (attempt ${attempt} of 3)..."
    if timeout 300 npm install --global --prefix /usr/local \
        --no-audit --no-fund @openai/codex@latest; then
        if [ -x /usr/local/bin/codex ]; then
            /usr/local/bin/codex --version
            exit 0
        fi
        echo "npm completed but /usr/local/bin/codex was not created." >&2
    else
        echo "Codex CLI installation attempt ${attempt} failed." >&2
    fi

    if [ "${attempt}" -lt 3 ]; then
        sleep 5
    fi
done

echo "Codex CLI was not installed. Retry with: sudo /usr/local/sbin/install-codex-cli" >&2
exit 1
EOF
chmod 755 /usr/local/sbin/install-codex-cli

if ! /usr/local/sbin/install-codex-cli; then
    echo "WARNING: Continuing without Codex CLI; its Fedora dependencies are installed." >&2
fi

# Ensure standard user owns home directory
chown -R aslate:aslate /home/aslate

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

# Configure Graphical boot & Greetd display manager to boot into Sway UI automatically
systemctl set-default graphical.target

mkdir -p /etc/greetd
cat << 'EOF' > /etc/greetd/config.toml
[default_session]
command = "tuigreet --time --remember --cmd sway"
user = "greeter"

[initial_session]
command = "sway"
user = "aslate"
EOF

systemctl enable greetd.service 2>/dev/null || true

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
systemctl enable systemd-resolved || true
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# Lockdown Firewalld: Set default zone to 'drop' with zero exposed services or ports
mkdir -p /etc/firewalld/zones
if [ -f /etc/firewalld/firewalld.conf ]; then
    sed -i 's/^DefaultZone=.*/DefaultZone=drop/' /etc/firewalld/firewalld.conf
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
%end
