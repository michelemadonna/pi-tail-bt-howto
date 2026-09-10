# Pi-Tail Reverse Bluetooth Tethering Configuration

## Overview

[Pi-Tail](https://www.kali.org/docs/arm/raspberry-pi-zero-w-pi-tail/) is a specialized **Kali Linux** image optimized for the **Raspberry Pi Zero 2 W**, designed specifically for portable penetration testing and cybersecurity fieldwork. 

It transforms the compact Raspberry Pi into a **“tail”** device that can be **tethered to a smartphone or PC**, using the host device for power, display (via VNC), keyboard, and internet access — all while keeping the Pi headless and highly portable.

The official Pi-Tail setup typically configures Bluetooth in “server” mode: the Raspberry Pi acts as a Bluetooth access point, allowing your smartphone or PC to pair and connect to it, sharing the host’s internet connection with the Pi via Bluetooth PAN (Personal Area Network).
This repository provides a reverse Bluetooth configuration: the Raspberry Pi acts as the client, actively connecting to your paired smartphone or PC. This approach offers greater reliability in certain scenarios, as it allows the Pi to automatically establish the connection on boot and better handle internet sharing from the host device.

Key Benefits of This Reverse Setup

* Seamless Internet Sharing: The Pi reliably obtains internet access from your phone/PC without manual intervention after initial pairing.
* Systemd Integration: Includes a custom systemd service script to manage the Bluetooth connection automatically at boot.
* Muliple Device Support: Easily configure the Pi to connect to multiple devices (e.g., both an iPhone and an Android phone) with prioritized connection attempts.

This setup is particularly useful for cybersecurity students and professionals needing a discreet, portable Kali environment with consistent network access via Bluetooth tethering.
Feel free to contribute improvements or report issues!

## Prerequisites

- A Raspberry Pi Zero 2 W running Kali Linux (Pi-Tail image recommended). See [Pi-Tail GitHub](https://github.com/Re4son/RPi-Tweaks/tree/master/pi-tail) for setup instructions and more.
- A smartphone or PC capable of Bluetooth tethering.

## Setup Instructions

1. **Initial Configuration**
   access your Raspberry Pi via SSH or terminal and perform initial updates and configurations (default username: kali, password: kali):
   
   ```bash
   sudo apt update
   sudo apt upgrade -y
   ```
   
   change the hostname to a more understandable name for easier identification:
   
   ```bash
   sudo hostnamectl set-hostname printer-pi
   ```
   
   edit the hosts file and systemd resolved configuration to ensure proper DNS resolution:
   
   ```bash
   sudo nano /etc/hosts
   ```
   
   change the dns server settings:
   
   ```bash
   sudo nano /etc/systemd/resolved.conf
   ```
   
   Add or modify the following lines:
   
   ```
   [Resolve]
   DNS=1.1.1.1
   FallbackDNS=9.9.9.9
   ```
   
   Restart the systemd-resolved service to apply changes:
   
   ```bash
   sudo systemctl restart systemd-resolved
   resolvectl status
   ```
   
   Enable and start the Avahi daemon for network service discovery:
   
   ```bash
   sudo systemctl enable avahi-daemon
   sudo systemctl start avahi-daemon
   ```
   
   change the default password for security:
   
   ```bash
   passwd
   ```

2. **Install Required Packages**
   Ensure that BlueZ and other necessary packages are installed on your Raspberry Pi:
   
   ```bash
   sudo apt install bluez bluez-tools bluetooth blueman pulseaudio-module-bluetooth \
       python3-dbus python3-gi isc-dhcp-client -y
   ```

3. **Pair Your Devices**
   
   > ⚠️ **Important:** Before proceeding with Bluetooth pairing, make sure that Internet Sharing (tethering) is enabled on your smartphone.
   
   - **iPhone:**
     
     1. Go to **Settings** > **Personal Hotspot**.
     2. Toggle **Allow Others to Join** to ON.
     3. Ensure **Maximize Compatibility** is enabled for easier connection.
     4. Bluetooth must be ON.
   
   - **Android:**
     
     1. Go to **Settings** > **Network & Internet** > **Hotspot & tethering**.
     2. Enable **Bluetooth tethering**.
     3. Make sure Bluetooth is ON.
   
   Once Internet Sharing is active, you can proceed with Bluetooth pairing.
   
   Use `bluetoothctl` to pair your Raspberry Pi with your smartphone or PC:
   
   ```bash
   bluetoothctl
   ```
   
   Inside the `bluetoothctl` prompt, use the following commands:
   
   ```bash
   power on
   agent on
   default-agent
   scan on
   ```
   
   Once you see your device, note its MAC address and pair:
   
   ```
   pair XX:XX:XX:XX:XX:XX
   trust XX:XX:XX:XX:XX:XX
   ```
   
   Replace `XX:XX:XX:XX:XX:XX` with your device's MAC address. 
   You may be prompted to confirm the pairing on your smartphone. Accept the pairing request.
   Pair other devices if needed by repeating the above steps.
   Finally, stop scanning and exit:
   
   ```
   scan off
   quit
   ```

4. **Install the Bluetooth PAN Client**
   Install the supervisor, its BlueZ D-Bus helper, and the DHCP hook:

   ```bash
   sudo cp ./auto-bt-pan.sh /usr/local/bin/auto-bt-pan.sh
   sudo install -d -m 755 /usr/local/libexec
   sudo cp ./bluez-pan-connect.py /usr/local/libexec/bluez-pan-connect.py
   sudo cp ./auto-bt-pan-dhclient-script /usr/local/libexec/auto-bt-pan-dhclient-script
   sudo chmod +x /usr/local/bin/auto-bt-pan.sh \
       /usr/local/libexec/bluez-pan-connect.py \
       /usr/local/libexec/auto-bt-pan-dhclient-script
   ```
   
   Modify the following content regarding your devices in `/usr/local/bin/auto-bt-pan.sh`:
   
   ```bash
   # List of devices in priority order
   # FORMAT: MAC|TYPE|STATIC_IP|GATEWAY|DNS
   DEVICES=(
   "xx:xx:xx:xx:xx:xx|iPhone|172.20.10.2|172.20.10.1|1.1.1.1"
   "yy:yy:yy:yy:yy:yy|Android|192.168.44.2|192.168.44.1|1.1.1.1"
   )
   ```
   
   The devices are tried in the order listed in `DEVICES`. The format is:

   ```bash
   MAC|TYPE|STATIC_IP|GATEWAY|DNS
   ```

   DHCP is attempted first. `STATIC_IP` is used as a fallback with a `/28`
   prefix by default; override it with `BLUETOOTH_PAN_STATIC_PREFIX` if the
   tethering network uses another prefix.

5. **Create Systemd Service**
   Create a systemd service to manage the Bluetooth connection:
   
   ```bash
   sudo cp ./auto-bt-pan.service /etc/systemd/system/auto-bt-pan.service
   ```

6. **Enable and Start the Service**
   Enable and start the Bluetooth PAN client service:
   
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable --now auto-bt-pan.service
   ```

7. **Reboot and Test**
   Reboot your Raspberry Pi to apply all changes:
   
   ```bash
   sudo reboot
   ```
   
   After reboot, check if the Bluetooth PAN connection is established and if you have internet access:
   
   ```bash
   ip -br address
   ip route
   ping -c 4 google.com
   ```

## Troubleshooting

Ensure your smartphone or PC has Bluetooth tethering enabled

Check the status of the systemd service:

- ```bash
  sudo systemctl status auto-bt-pan.service
  ```

- Review logs for errors and reconnection events:
  
  ```bash
  journalctl -u auto-bt-pan.service -f
  ```

## Bonus 1: USB Gadget Bootstrap on macOS

The package can configure USB gadget mode on a Pi-Tail installation when the
Mac can modify only the FAT boot partition. The first boot uses an ifupdown
`up` hook attached to `lo`; the hook installs the runtime files into the real
Kali root, starts the gadget immediately, and removes itself.

This method leaves the normal systemd boot sequence unchanged.

### Clean installation from a fresh Pi-Tail image

Use this procedure when starting from a newly flashed Pi-Tail SD card. It
does not require SSH access or any pre-existing USB gadget installation.

1. Flash the Pi-Tail image to the SD card and mount its FAT boot partition on
   the Mac, for example as `/Volumes/bootfs`. Do not boot the card yet.

2. Copy the package files to the root of the boot partition:

   ```bash
   BOOT=/Volumes/bootfs

   cp ./install-usb-gadget.sh "$BOOT/install-usb-gadget.sh"
   cp ./usb-gadget "$BOOT/usb-gadget"
   cp ./usb-gadget.service "$BOOT/usb-gadget.service"
   cp ./usb-gadget.conf "$BOOT/usb-gadget.conf"
   ```

3. Edit `$BOOT/cmdline.txt`. Keep it as one line and remove any old
   `g_ether`, `g_ether.host_addr=...`, and `g_ether.dev_addr=...` tokens. If
   `modules-load=` contains `g_ether`, leave only the other modules, normally:

   ```text
   modules-load=dwc2
   ```

4. Edit `$BOOT/interfaces` and ensure the loopback stanza contains this hook:

   ```text
   auto lo
   iface lo inet loopback
       up /bin/bash /boot/firmware/install-usb-gadget.sh --offline-firstboot || true
   ```

   Add the hook only once. Do not add a second USB network stanza; the
   `usb-gadget` script configures the USB interface itself.

5. Eject the SD card cleanly, insert it into the Pi, and connect the USB data
   port to the Mac. During this first boot, Pi-Tail copies `interfaces`, raises
   `lo`, and runs the installer. The installer copies the runtime script and
   service into the root filesystem, removes the hook, reloads systemd, enables
   and starts `usb-gadget.service`, and writes its one-shot marker.

6. Configure the new USB Ethernet interface on macOS as `192.168.2.2` with
   subnet mask `255.255.255.0`. The default Pi address is `192.168.2.3`.

7. Verify the installation over USB:

   ```bash
   ssh kali@192.168.2.3
   sudo systemctl is-active usb-gadget.service
   sudo test -e /var/lib/usb-gadget/.offline-firstboot-installed
   ```

   With boot storage enabled, the service exports the boot partition to the
   host and it is no longer mounted locally. `usb-gadget.conf` remains on that
   boot partition and is read when the service starts.

### Configure macOS

After the Pi has booted, macOS should show a new USB Ethernet interface. Set
its IPv4 address manually to `192.168.2.2` with subnet mask
`255.255.255.0`. The Pi uses `192.168.2.3` by default, as configured in
`usb-gadget.conf`.

Keep Wi-Fi or the normal Ethernet service above the USB gadget in macOS
Network Service Order. You can then connect with:

```bash
ssh kali@192.168.2.3
```

To inspect the first-boot result on the Pi:

```bash
sudo systemctl status usb-gadget.service
sudo test -e /var/lib/usb-gadget/.offline-firstboot-installed
sudo journalctl -u usb-gadget.service --no-pager
```
