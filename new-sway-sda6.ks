# Kickstart file for Fedora 44, UEFI, Sway Wayland desktop environment.

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
user --name=aslate --groups=wheel --shell=/bin/bash --passwd=changeme

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
btrfs / --subvol --name=@root fedora
btrfs /home --subvol --name=@home fedora
btrfs /.snapshots --subvol --name=@snapshots fedora

# Limit kernel command-line hardening to settings that apply during early boot.
bootloader --append="ipv6.disable=1 crashkernel=no quiet loglevel=3 rd.systemd.debug_shell=0"

# System services
services --enabled=NetworkManager,firewalld,systemd-resolved,
services --disabled=avahi-daemon,avahi-daemon.socket,kdump,abrtd,abrt-ccpp,abrt-oops,brltty,brltty-udev,sys-kernel-debug.mount,sys-kernel-tracing.mount

%packages 
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
rofi
greetd
tuigreet

# Screenshots & Clipboard Utilities
grim
slurp
wl-clipboard

ksvalidator

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
#nodejs24-bin
#nodejs24-npm-bin
polkit
pykickstart
#xdg-utils
#lxqt-policykit

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

%post --log=/root/kickstart-post.log
# Mask and disable Brltty & AT-SPI Accessibility services globally
systemctl mask brltty.service brltty-udev.service
systemctl disable brltty.service brltty-udev.service

# Mask systemd user services for AT-SPI bus and registry
systemctl mask at-spi-dbus-bus.service at-spi2-registryd.service
systemctl disable at-spi-dbus-bus.service at-spi2-registryd.service 

systemctl mask  org.a11y.Bus.service org.a11y.atspi.Registry.service 
systemctl disable  org.a11y.Bus.service org.a11y.atspi.Registry.service 

# Disable and mask PipeWire and WirePlumber user services globally
systemctl mask pipewire.service pipewire.socket pipewire-pulse.service pipewire-pulse.socket wireplumber.service
systemctl disable pipewire.service pipewire.socket pipewire-pulse.service pipewire-pulse.socket wireplumber.service

systemctl mask avahi-daemon.service avahi-daemon.socket
systemctl disable avahi-daemon.service avahi-daemon.socket

# Disable Precision Time Protocol synchronization without disabling Ethernet.
systemctl disable ptp4l.service ptp4l@.service phc2sys.service phc2sys@.service timemaster.service
systemctl mask ptp4l.service ptp4l@.service phc2sys.service phc2sys@.service timemaster.service

# Disable binfmt_misc activation and prevent the Intel SPI flash devices from appearing.
systemctl mask proc-sys-fs-binfmt_misc.automount
systemctl mask systemd-binfmt.service

systemctl disable proc-sys-fs-binfmt_misc.automount
systemctl disable systemd-binfmt.service

cat << 'EOF' > /etc/modprobe.d/disable-intel-spi.conf
blacklist intel_spi_pci
blacklist intel_spi_platform
EOF

# Use systemd masks to disable services and debug, tracing, and configfs mounts.
systemctl mask kdump.service abrt-ccpp.service abrt-oops.service abrtd.service systemd-coredump.service systemd-coredump.socket systemd-debug-shell.service sys-kernel-debug.mount sys-kernel-tracing.mount sys-kernel-config.mount
systemctl disable kdump.service abrt-ccpp.service abrt-oops.service abrtd.service systemd-coredump.service systemd-coredump.socket systemd-debug-shell.service sys-kernel-debug.mount sys-kernel-tracing.mount sys-kernel-config.mount

# Disable core dumps through native systemd configuration and process limits.
# mkdir -p /etc/systemd/coredump.conf.d

# mkdir -p /etc/security/limits.d

# Disable IPv6 via sysctl persistently
cat << 'EOF' > /etc/sysctl.d/90-disable-ipv6.conf
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
net.ipv6.conf.eno1.disable_ipv6 = 1
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

# Configure Cloudflare Secure DNS (DNS-over-TLS over IPv4) in systemd-resolved
mkdir -p /etc/systemd/resolved.conf.d
cat << 'EOF' > /etc/systemd/resolved.conf.d/cloudflare-dns-over-tls.conf
[Resolve]
DNS=1.1.1.1#cloudflare-dns.com 1.0.0.1#cloudflare-dns.com
DNSOverTLS=yes
DNSSEC=yes
MulticastDNS=no
EOF

%end
