#!/usr/bin/env python3
"""Small BlueZ D-Bus helper for outgoing Bluetooth PAN connections."""

from __future__ import annotations

import argparse
import signal
import sys
import time
from typing import Any

import dbus


PROFILE_UUIDS = {
    "gn": "00001117-0000-1000-8000-00805f9b34fb",
    "nap": "00001116-0000-1000-8000-00805f9b34fb",
    "panu": "00001115-0000-1000-8000-00805f9b34fb",
}

EXIT_OK = 0
EXIT_USAGE = 2
EXIT_TIMEOUT = 10
EXIT_NO_DEVICE = 11
EXIT_PROFILE = 12
EXIT_DISCONNECTED = 13
EXIT_DBUS = 14


class HelperError(Exception):
    """An expected helper failure with a stable process exit code."""

    def __init__(self, code: int, message: str):
        super().__init__(message)
        self.code = code


def normalise_mac(value: str) -> str:
    mac = value.strip().upper()
    parts = mac.split(":")
    if len(parts) != 6 or any(len(part) != 2 for part in parts):
        raise HelperError(EXIT_USAGE, f"invalid Bluetooth address: {value}")
    try:
        if any(int(part, 16) > 255 for part in parts):
            raise ValueError
    except ValueError as error:
        raise HelperError(EXIT_USAGE, f"invalid Bluetooth address: {value}") from error
    return mac


def profile_uuid(value: str) -> str:
    value = value.lower()
    if value in PROFILE_UUIDS:
        return PROFILE_UUIDS[value]
    if len(value) == 36 and value.count("-") == 4:
        return value
    raise HelperError(EXIT_USAGE, f"unsupported PAN profile: {value}")


def get_bus() -> dbus.SystemBus:
    try:
        return dbus.SystemBus()
    except dbus.DBusException as error:
        raise HelperError(EXIT_DBUS, f"cannot connect to the system D-Bus: {error}") from error


def managed_objects(bus: dbus.SystemBus) -> Any:
    try:
        manager = dbus.Interface(
            bus.get_object("org.bluez", "/"),
            "org.freedesktop.DBus.ObjectManager",
        )
        return manager.GetManagedObjects()
    except dbus.DBusException as error:
        raise HelperError(EXIT_DBUS, f"cannot enumerate BlueZ objects: {error}") from error


def find_device(bus: dbus.SystemBus, mac: str) -> str | None:
    for path, interfaces in managed_objects(bus).items():
        properties = interfaces.get("org.bluez.Device1")
        if properties and str(properties.get("Address", "")).upper() == mac:
            return str(path)
    return None


def proxy(bus: dbus.SystemBus, path: str, interface: str) -> Any:
    return dbus.Interface(bus.get_object("org.bluez", path), interface)


def properties(bus: dbus.SystemBus, path: str, interface: str) -> dict[str, Any]:
    try:
        return dict(proxy(bus, path, "org.freedesktop.DBus.Properties").GetAll(interface))
    except dbus.DBusException as error:
        raise HelperError(EXIT_DBUS, f"cannot read {interface} on {path}: {error}") from error


def network_state(bus: dbus.SystemBus, path: str) -> tuple[bool, str]:
    try:
        values = properties(bus, path, "org.bluez.Network1")
    except HelperError:
        return False, ""
    return bool(values.get("Connected", False)), str(values.get("Interface", ""))


def classify_dbus_error(error: dbus.DBusException) -> int:
    name = error.get_dbus_name() or ""
    if any(token in name for token in ("NotAvailable", "NotSupported", "DoesNotExist")):
        return EXIT_PROFILE
    return EXIT_DBUS


def connect_device(mac: str, profile: str, timeout: float) -> str:
    bus = get_bus()
    uuid = profile_uuid(profile)
    deadline = time.monotonic() + timeout
    saw_device = False
    last_error = "connection failed"

    while time.monotonic() < deadline:
        path = find_device(bus, mac)
        if path is None:
            time.sleep(0.5)
            continue

        saw_device = True
        network = None

        try:
            network = proxy(bus, path, "org.bluez.Network1")
        except dbus.DBusException:
            # Network1 can be registered only after BlueZ has resolved the
            # remote services. Device1.ConnectProfile triggers that discovery.
            pass

        try:
            if network is not None:
                interface = str(network.Connect(uuid))
                if interface:
                    print(interface, flush=True)
                    return interface
            else:
                device = proxy(bus, path, "org.bluez.Device1")
                device.ConnectProfile(uuid)
        except dbus.DBusException as error:
            name = error.get_dbus_name() or ""
            if "AlreadyConnected" not in name:
                code = classify_dbus_error(error)
                if code == EXIT_PROFILE:
                    raise HelperError(code, str(error)) from error
                last_error = str(error)

                # A transient NotReady/InProgress/Failed state is retried until
                # the bounded connection timeout expires.
                time.sleep(0.5)
                continue

        connected, interface = network_state(bus, path)
        if connected and interface:
            print(interface, flush=True)
            return interface

        time.sleep(0.25)

    if not saw_device:
        raise HelperError(EXIT_NO_DEVICE, f"device {mac} is not present in BlueZ")
    raise HelperError(EXIT_TIMEOUT, last_error)


def disconnect_device(mac: str) -> None:
    bus = get_bus()
    path = find_device(bus, mac)
    if path is None:
        return

    try:
        network = proxy(bus, path, "org.bluez.Network1")
        network.Disconnect()
    except dbus.DBusException as error:
        name = error.get_dbus_name() or ""
        if "NotConnected" not in name and "DoesNotExist" not in name:
            raise HelperError(EXIT_DBUS, str(error)) from error


def status_device(mac: str) -> int:
    bus = get_bus()
    path = find_device(bus, mac)
    if path is None:
        print("absent")
        return EXIT_NO_DEVICE

    connected, interface = network_state(bus, path)
    if connected and interface:
        print(f"connected {interface}")
        return EXIT_OK

    print("disconnected")
    return EXIT_DISCONNECTED


def watch_device(mac: str, expected_interface: str, profile: str) -> int:
    """Wait for a BlueZ disconnect, with a polling guard for old BlueZ builds."""

    try:
        from dbus.mainloop.glib import DBusGMainLoop
        from gi.repository import GLib
    except ImportError as error:
        raise HelperError(
            EXIT_DBUS,
            "watch requires python3-dbus and python3-gi",
        ) from error

    DBusGMainLoop(set_as_default=True)
    bus = get_bus()
    path = find_device(bus, mac)
    if path is None:
        return EXIT_NO_DEVICE

    loop = GLib.MainLoop()
    result = {"code": EXIT_DISCONNECTED}
    profile_uuid(profile)

    def stop(code: int) -> bool:
        result["code"] = code
        if loop.is_running():
            loop.quit()
        return False

    def properties_changed(interface: str, changed: dict[str, Any], _invalidated: list[str]) -> None:
        if interface != "org.bluez.Network1":
            return
        if "Connected" in changed and not bool(changed["Connected"]):
            stop(EXIT_DISCONNECTED)
        if "Interface" in changed and str(changed["Interface"]) != expected_interface:
            stop(EXIT_DISCONNECTED)

    def disconnected(_reason: str, _message: str) -> None:
        stop(EXIT_DISCONNECTED)

    def check_state() -> bool:
        current_path = find_device(bus, mac)
        if current_path != path:
            return stop(EXIT_DISCONNECTED)
        connected, interface = network_state(bus, path)
        if not connected or interface != expected_interface:
            return stop(EXIT_DISCONNECTED)
        return True

    bus.add_signal_receiver(
        properties_changed,
        signal_name="PropertiesChanged",
        dbus_interface="org.freedesktop.DBus.Properties",
        path=path,
        byte_arrays=True,
    )
    bus.add_signal_receiver(
        disconnected,
        signal_name="Disconnected",
        dbus_interface="org.bluez.Device1",
        path=path,
    )
    GLib.timeout_add_seconds(2, check_state)

    def handle_signal(_signum: int, _frame: Any) -> None:
        stop(EXIT_OK)

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)
    loop.run()
    return result["code"]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    connect = subparsers.add_parser("connect")
    connect.add_argument("mac")
    connect.add_argument("--profile", default="nap")
    connect.add_argument("--timeout", type=float, default=20.0)

    disconnect = subparsers.add_parser("disconnect")
    disconnect.add_argument("mac")

    status = subparsers.add_parser("status")
    status.add_argument("mac")

    watch = subparsers.add_parser("watch")
    watch.add_argument("mac")
    watch.add_argument("--profile", default="nap")
    watch.add_argument("--interface", required=True)

    return parser.parse_args()


def main() -> int:
    args = parse_args()
    mac = normalise_mac(args.mac)

    if args.command == "connect":
        connect_device(mac, args.profile, max(1.0, args.timeout))
        return EXIT_OK
    if args.command == "disconnect":
        disconnect_device(mac)
        return EXIT_OK
    if args.command == "status":
        return status_device(mac)
    if args.command == "watch":
        return watch_device(mac, args.interface, args.profile)

    return EXIT_USAGE


if __name__ == "__main__":
    try:
        sys.exit(main())
    except HelperError as error:
        print(f"bluez-pan-connect: {error}", file=sys.stderr)
        sys.exit(error.code)
    except dbus.DBusException as error:
        print(f"bluez-pan-connect: D-Bus error: {error}", file=sys.stderr)
        sys.exit(EXIT_DBUS)
