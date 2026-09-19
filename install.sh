#!/usr/bin/env bash
set -e

# ==============================================================================
# Moode Audio Premium Bluetooth Overlay
# Created by: Duncan Mascarenhas | Nexus One Solutions
# License: MIT License (Open Source)
# Compatibility: Tested on Moode Audio v10.3.4
# ==============================================================================

if [ "$EUID" -ne 0 ]; then
  echo "[!] Please run as root: sudo bash install.sh"
  exit 1
fi

echo "========================================================"
echo " Installing Moode Premium Bluetooth Overlay..."
echo " Created by Duncan Mascarenhas | Nexus One Solutions"
echo "========================================================"

echo "==> [1/5] Creating background Python service (/usr/local/bin/bluez_art.py)..."
cat << 'PYEOF' > /usr/local/bin/bluez_art.py
import dbus, dbus.mainloop.glib, urllib.parse, urllib.request, json, re, os, shutil, time
from gi.repository import GLib

COVER_ART_PATH = "/var/www/images/bluetooth.png"
META_PATH = "/var/www/images/bt_meta.json"
DEFAULT_COVER = "/var/www/images/default-radio-cover.jpg"

def clean_string(text):
    if not text: return ""
    text = re.sub(r'\|.*$', '', text)
    text = re.sub(r'\[.*?\]', '', text)
    text = re.sub(r'\(.*?(official|video|audio|lyrics|feat|ft).*?\)', '', text, flags=re.I)
    return text.strip()

def search_itunes(query):
    url = f"https://itunes.apple.com/search?term={urllib.parse.quote(query)}&entity=song&limit=1"
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'}), timeout=4) as resp:
            data = json.loads(resp.read().decode())
            if data.get('resultCount', 0) > 0:
                return data['results'][0]['artworkUrl100'].replace('100x100bb', '600x600bb')
    except: pass
    return None

def fetch_artwork(artist, title, album):
    clean_t, clean_a = clean_string(title), clean_string(artist)
    url = None
    if clean_a and clean_t: url = search_itunes(f"{clean_a} {clean_t}")
    if not url and clean_t: url = search_itunes(clean_t)
    if not url and clean_a and album and album != title: url = search_itunes(f"{clean_a} {clean_string(album)}")

    updated = False
    if url:
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'}), timeout=5) as resp, open(COVER_ART_PATH, 'wb') as f:
                f.write(resp.read())
            updated = True
        except: pass

    if not updated and os.path.exists(DEFAULT_COVER): shutil.copyfile(DEFAULT_COVER, COVER_ART_PATH)

    with open(META_PATH, 'w') as f: json.dump({"title": title or "Unknown", "artist": artist or "", "album": album or "", "art_time": int(time.time())}, f)

def on_property_changed(interface, changed, invalidated, path):
    if interface == "org.bluez.MediaPlayer1" and "Track" in changed:
        t = changed["Track"]
        if t.get("Artist", "") or t.get("Title", ""): fetch_artwork(str(t.get("Artist", "")), str(t.get("Title", "")), str(t.get("Album", "")))

if __name__ == "__main__":
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SystemBus()
    bus.add_signal_receiver(on_property_changed, bus_name="org.bluez", signal_name="PropertiesChanged", dbus_interface="org.freedesktop.DBus.Properties", path_keyword="path")
    try: GLib.MainLoop().run()
    except KeyboardInterrupt: pass
PYEOF
chmod 755 /usr/local/bin/bluez_art.py

echo "==> [2/5] Creating and starting systemd service..."
cat << 'SVCEOF' > /etc/systemd/system/moode-bt-art.service
[Unit]
Description=Moode Bluetooth Artwork Fetcher (by Nexus One Solutions)
After=bluetooth.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/bluez_art.py
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
SVCEOF
systemctl daemon-reload && systemctl enable moode-bt-art.service && systemctl restart moode-bt-art.service

echo "==> [3/5] Deploying frontend UI script (/var/www/js/bt-overlay.js)..."
cat << 'JSEOF' > /var/www/js/bt-overlay.js
(function(){"use strict";var lastArtTime=0,refreshBusy=!1;function installStyles(){if(!document.getElementById("custom-bt-style")){var t=document.createElement("style");t.id="custom-bt-style",t.textContent="\n            body.bt-scroll-lock { overflow: hidden !important; touch-action: none !important; }\n            #inpsrc-indicator.custom-bt-active { position: fixed !important; top: 0 !important; left: 0 !important; width: 100vw !important; height: 100vh !important; height: 100dvh !important; z-index: 99999 !important; overflow: hidden !important; background-position: center !important; background-size: cover !important; }\n            #inpsrc-indicator.custom-bt-active #inpsrc-msg,\n            #inpsrc-indicator.custom-bt-active #inpsrc-backdrop,\n            #inpsrc-indicator.custom-bt-active #inpsrc-cover,\n            #inpsrc-indicator.custom-bt-active #inpsrc-metadata-parent,\n            #inpsrc-indicator.custom-bt-active #inpsrc-metadata-refresh { display: none !important; }\n            #custom-bt-ui { position: absolute; inset: 0; z-index: 1000; box-sizing: border-box; display: flex; flex-direction: column; align-items: center; justify-content: center; padding: max(20px, env(safe-area-inset-top)) max(20px, env(safe-area-inset-right)) max(20px, env(safe-area-inset-bottom)) max(20px, env(safe-area-inset-left)); overflow: hidden; color: #fff; text-align: center; font-family: sans-serif; background: linear-gradient(180deg, rgba(0, 0, 0, 0.45), rgba(0, 0, 0, 0.75)); backdrop-filter: blur(30px) saturate(140%); -webkit-backdrop-filter: blur(30px) saturate(140%); }\n            #custom-bt-status { display: flex; align-items: center; margin-bottom: clamp(16px, 3.5vh, 36px); color: #60a5fa; font-size: clamp(0.8rem, 2.2vw, 1.1rem); font-weight: 700; letter-spacing: 0.15em; text-transform: uppercase; }\n            #custom-bt-status svg { width: 1.4em; height: 1.4em; margin-right: 8px; }\n            #custom-bt-art { display: block; width: min(70vw, 380px); height: auto; max-height: 46vh; margin-bottom: clamp(16px, 3.5vh, 36px); object-fit: contain; border-radius: 14px; box-shadow: 0 20px 50px rgba(0, 0, 0, 0.6); }\n            #custom-bt-title { max-width: 900px; margin-bottom: 0.3em; font-size: clamp(1.4rem, 4.5vw, 2.4rem); font-weight: 750; line-height: 1.15; overflow-wrap: anywhere; text-shadow: 0 2px 5px rgba(0, 0, 0, 0.6); }\n            #custom-bt-artist { max-width: 900px; margin-bottom: 0.2em; color: #e5e7eb; font-size: clamp(1rem, 3.2vw, 1.45rem); font-weight: 550; overflow-wrap: anywhere; }\n            #custom-bt-album { max-width: 900px; color: #9ca3af; font-size: clamp(0.85rem, 2.2vw, 1.1rem); overflow-wrap: anywhere; }\n            @media (orientation: landscape) and (max-height: 600px) {\n                #custom-bt-ui { display: grid; grid-template-columns: minmax(180px, 36vw) 1fr; grid-template-rows: auto auto auto auto; column-gap: clamp(20px, 4vw, 50px); }\n                #custom-bt-status { grid-column: 2; margin-bottom: 15px; justify-self: center; }\n                #custom-bt-art { grid-column: 1; grid-row: 1 / 5; width: min(34vw, 340px); max-height: 75vh; margin: 0; align-self: center; justify-self: center; }\n                #custom-bt-title, #custom-bt-artist, #custom-bt-album { grid-column: 2; }\n            }\n        ",document.head.appendChild(t)}}function buildUI(){var t=document.getElementById("inpsrc-indicator");if(t&&!document.getElementById("custom-bt-ui")){var e=document.createElement("div");e.id="custom-bt-ui",e.innerHTML='\n            <div id="custom-bt-status">\n                <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="6.5 6.5 17.5 17.5 12 23 12 1 17.5 6.5 6.5 17.5"></polyline></svg>\n                <span>Bluetooth Audio</span>\n            </div>\n            <img id="custom-bt-art" src="/images/bluetooth.png" alt="Album artwork">\n            <div id="custom-bt-title">Connecting...</div>\n            <div id="custom-bt-artist"></div>\n            <div id="custom-bt-album"></div>\n        ',t.appendChild(e)}}function isBluetoothActive(){var t=document.getElementById("inpsrc-indicator"),e=document.getElementById("inpsrc-msg");if(!t)return!1;var n="none"!==window.getComputedStyle(t).display,o=e?e.textContent:"";return n&&(-1!==o.indexOf("Bluetooth Active")||t.classList.contains("custom-bt-active"))}function activateUI(){var t=document.getElementById("inpsrc-indicator");t&&(installStyles(),buildUI(),t.classList.add("custom-bt-active"),document.body.classList.add("bt-scroll-lock"))}function deactivateUI(){var t=document.getElementById("inpsrc-indicator"),e=document.getElementById("custom-bt-ui");t&&(t.classList.remove("custom-bt-active"),t.style.backgroundImage=""),e&&e.remove(),document.body.classList.remove("bt-scroll-lock"),lastArtTime=0}function fetchMetadata(){if(isBluetoothActive()&&!refreshBusy){refreshBusy=!0,activateUI();fetch("/images/bt_meta.json?t="+Date.now(),{cache:"no-store"}).then((t=>{if(!t.ok)throw new Error("Metadata error");return t.json()})).then((t=>{var e=document.getElementById("custom-bt-title"),n=document.getElementById("custom-bt-artist"),o=document.getElementById("custom-bt-album");if(e&&(e.textContent=t.title||"Unknown Track"),n&&(n.textContent=t.artist||""),o&&(o.textContent=t.album&&t.album!==t.title?t.album:""),t.art_time&&t.art_time!==lastArtTime){lastArtTime=t.art_time;var i="/images/bluetooth.png?t="+t.art_time,a=new Image;a.onload=function(){var t=document.getElementById("custom-bt-art"),e=document.getElementById("inpsrc-indicator");t&&(t.src=i),e&&(e.style.backgroundImage='url("'+i+'")')},a.src=i}})).catch((t=>{})).finally((()=>refreshBusy=!1))}}function reconcileState(){isBluetoothActive()?(activateUI(),fetchMetadata()):deactivateUI()}function initialize(){var t=document.getElementById("inpsrc-indicator");t&&(new MutationObserver((()=>window.requestAnimationFrame(reconcileState))).observe(t,{childList:!0,subtree:!0,attributes:!0,attributeFilter:["style","class"]}),reconcileState(),window.setInterval((()=>{isBluetoothActive()&&fetchMetadata()}),1200))}"loading"===document.readyState?document.addEventListener("DOMContentLoaded",initialize):initialize()})();
JSEOF
chmod 644 /var/www/js/bt-overlay.js

echo "==> [4/5] Linking script in /var/www/header.php..."
if ! grep -q "bt-overlay.js" /var/www/header.php; then
  sed -i '/<\/head>/i <script src="/js/bt-overlay.js?v=1" defer></script>' /var/www/header.php
fi

echo "==> [5/5] Ensuring permissions..."
chown -R www-data:www-data /var/www/images /var/www/js 2>/dev/null || true

echo "--------------------------------------------------------"
echo " Installation Complete! Please hard refresh your browser."
echo "--------------------------------------------------------"
