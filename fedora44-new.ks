# Generated for Fedora 44, UEFI, minimal Sway Wayland, explicit package set.
# WARNING: this file contains the LUKS passphrase in clear text.

text
url --url=https://download.fedoraproject.org/pub/fedora/linux/releases/44/Everything/x86_64/os/
repo --name=fedora-updates --baseurl=https://download.fedoraproject.org/pub/fedora/linux/updates/44/Everything/x86_64/ --install
#repo --name=surfshark --baseurl=https://rpm.surfshark.com/linux/stable/x86_64/ --install
firstboot --disable
eula --agreed
reboot

lang en_GB.UTF-8
keyboard --vckeymap=gb
timezone Europe/London --utc

network --bootproto=dhcp --device=link --activate --hostname=fed-desk --noipv6
firewall --enabled
selinux --enforcing
services --enabled="NetworkManager,firewalld,chronyd,seatd" --disabled="avahi-daemon,bluetooth,cups"

rootpw --lock
user --name=aslate --groups=wheel --password='$6$vBjuqURNzrddC/HQ$Xqtgns3m4LNscrFJe3vrUT2QafnPUZe50EXd9ZCRCaJltsu/jYSENAEd1v0r7QrODzB6eDzbwKggqDnzy.nDk/' --iscrypted

ignoredisk --only-use=sda
zerombr
clearpart --none

# Preserve existing boot partitions cleanly
part /boot/efi --fstype=efi --onpart=/dev/sda1 --noformat
part /boot --fstype=ext4 --onpart=/dev/sda3 --noformat

# Recreate the encrypted physical volume on sda5 from scratch
part pv.01 --onpart=/dev/sda5 --encrypted --luks-version=luks2 --pbkdf=argon2id --cipher=aes-xts-plain64 --passphrase="my lovely horse"

# Setup Volume Group on the fresh physical volume
volgroup fedora_vg pv.01

# Create separate logical volumes for root and home
logvol / --fstype=btrfs --name=root --vgname=fedora_vg --size=40000
logvol /home --fstype=btrfs --name=home --vgname=fedora_vg --size=1 --grow

# Btrfs root subvolumes layout
btrfs none --label=fedora_root /dev/fedora_vg/root
btrfs / --subvol --name=@ fedora_root
btrfs /var --subvol --name=@var fedora_root
btrfs /tmp --subvol --name=@tmp fedora_root
btrfs /.snapshots --subvol --name=@snapshots fedora_root

# Separate Btrfs home subvolume layout 
btrfs none --label=fedora_home /dev/fedora_vg/home
btrfs /home --subvol --name=@home fedora_home


bootloader --append="ipv6.disable=1 rd.luks.options=discard=no"

%packages --excludedocs --inst-langs=en_GB.UTF-8 --nocore
abattis-cantarell-fonts
adwaita-icon-theme
audit
bash
bind-utils
btrfs-progs
ca-certificates
chrony
coreutils
cryptsetup
chromium
dnf5
dnf5-plugins
dosfstools
dracut
dracut-config-rescue
e2fsprogs
efibootmgr
fedora-release
fedora-repos
filesystem
firefox
firewalld
foot
fuzzel
gawk
gparted
glibc-langpack-en
grim
grub2-common
grub2-efi-x64
grub2-efi-x64-modules
grub2-tools
grub2-tools-minimal
htop
iperf3
kernel
kernel-core
kernel-modules
less
liberation-fonts-all
linux-firmware
lxqt-policykit
mako
NetworkManager
NetworkManager-wifi
neovim
nmap
policycoreutils
polkit
rpm
seatd
selinux-policy-targeted
setup
shadow-utils
shim-x64
slurp
smartmontools
#surfshark-vpn
sudo
sway
swaybg
swayidle
swaylock
systemd-resolved
tcpdump
timeshift
util-linux
waybar
which
wl-clipboard
wpa_supplicant
xdg-desktop-portal-gtk
xdg-desktop-portal-wlr
xdg-user-dirs
xdg-utils
%end

%post --erroronfail --log=/root/kickstart-post.log
set -Eeuo pipefail

# Disable IPv6 persistently
cat > /etc/sysctl.d/90-disable-ipv6.conf <<'SYSCTL'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
SYSCTL

# Disable multicast name resolution and enforce Secure DNS
mkdir -p /etc/systemd/resolved.conf.d /etc/NetworkManager/conf.d
cat > /etc/systemd/resolved.conf.d/90-secure-dns.conf <<'RESOLVED'
[Resolve]
LLMNR=no
MulticastDNS=no
DNS=1.1.1.1#cloudflare-dns.com 1.0.0.1#cloudflare-dns.com 9.9.9.9#dns.quad9.net
FallbackDNS=8.8.8.8 8.8.4.4
DNSOverTLS=yes
DNSSEC=yes
RESOLVED

cat > /etc/NetworkManager/conf.d/90-no-connectivity.conf <<'NM'
[connectivity]
enabled=false
NM

systemctl mask avahi-daemon.service avahi-daemon.socket brltty.service brltty-udev.service 2>/dev/null || true
systemctl disable bluetooth.service cups.service brltty.service brltty-udev.service 2>/dev/null || true

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

# --- Auto-login into Sway on TTY1 ---
mkdir -p /etc/systemd/system/getty@tty1.service.d

cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<'AUTOLOGIN'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin aslate --noclear %I $TERM
Type=idle
AUTOLOGIN

cat > /home/aslate/.bash_profile <<'PROFILE'
#
# ~/.bash_profile
#

# Automatically launch Sway on tty1 if not already running
if [ -z "${WAYLAND_DISPLAY:-}" ] && [ "$(tty)" = "/dev/tty1" ]; then
    exec sway
fi
PROFILE

chown aslate:aslate /home/aslate/.bash_profile
chmod 644 /home/aslate/.bash_profile

# --- First-Boot Passphrase Rotation Script & Service (Targeting TTY2) ---
cat > /usr/local/bin/rotate-luks-passphrase.sh <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

LUKS_PART=""
if [[ -f /etc/crypttab ]]; then
    LUKS_PART=$(awk 'NR==1 {print $2}' /etc/crypttab | sed 's/UUID=//')
fi
[[ -z "$LUKS_PART" ]] && LUKS_PART="/dev/sda5"

TEMP_PASS="my lovely horse"

echo "======================================================="
echo " First Boot: Update LUKS Passphrase"
echo "======================================================="
echo

while true; do
    read -s -p "Enter NEW LUKS passphrase: " NEW_PASS1
    echo
    read -s -p "Confirm NEW LUKS passphrase: " NEW_PASS2
    echo
    if [[ "$NEW_PASS1" == "$NEW_PASS2" ]] && [[ -n "$NEW_PASS1" ]]; then
        break
    fi
    echo "Passphrases do not match or are empty. Please try again."
    echo
done

echo "Adding new passphrase to LUKS keyslot..."
cryptsetup luksAddKey "$LUKS_PART" <(echo -n "$NEW_PASS1") --key-file=<(echo -n "$TEMP_PASS")

echo "Removing temporary installation passphrase..."
cryptsetup luksRemoveKey "$LUKS_PART" --key-file=<(echo -n "$TEMP_PASS")

echo "Passphrase updated successfully!"

systemctl disable rotate-luks.service
rm -f /etc/systemd/system/rotate-luks.service
rm -f /usr/local/bin/rotate-luks-passphrase.sh
SCRIPT

chmod +x /usr/local/bin/rotate-luks-passphrase.sh

cat > /etc/systemd/system/rotate-luks.service <<'SERVICE'
[Unit]
Description=Rotate temporary LUKS passphrase on first boot
ConditionPathExists=/usr/local/bin/rotate-luks-passphrase.sh
Conflicts=getty@tty2.service
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/rotate-luks-passphrase.sh
StandardInput=tty
StandardOutput=tty
TTYPath=/dev/tty2
TTYReset=yes
TTYVHangup=yes
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICE

systemctl enable rotate-luks.service

# --- First-Boot Surfshark Setup Script & Service (Targeting TTY2) ---
cat > /usr/local/bin/setup-surfshark.sh <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

echo "======================================================="
echo " First Boot: Surfshark VPN Setup"
echo "======================================================="
echo

surfshark login

echo "Configuring Surfshark preferences..."
surfshark config set protocol wireguard
surfshark config set killswitch on

echo "Surfshark setup complete!"

systemctl disable setup-surfshark.service
rm -f /etc/systemd/system/setup-surfshark.service
rm -f /usr/local/bin/setup-surfshark.sh
SCRIPT

chmod +x /usr/local/bin/setup-surfshark.sh

cat > /etc/systemd/system/setup-surfshark.service <<'SERVICE'
[Unit]
Description=Configure Surfshark VPN on first boot
ConditionPathExists=/usr/local/bin/setup-surfshark.sh
Conflicts=getty@tty2.service
After=rotate-luks.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/setup-surfshark.sh
StandardInput=tty
StandardOutput=tty
TTYPath=/dev/tty2
TTYReset=yes
TTYVHangup=yes
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICE

systemctl enable setup-surfshark.service

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