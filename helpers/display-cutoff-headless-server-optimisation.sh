#!/bin/sh
# headless-optimize.sh
#
# Converts a fresh Droidian install on the Realme RMX2001 into a lean,
# SSH-only headless box: no GUI boot, dead/unused hardware daemons masked,
# and the OLED panel forced off at boot instead of being left stuck on
# whatever the bootloader/Plymouth last drew to it.
#
# Run once after a fresh flash/format, as the droidian user, with sudo
# available. Idempotent - safe to re-run.
#
#   chmod +x headless-optimize.sh
#   ./headless-optimize.sh
#
# A reboot is required at the end: the default-target change, Plymouth
# removal, and the display power-off cycle only take effect at boot.

set -e

echo "== 1/6: killing the modem stack (ofono2mm crash-loops with no SIM in use) =="
sudo systemctl mask --now ofono ModemManager

echo "== 2/6: switching to text-mode boot, no Phosh GUI =="
sudo systemctl set-default multi-user.target
sudo systemctl disable phosh

echo "== 3/6: masking unused phone-hardware services =="
sudo systemctl mask --now \
  cups cups-browsed cups.socket cups.path \
  bluetooth bluebinder \
  nfcd \
  geoclue iio-sensor-proxy sensorfwd \
  openvpn strongswan-starter \
  lm-sensors vnstat \
  udisks2 accounts-daemon \
  NetworkManager-wait-online \
  polkit upower
sudo systemctl disable --now apt-daily.timer apt-daily-upgrade.timer

echo "== 4/6: disabling the Plymouth boot splash =="
sudo systemctl mask plymouth-start.service

echo "== 5/6: installing early best-effort framebuffer blank =="
sudo tee /usr/lib/systemd/system/blank-display.service > /dev/null <<'EOF'
[Unit]
Description=Blank display and kill backlight (headless server, prevent OLED burn-in)
DefaultDependencies=no
After=local-fs.target
Before=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c "echo 1 > /sys/class/graphics/fb0/blank 2>/dev/null; echo 0 > /sys/class/leds/lcd-backlight/brightness 2>/dev/null; true"

[Install]
WantedBy=multi-user.target
EOF

echo "== 6/6: installing the real display power-off cycle =="
# The bootloader/Plymouth draw the panel via a hardware overlay plane that
# only gets released once something real (phoc, via the hwcomposer HAL)
# takes ownership of the display and issues an explicit power-off. Nothing
# else on a headless box ever does that, so without this the panel is
# stuck showing whatever was last drawn, forever. This briefly brings up
# Phosh purely to grab the panel and turn it off, then tears it back down.
sudo tee /usr/local/sbin/display-poweroff.sh > /dev/null <<'EOF'
#!/bin/sh
set -e

systemctl start phosh

for i in $(seq 1 40); do
  [ -S /run/user/32011/wayland-0 ] && break
  sleep 0.5
done

sleep 8

su -s /bin/sh droidian -c "XDG_RUNTIME_DIR=/run/user/32011 WAYLAND_DISPLAY=wayland-0 wlr-randr --output HWCOMPOSER-1 --off" || true

systemctl stop phosh || true
systemctl stop android-service@hwcomposer || true

# phosh's ExecStartPost does `chvt 7`, which kills getty@tty1's session -
# bring local console login back so it doesn't stay dead after every boot.
systemctl restart getty@tty1 || true

exit 0
EOF
sudo chmod +x /usr/local/sbin/display-poweroff.sh

sudo tee /usr/lib/systemd/system/display-poweroff.service > /dev/null <<'EOF'
[Unit]
Description=Power off display panel at boot (headless server - prevent OLED burn-in/wasted power)
After=lxc@android.service
Wants=lxc@android.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/display-poweroff.sh
TimeoutStartSec=60

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable display-poweroff.service

echo
echo "Done. Reboot to apply (default target, Plymouth removal, and the"
echo "display power-off cycle only take effect at boot):"
echo
echo "    sudo reboot"
echo
echo "SSH, Wi-Fi (lxc@android), and Tailscale are all untouched - verify"
echo "SSH access before disconnecting, same as any remote change."
