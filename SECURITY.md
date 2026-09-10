# Security Policy

## Scope

This repository configures a Raspberry Pi as an outgoing Bluetooth PAN client.
The software manages paired Bluetooth devices, creates a PAN network interface,
and changes the Pi's routing and DNS state while the connection is active.

The repository does not provide a general-purpose Bluetooth access point,
firewall, VPN, credential store, or security hardening baseline for Kali Linux.

## Supported versions

Only the current `main` branch is supported. Older copied installers and local
modifications may contain issues that are fixed in the current branch.

## Reporting a vulnerability

Please do not disclose security vulnerabilities in public issues, pull requests,
or discussion threads.

Report a vulnerability through GitHub's private vulnerability reporting for this
repository, if available. If private reporting is unavailable, contact the
repository owner through GitHub and include **Security report** in the subject.

Please include:

- the affected commit, tag, or installer URL;
- the Raspberry Pi and Kali versions;
- the relevant command, configuration, or input;
- reproduction steps and expected versus actual behavior;
- logs or proof of impact with personal data and secrets removed.

Do not include private Bluetooth keys, passwords, access tokens, or complete
system logs containing personal information.

There is no guaranteed response or remediation time, but reports will be
reviewed as soon as practical.

## Security considerations

### Installer

The documented installer downloads shell, Python, service, and DHCP-hook files
from the repository and executes the installer through Bash. This is convenient
but requires trusting the repository, the selected branch, GitHub, and the
network path.

For higher assurance, review and pin the installer source to a specific commit
before running it. Do not run it as `sudo bash`; the installer must run as the
normal user and requests `sudo` only for package and system-file installation.

### Bluetooth pairing

Only configure devices that you own or explicitly trust. Pairing and trusting a
device authorizes the Pi to reconnect to it. Verify the MAC address and confirm
that `bluetoothctl info` reports both `Paired: yes` and `Trusted: yes` before
adding the device to `/etc/default/auto-bt-pan`.

Remove devices that are no longer trusted:

```bash
bluetoothctl remove AA:BB:CC:DD:EE:FF
```

### Privileges and network state

The service runs with root privileges because it must manage BlueZ, network
interfaces, routes, DHCP, and resolver configuration. The supervisor is designed
to remove only the route and DNS state that it owns, but it should still be
reviewed before deployment on a system with custom routing or firewall rules.

The PAN gateway becomes the preferred default route while the connection is
active. Any device that can provide the configured PAN gateway may therefore
provide the Pi's Internet path.

### Configuration and logs

Protect `/etc/default/auto-bt-pan` because it controls which Bluetooth devices
the root service will connect to and which routes it will install. Do not put
passwords, tokens, or other secrets in the device entries.

Logs may contain Bluetooth MAC addresses, interface names, and network details.
Treat `journalctl -u auto-bt-pan.service` output as sensitive operational data.

## Security testing

Before deploying a change, test at least:

- pairing and trust of only the intended device;
- loss and restoration of Bluetooth tethering;
- failover to the next configured device;
- cleanup after stopping the service;
- preservation of unrelated routes and `/etc/resolv.conf`;
- service behavior after Bluetooth restarts and Raspberry Pi reboots.
