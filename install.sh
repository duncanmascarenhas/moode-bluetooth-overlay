#!/usr/bin/env bash
set -e

if [ "$EUID" -ne 0 ]; then
  echo "[!] Please run as root: sudo bash install_v2.sh"
  exit 1
fi

echo "========================================================"
echo " Installing Moode Premium Bluetooth Overlay V2.13"
echo " Added: Inline Top Bar & Glassmorphism Depth"
echo "========================================================"

echo "==> [1/6] Terminating zombie processes..."
systemctl stop moode-bt-art.service 2>/dev/null || true
killall bluez_art.py 2>/dev/null || true

echo "==> [2/6] Creating native Python D-Bus listener (/usr/local/bin/bluez_art.py)..."
cat << 'PYEOF' > /usr/local/bin/bluez_art.py
import dbus, dbus.mainloop.glib, json, subprocess, threading, time
from gi.repository import GLib

META_PATH = "/var/www/images/bt_meta.json"
DEFAULT_COVER = "/images/default-radio-cover.jpg"

current_track_id = 0
last_device_name = "Bluetooth Device"

def get_device_name(path):
    try:
        bus = dbus.SystemBus()
        dev_path = path.rsplit('/', 1)[0]
        props = dbus.Interface(bus.get_object("org.bluez", dev_path), "org.freedesktop.DBus.Properties")
        return str(props.Get("org.bluez.Device1", "Alias"))
    except: return "Bluetooth Device"

def fetch_moode_artwork(artist, title):
    if not title and not artist: return DEFAULT_COVER
    
    search_title = f"{artist} - {title}" if artist and title else (title or artist)
    search_title_sql = search_title.replace("'", "''")
    
    try:
        cmd = f'moodeutl -q "SELECT cover_url FROM cfg_rcucache WHERE title = \'{search_title_sql}\'"'
        res = subprocess.check_output(cmd, shell=True, text=True, timeout=5).strip()
        if res.startswith("http") or res.startswith("/"): return res
    except: pass
    
    try:
        cmd = ['sudo', '/var/www/util/radiocover_plus.py', '--title', search_title, '--station', '']
        res = subprocess.check_output(cmd, text=True, timeout=12).strip()
        if res.startswith("http"): return res
    except: pass
    
    return DEFAULT_COVER

def background_art_fetch(artist, title, album, task_id, device):
    global current_track_id
    try:
        cover_url = fetch_moode_artwork(artist, title)
        if task_id == current_track_id:
            with open(META_PATH, 'w') as f:
                json.dump({"title": title, "artist": artist, "album": album, "cover_url": cover_url, "device": device}, f)
    except: pass

def update_meta(artist, title, album, status="playing", device=""):
    global current_track_id, last_device_name
    current_track_id += 1
    this_task_id = current_track_id
    
    if device: last_device_name = device
    
    artist = artist.strip() if artist else ""
    title = title.strip() if title else ""
    album = album.strip() if album else ""
    
    if title.lower() in ["not provided", "unknown"]: title = ""
    if artist.lower() in ["not provided", "unknown"]: artist = ""
    
    try:
        if status == "stopped" or (not title and not artist):
            with open(META_PATH, 'w') as f:
                json.dump({"title": "Playback Stopped" if status == "stopped" else "No Track Playing", 
                           "artist": "", "album": "", "cover_url": DEFAULT_COVER, "device": last_device_name}, f)
            return
            
        with open(META_PATH, 'w') as f:
            json.dump({"title": title, "artist": artist, "album": album, "cover_url": DEFAULT_COVER, "device": last_device_name}, f)
            
        t = threading.Thread(target=background_art_fetch, args=(artist, title, album, this_task_id, last_device_name))
        t.start()
    except: pass

def on_property_changed(interface, changed, invalidated, path):
    try:
        if interface != "org.bluez.MediaPlayer1": return
        
        device_name = get_device_name(path)
        
        if "Status" in changed:
            status = str(changed["Status"])
            if status == "stopped":
                update_meta("", "", "", "stopped", device_name)
                return
            elif status in ["playing", "paused"] and "Track" not in changed:
                try:
                    bus = dbus.SystemBus()
                    props = dbus.Interface(bus.get_object("org.bluez", path), "org.freedesktop.DBus.Properties")
                    changed["Track"] = props.Get("org.bluez.MediaPlayer1", "Track")
                except: pass

        if "Track" in changed:
            t = changed["Track"]
            update_meta(str(t.get("Artist", "")), str(t.get("Title", "")), str(t.get("Album", "")), "playing", device_name)
    except Exception as e:
        pass 

def on_interfaces_removed(path, interfaces):
    try:
        if "org.bluez.MediaPlayer1" in interfaces:
            update_meta("", "", "", "stopped")
    except: pass

if __name__ == "__main__":
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SystemBus()
    bus.add_signal_receiver(on_property_changed, bus_name="org.bluez", signal_name="PropertiesChanged", dbus_interface="org.freedesktop.DBus.Properties", path_keyword="path")
    bus.add_signal_receiver(on_interfaces_removed, bus_name="org.bluez", signal_name="InterfacesRemoved", dbus_interface="org.freedesktop.DBus.ObjectManager")
    update_meta("", "", "", "stopped")
    try: GLib.MainLoop().run()
    except KeyboardInterrupt: pass
PYEOF
chmod 755 /usr/local/bin/bluez_art.py

echo "==> [3/6] Creating resilient systemd service..."
cat << 'SVCEOF' > /etc/systemd/system/moode-bt-art.service
[Unit]
Description=Moode Bluetooth Artwork Fetcher
After=bluetooth.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/bluez_art.py
Restart=always
RestartSec=3
StartLimitIntervalSec=0
User=root

[Install]
WantedBy=multi-user.target
SVCEOF
systemctl daemon-reload && systemctl enable moode-bt-art.service

echo "==> [4/6] Deploying native-URL frontend script..."
cat << 'JSEOF' > /var/www/js/bt-overlay.js
(function(){
    "use strict";
    var lastCoverUrl = "";
    var refreshBusy = false;

    function installStyles() {
        if (!document.getElementById("custom-bt-style")) {
            var t = document.createElement("style");
            t.id = "custom-bt-style";
            t.textContent = 
                "body.bt-scroll-lock { overflow: hidden !important; touch-action: none !important; }\n" +
                "#inpsrc-indicator.custom-bt-active { position: fixed !important; top: 0 !important; left: 0 !important; width: 100vw !important; height: 100vh !important; z-index: 99999 !important; overflow: hidden !important; background-position: center !important; background-size: cover !important; }\n" +
                "#inpsrc-indicator.custom-bt-active #inpsrc-msg, #inpsrc-indicator.custom-bt-active #inpsrc-backdrop, #inpsrc-indicator.custom-bt-active #inpsrc-cover, #inpsrc-indicator.custom-bt-active #inpsrc-metadata-parent, #inpsrc-indicator.custom-bt-active #inpsrc-metadata-refresh { display: none !important; }\n" +
                "#custom-bt-ui { position: absolute; inset: 0; z-index: 1000; box-sizing: border-box; display: flex; flex-direction: column; align-items: center; justify-content: center; padding: 80px 20px 20px 20px; overflow: hidden; color: #fff; text-align: center; font-family: system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; background: linear-gradient(180deg, rgba(0, 0, 0, 0.6), rgba(0, 0, 0, 0.9)); backdrop-filter: blur(40px) saturate(150%); -webkit-backdrop-filter: blur(40px) saturate(150%); }\n" +
                "#custom-bt-topbar { position: absolute; top: 0; left: 0; width: 100%; box-sizing: border-box; display: grid; grid-template-columns: 1fr auto 1fr; align-items: center; padding: clamp(10px, 2vh, 18px) clamp(15px, 4vw, 30px); background: linear-gradient(180deg, rgba(255,255,255,0.08), rgba(255,255,255,0.01)); border-bottom: 1px solid rgba(255,255,255,0.1); box-shadow: 0 4px 20px rgba(0,0,0,0.3); z-index: 1001; }\n" +
                "#custom-bt-top-left { display: flex; align-items: center; gap: 8px; justify-self: start; }\n" +
                "#custom-bt-status { display: flex; align-items: center; color: var(--thm-prim, #60a5fa); font-size: clamp(0.7rem, 1.5vw, 0.85rem); font-weight: 700; letter-spacing: 0.1em; text-transform: uppercase; white-space: nowrap; }\n" +
                "#custom-bt-status svg { width: 1.3em; height: 1.3em; margin-right: 6px; }\n" +
                "#custom-bt-divider { color: rgba(255,255,255,0.4); font-size: 1rem; line-height: 1; }\n" +
                "#custom-bt-device { font-size: clamp(0.8rem, 1.8vw, 0.95rem); font-weight: 500; color: #d1d5db; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 25vw; }\n" +
                "#custom-bt-clock { justify-self: center; font-size: clamp(0.9rem, 2vw, 1.1rem); font-weight: 500; text-shadow: 0 2px 4px rgba(0,0,0,0.5); letter-spacing: 0.5px; }\n" +
                "#custom-bt-weather { justify-self: end; display: flex; align-items: center; font-size: clamp(0.9rem, 2vw, 1.1rem); font-weight: 500; text-shadow: 0 2px 4px rgba(0,0,0,0.5); letter-spacing: 0.5px; }\n" +
                "#custom-bt-art { display: block; width: min(75vw, 400px); height: min(75vw, 400px); object-fit: cover; margin-bottom: 25px; border-radius: 12px; box-shadow: 0 20px 50px rgba(0, 0, 0, 0.6); }\n" +
                "#custom-bt-text { display: flex; flex-direction: column; align-items: center; width: 100%; max-width: 900px; gap: 6px; }\n" +
                "#custom-bt-title { width: 100%; font-size: clamp(1.6rem, 5vw, 2.6rem); font-weight: 800; line-height: 1.15; overflow-wrap: anywhere; text-shadow: 0 2px 8px rgba(0, 0, 0, 0.6); margin: 0; }\n" +
                "#custom-bt-artist { width: 100%; color: #e5e7eb; font-size: clamp(1.1rem, 3.5vw, 1.6rem); font-weight: 600; overflow-wrap: anywhere; text-shadow: 0 1px 4px rgba(0, 0, 0, 0.5); margin: 0; }\n" +
                "#custom-bt-album { width: 100%; color: #9ca3af; font-size: clamp(0.9rem, 2.5vw, 1.2rem); font-weight: 400; overflow-wrap: anywhere; margin: 0; }\n" +
                "@media (orientation: landscape) and (max-height: 700px) {\n" +
                "    #custom-bt-ui { flex-direction: row; justify-content: center; align-items: center; gap: clamp(30px, 5vw, 70px); }\n" +
                "    #custom-bt-art { width: min(55vh, 400px); height: min(55vh, 400px); margin-bottom: 0; }\n" +
                "    #custom-bt-text { align-items: flex-start; text-align: left; max-width: 50vw; }\n" +
                "}";
            document.head.appendChild(t);
        }
    }

    function updateClockAndWeather() {
        var clockEl = document.getElementById("custom-bt-clock");
        if (clockEl) {
            var now = new Date();
            clockEl.textContent = now.toLocaleTimeString([], {hour: '2-digit', minute:'2-digit'});
        }
        fetch("https://api.open-meteo.com/v1/forecast?latitude=12.87&longitude=74.84&current_weather=true")
            .then(function(res){ return res.json(); })
            .then(function(data){
                var weatherEl = document.getElementById("custom-bt-weather");
                if (weatherEl && data.current_weather) {
                    var isDay = data.current_weather.is_day === 1;
                    var sunSvg = '<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="vertical-align: -4px; margin-right: 6px; opacity: 0.9;"><circle cx="12" cy="12" r="4"></circle><path d="M12 2v2"></path><path d="M12 20v2"></path><path d="m4.93 4.93 1.41 1.41"></path><path d="m17.66 17.66 1.41 1.41"></path><path d="M2 12h2"></path><path d="M20 12h2"></path><path d="m6.34 17.66-1.41 1.41"></path><path d="m19.07 4.93-1.41 1.41"></path></svg>';
                    var moonSvg = '<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="vertical-align: -4px; margin-right: 6px; opacity: 0.9;"><path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"></path></svg>';
                    weatherEl.innerHTML = (isDay ? sunSvg : moonSvg) + Math.round(data.current_weather.temperature) + "°C";
                }
            }).catch(function(){});
    }

    function buildUI(){
        var t = document.getElementById("inpsrc-indicator");
        if (t && !document.getElementById("custom-bt-ui")) {
            var e = document.createElement("div");
            e.id = "custom-bt-ui";
            e.innerHTML = 
                '<div id="custom-bt-topbar">' +
                    '<div id="custom-bt-top-left">' +
                        '<div id="custom-bt-status">' +
                            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="6.5 6.5 17.5 17.5 12 23 12 1 17.5 6.5 6.5 17.5"></polyline></svg>' +
                            '<span>Bluetooth Audio</span>' +
                        '</div>' +
                        '<span id="custom-bt-divider">&bull;</span>' +
                        '<div id="custom-bt-device">Connecting...</div>' +
                    '</div>' +
                    '<div id="custom-bt-clock"></div>' +
                    '<div id="custom-bt-weather"></div>' +
                '</div>' +
                '<img id="custom-bt-art" src="/images/default-radio-cover.jpg" alt="Album artwork">' +
                '<div id="custom-bt-text">' +
                    '<div id="custom-bt-title">Connecting...</div>' +
                    '<div id="custom-bt-artist"></div>' +
                    '<div id="custom-bt-album"></div>' +
                '</div>';
            t.appendChild(e);
            updateClockAndWeather();
            setInterval(updateClockAndWeather, 60000);
        }
    }

    function isBluetoothActive(){
        var t = document.getElementById("inpsrc-indicator"), e = document.getElementById("inpsrc-msg");
        if (!t) return false;
        var n = "none" !== window.getComputedStyle(t).display, o = e ? e.textContent : "";
        return n && (-1 !== o.indexOf("Bluetooth Active") || t.classList.contains("custom-bt-active"));
    }

    function activateUI(){
        var t = document.getElementById("inpsrc-indicator");
        if (t) {
            installStyles();
            buildUI();
            t.classList.add("custom-bt-active");
            document.body.classList.add("bt-scroll-lock");
        }
    }

    function deactivateUI(){
        var t = document.getElementById("inpsrc-indicator"), e = document.getElementById("custom-bt-ui");
        if (t) {
            t.classList.remove("custom-bt-active");
            t.style.backgroundImage = "";
        }
        if (e) e.remove();
        document.body.classList.remove("bt-scroll-lock");
        lastCoverUrl = "";
    }

    function fetchMetadata(){
        if (isBluetoothActive() && !refreshBusy) {
            refreshBusy = true;
            activateUI();
            fetch("/images/bt_meta.json?t=" + Date.now(), {cache: "no-store"})
                .then(function(t) { if (!t.ok) throw new Error("Metadata error"); return t.json(); })
                .then(function(t) {
                    var e = document.getElementById("custom-bt-title"), 
                        n = document.getElementById("custom-bt-artist"), 
                        o = document.getElementById("custom-bt-album"),
                        d = document.getElementById("custom-bt-device");
                    if (e) e.textContent = t.title || "Unknown Track";
                    if (n) n.textContent = t.artist || "";
                    if (o) o.textContent = (t.album && t.album !== t.title) ? t.album : "";
                    if (d) d.textContent = t.device || "Bluetooth Device";
                    
                    if (t.cover_url && t.cover_url !== lastCoverUrl) {
                        lastCoverUrl = t.cover_url;
                        var i = new Image();
                        i.onload = function() {
                            var art = document.getElementById("custom-bt-art"), bg = document.getElementById("inpsrc-indicator");
                            if (art) art.src = lastCoverUrl;
                            if (bg) bg.style.backgroundImage = 'url("' + lastCoverUrl + '")';
                        };
                        i.src = t.cover_url;
                    }
                })
                .catch(function() {})
                .finally(function() { refreshBusy = false; });
        }
    }

    function reconcileState(){ isBluetoothActive() ? (activateUI(), fetchMetadata()) : deactivateUI(); }
    
    function initialize(){
        var t = document.getElementById("inpsrc-indicator");
        if (t) {
            new MutationObserver(function() { window.requestAnimationFrame(reconcileState); }).observe(t, {childList: true, subtree: true, attributes: true, attributeFilter: ["style", "class"]});
            reconcileState();
            window.setInterval(function() { if (isBluetoothActive()) fetchMetadata(); }, 1200);
        }
    }
    
    "loading" === document.readyState ? document.addEventListener("DOMContentLoaded", initialize) : initialize();
})();
JSEOF
chmod 644 /var/www/js/bt-overlay.js

echo "==> [5/6] Linking script in /var/www/header.php..."
if ! grep -q "bt-overlay.js" /var/www/header.php; then
  sed -i '/<\/head>/i <script src="/js/bt-overlay.js?v=2" defer></script>' /var/www/header.php
fi

echo "==> [6/6] Starting robust services..."
systemctl restart moode-bt-art.service

echo "--------------------------------------------------------"
echo " Installation Complete! Rebooting in 5 seconds..."
echo "--------------------------------------------------------"
sleep 5
sudo reboot
