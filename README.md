# Pi-Tail Reverse Bluetooth Tethering Configuration

## Overview

[Pi-Tail](https://www.kali.org/docs/arm/raspberry-pi-zero-w-pi-tail/) is a specialized **Kali Linux** image optimized for the **Raspberry Pi Zero 2 W**, designed specifically for portable penetration testing and cybersecurity fieldwork. 

It transforms the compact Raspberry Pi into a **“tail”** device that can be **tethered to a smartphone or PC**, using the host device for power, display (via VNC), keyboard, and internet access — all while keeping the Pi headless and highly portable.

The official Pi-Tail setup typically configures Bluetooth in “server” mode: the Raspberry Pi acts as a Bluetooth access point, allowing your smartphone or PC to pair and connect to it, sharing the host’s internet connection with the Pi via Bluetooth PAN (Personal Area Network).
This repository provides a reverse Bluetooth configuration: the Raspberry Pi acts as the client, actively connecting to your paired smartphone or PC. This approach offers greater reliability in certain scenarios, as it allows the Pi to automatically establish the connection on boot and better handle internet sharing from the host device.

`auto-bt-pan` has been tested on Kali Linux Pi-Tail running on a Raspberry Pi
Zero 2 W. It can be adapted to other Raspberry Pi distributions when they
provide the required BlueZ, systemd, iproute2, DHCP client, and Python D-Bus
components.

Key Benefits of This Reverse Setup

* Seamless Internet Sharing: The Pi reliably obtains internet access from your phone/PC without manual intervention after initial pairing.
* Systemd Integration: Includes a custom systemd service script to manage the Bluetooth connection automatically at boot.
* Multiple Device Support: Easily configure the Pi to connect to multiple devices (e.g., both an iPhone and an Android phone) with prioritized connection attempts.

This setup is particularly useful for cybersecurity students and professionals needing a discreet, portable Kali environment with consistent network access via Bluetooth tethering.
Feel free to contribute improvements or report issues!

## Prerequisites

- A Raspberry Pi Zero 2 W running Kali Linux (Pi-Tail image recommended). See [Pi-Tail GitHub](https://github.com/Re4son/RPi-Tweaks/tree/master/pi-tail) for setup instructions and more.
- A smartphone or PC capable of Bluetooth tethering.

## Initial system setup

Complete the basic Kali setup before pairing or installing the Bluetooth PAN
service. Connect to the Raspberry Pi through SSH or a local terminal. The
default Pi-Tail credentials are `kali` / `kali`; change the password immediately:

```bash
passwd
```

Update the system:

```bash
sudo apt update
sudo apt upgrade -y
```

Set a recognizable hostname, replacing `printer-pi` if desired:

```bash
sudo hostnamectl set-hostname printer-pi
```

Review the hosts file:

```bash
sudo nano /etc/hosts
```

Configure DNS resolution in `/etc/resolv.conf`:

```bash
sudo nano /etc/resolv.conf
```

Add or update these entries:

```text
nameserver 1.1.1.1
nameserver 9.9.9.9
```

If `/etc/resolv.conf` is a symbolic link managed by another resolver, edit the
file it points to or configure that resolver instead of replacing the link.

Enable Avahi for local service discovery:

```bash
sudo systemctl enable avahi-daemon
sudo systemctl start avahi-daemon
```

## Before installation

Complete these steps on the Raspberry Pi before running the installer:

1. Boot Kali and connect to the Pi through SSH or a local terminal. The Pi
   needs temporary Internet access so `apt` can install the dependencies.
2. Enable tethering on the phone or computer that will provide the PAN link.
   Bluetooth tethering must be enabled during pairing and whenever you test
   the connection.
3. Pair and trust every device you want the Pi to use. The installer does not
   perform pairing for you.
4. Note the Bluetooth MAC address of each paired device.

Do not run the installer with `sudo bash`. Run it as the normal user; it asks
for sudo only when it is ready to install packages and system files. Do not
install the files manually and do not edit `/usr/local/bin/auto-bt-pan.sh`
after installation. Device configuration belongs in
`/etc/default/auto-bt-pan`.

## Pair and trust a device

Enable tethering before pairing.

On an **iPhone**:

1. Open **Settings > Personal Hotspot**.
2. Enable **Allow Others to Join**.
3. Enable **Maximize Compatibility** when available.
4. Make sure Bluetooth is enabled.

On **Android**:

1. Open **Settings > Network & Internet > Hotspot & tethering**. The exact
   menu name may differ by Android version or manufacturer.
2. Enable **Bluetooth tethering**.
3. Make sure Bluetooth is enabled and keep tethering enabled during pairing.

On a **PC**, enable Bluetooth and configure the system's Bluetooth PAN or
Internet Sharing feature before pairing.

On the Raspberry Pi, run:

```bash
bluetoothctl
```

Then enter:

```text
power on
agent on
default-agent
scan on
```

When the device appears, note its MAC address and run:

```text
pair AA:BB:CC:DD:EE:FF
trust AA:BB:CC:DD:EE:FF
info AA:BB:CC:DD:EE:FF
```

Continue only when `info` shows `Paired: yes` and `Trusted: yes`. Repeat this
procedure for every device you want to configure. Then stop scanning and exit:

```text
scan off
quit
```

## Install

Run the installer as the normal user. It installs the dependencies and service,
then asks for the first device configuration:

```bash
curl -fsSL https://raw.githubusercontent.com/michelemadonna/pi-tail-bt-howto/main/install.sh | bash
```

At the prompt enter one line in this format:

```text
MAC|TYPE|STATIC_IP|GATEWAY|DNS
```

Example:

```text
AA:BB:CC:DD:EE:FF|iPhone|172.20.10.2|172.20.10.1|1.1.1.1
```

The installer starts the service only after a valid device has been provided.
DHCP is attempted first; `STATIC_IP` is the fallback address and uses `/28` by
default.

For a non-interactive install:

```bash
curl -fsSL https://raw.githubusercontent.com/michelemadonna/pi-tail-bt-howto/main/install.sh \
  | PI_TAIL_DEVICE='AA:BB:CC:DD:EE:FF|iPhone|172.20.10.2|172.20.10.1|1.1.1.1' bash
```

## Add another device

Pair and trust the new device first, then edit the configuration:

```bash
sudo nano /etc/default/auto-bt-pan
```

Add one quoted entry per device:

```bash
DEVICES=(
    'AA:BB:CC:DD:EE:FF|iPhone|172.20.10.2|172.20.10.1|1.1.1.1'
    '11:22:33:44:55:66|Android|192.168.44.2|192.168.44.1|1.1.1.1'
)
```

The order is the priority order: the first device is always tried first, and
the next device is used only after the active connection fails. Keep each
device's IP range and gateway consistent with that device's Bluetooth
tethering network. After saving the file, restart the service:

```bash
sudo systemctl restart auto-bt-pan.service
```

No script copy or manual package installation is needed when adding devices.

## Test the connection

```bash
sudo systemctl status auto-bt-pan.service
sudo journalctl -fu auto-bt-pan.service
ip -br address
ip route
ping -c 4 google.com
```

## Optional USB gadget mode

If you also want to use the Raspberry Pi as a USB gadget, follow the dedicated
configuration guide in [`rpi-configfs-usb-gadget`](https://github.com/michelemadonna/rpi-configfs-usb-gadget).

This repository manages reverse Bluetooth PAN connectivity; the linked
repository manages the USB ConfigFS gadget setup. Configure USB gadget mode
separately and avoid enabling conflicting gadget configurations at the same
time.

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
