# LAN Scanner

A small native macOS app for scanning the local LAN and spotting devices such as Raspberry Pi, Homebridge, MQTT brokers, Home Assistant, and Node-RED.

## Current version

- Detects the active private IPv4 network.
- Scans the `/24` subnet with ping.
- Reads MAC addresses from ARP when available.
- Shows hostname, IP, MAC/vendor, response time, and last seen time.
- Detects common services on ports `22`, `80`, `443`, `1883`, `8581`, `1880`, and `8123`.
- Highlights likely Raspberry Pi devices by hostname, MAC prefix, or vendor.
- Supports light/dark with `fn+F6`.
- Supports hard/grass/clay themes with `fn+F3`.

## Build

```bash
swift build
Scripts/build-app.sh
```

The app bundle is created at:

```text
dist/LAN Scanner.app
```
