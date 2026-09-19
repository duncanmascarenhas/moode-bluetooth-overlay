# Moode Audio Premium Bluetooth Dashboard
A responsive, high-end "frosted glass" Bluetooth screen for Moode Audio. It silently listens to your Bluetooth streams in the background, fetches high-resolution album artwork from the Apple Music API, and dynamically injects a scalable layout over Moode's default Bluetooth placeholder screen.

### 🌟 Features
* **Dynamic Artwork:** Fetches High-Res album covers instantly from Apple Music.
* **Smart Cleaning:** Removes YouTube noise (e.g., `[Official Video]`, `|`) from titles for better search matching.
* **Fully Responsive:** Scales perfectly on mobile browsers, tablets, and local desktop displays using CSS clamping.
* **Non-Destructive:** Leverages a custom JavaScript observer without ruining Moode's core templates.

### ⚠️ Disclaimer
**Compatibility:** Tested on **Moode Audio v10.3.4**.  
This script edits your `/var/www/header.php` file to load the custom UI. While designed to be lightweight and safe, it is provided "as is" under the MIT license. Future Moode updates may overwrite `header.php`, requiring you to re-run the installer.

### 🚀 How to Install
Run this single command in your Raspberry Pi's SSH terminal:

```bash
curl -sSL [https://raw.githubusercontent.com/duncanmascarenhas/moode-bluetooth-overlay/main/install.sh](https://raw.githubusercontent.com/duncanmascarenhas/moode-bluetooth-overlay/main/install.sh) | sudo bash

(After installing, simply clear your phone/desktop web browser cache and play a song over Bluetooth!)

Credits & License
Created by Duncan Mascarenhas | Nexus One Solutions

Released under the MIT License.
