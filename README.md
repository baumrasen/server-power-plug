# Tasmota32 Proxmox Hardware-Watchdog (Berry Script)

Ein autarker, zweistufiger Hardware-Watchdog in **Berry** für Tasmota32-Messsteckdosen (ESP32), entwickelt zur Überwachung und automatischen Wiederherstellung eines **Proxmox VE Servers** bei Systemabstürzen, Kernel-Panics oder NVMe/SSD-I/O-Freezes (z. B. durch Überhitzung während intensiver Backup-Läufe).

# note

Code created by Gemini Argon

---

## 🎯 Hintergrund & Funktionsweise

Wenn sich eine NVMe/SSD unter hoher Last (wie einem `vzdump`-Backup) überhitzt oder kurzzeitig vom PCIe-Bus abmeldet, schaltet sich ein Server oft **nicht** klassisch aus (Soft-Off), sondern friert in einem harten **Kernel-/I/O-Lockup** ein. Da die CPU-Kerne in diesem Zustand nicht mehr in die Schlafzustände (C-States) wechseln, verharrt der Server bei einer **konstant hohen Leistungsaufnahme ("Flatline")** und ist über das Netzwerk nicht mehr erreichbar.

Ein reiner Netzwerk-Check (Ping/HTTP) wäre als alleiniges Kriterium für das harte Trennen des Stroms viel zu gefährlich: Fällt lediglich ein Switch, das WLAN oder ein Dienst kurz aus, während der Server normal arbeitet oder gerade ein Dateisystem-Update durchführt, würde ein simpler Watchdog das Dateisystem durch Stromtrennen beschädigen.

### Die 3-Faktoren-Erkennung dieses Skripts
Dieses Berry-Skript läuft komplett unabhängig direkt auf dem ESP32 der Messsteckdose und kombiniert **Netzwerkstatus** und **Leistungsprofil**:

1. **Proxmox Health-Check (Port 8006):** Prüft im eingestellten Intervall (Standard: 60s) den leichtgewichtigen, unauthentifizierten Endpunkt `/api2/json/access/domains` des Proxmox-Servers.
2. **Leistungsprofil-Analyse (Freeze vs. Normalbetrieb vs. Boot):**
   * **Normalbetrieb ohne Netzwerk (`~45–70 W`):** Antwortet Proxmox nicht, aber der Stromverbrauch liegt im normalen Arbeitsbereich, unternimmt der Watchdog **nichts** (Schutz bei reinem Netzwerk-/Switch-Ausfall).
   * **Aktiver Reboot / Dynamische Last (`Delta > 3 W`):** Schwankt die Leistung stark zwischen zwei Messpunkten, erkennt das Skript aktive Arbeit (z. B. einen laufenden Bootvorgang) und greift **nicht** ein.
   * **Freeze-Zustand (`>= 75 W` & `Delta <= 3 W`):** Antwortet Port 8006 nicht **und** die Leistungsaufnahme klebt starr auf hohem Niveau (typisch für I/O-Freeze/Kernel-Panic), zählt der Fehlerzähler hoch.
   * **Soft-Off-Zustand (`< 15 W`):** Hat sich der Server komplett abgeschaltet (S5 Standby), zählt der Fehlerzähler ebenfalls hoch.

---

## 🛡️ Zweistufige Eskalation & Schutzmechanismen

Tritt ein erkannter Fehlerzustand dauerhaft auf, eskaliert das Skript in zwei Stufen:

* **Stufe 1 – Sanfter API-Reboot (Standard: nach 3 Minuten):**
  Im Freeze-Zustand versucht die Steckdose zuerst, über die offizielle Proxmox REST-API (`POST /api2/json/nodes/{node}/status` mit `command=reboot`) einen sauberen Systemneustart auszulösen. Reagiert der Kernel darauf, erkennt das Skript die anschließenden Leistungsschwankungen beim Booten und bricht den Countdown für Stufe 2 automatisch ab.
* **Stufe 2 – Harter Power-Cycle (Standard: nach 5 Minuten):**
  Reagiert auch die Proxmox-API nicht mehr (oder befindet sich der Server im Soft-Off), schaltet die Steckdose das Relais für **15 Sekunden** stromlos (Reset für Netzteil und SSD-Controller) und danach wieder ein.
* **Boot-Cooldown & Endlosschleifen-Schutz (`Reboot Lock`):**
  Nach einem Power-Cycle pausiert die Überwachung für **8 Minuten**, damit der Server in Ruhe booten kann. Kommt der Server auch nach dem Power-Cycle nicht wieder hoch, sperrt sich der Watchdog (`LOCKED_After_Reboot`), um ständiges Ein- und Ausschalten bei einem echten Hardwaredefekt zu verhindern. Die Sperre löst sich erst, wenn Proxmox mindestens einmal wieder regulär erreichbar war.
* **Uptime Kuma Integration:**
  Nach jedem Prüfzyklus sendet die Steckdose einen Heartbeat an einen **Uptime Kuma Push-Monitor** – inklusive des aktuellen Watchdog-Status als Textmeldung (`msg`) und der aktuellen Leistungsaufnahme in Watt im `ping`-Feld (wodurch Uptime Kuma automatisch einen Stromverbrauchs-Graphen zeichnet).

---

## 📋 Voraussetzungen

1. **Steckdose:** Tasmota-Steckdose mit **ESP32-Chip** (Tasmota32 mit integriertem Berry Scripting und LittleFS-Dateisystem) sowie Energiemessung (z. B. Nous A8T mit ESP32, Shelly Plug S Gen3 (?) o. Ä.).
2. **Server-BIOS:** Im BIOS/UEFI des Proxmox-Servers muss unter *APM / Power Management* die Option **`Restore on AC Power Loss`** zwingend auf **`Power On`** (Always On) stehen, damit der Server automatisch hochfährt, sobald die Steckdose den Strom wieder einschaltet.

---

## 🚀 Installation & Einrichtung

### 1. Proxmox API-Token erstellen (für Stufe 1: Sanfter Reboot)
1. In der Proxmox-Weboberfläche auf **Rechenzentrum (Datacenter) -> Berechtigungen -> API-Tokens** wechseln.
2. Auf **Hinzufügen** klicken:
   * **Benutzer:** `root@pam`
   * **Token-ID:** `watchdog`
   * **Privilege Separation:** Haken entfernen *(oder alternativ dem Token unter "Berechtigungen" auf dem Pfad `/nodes/<DEIN_NODE>` die Rolle mit dem Recht `Sys.PowerMgmt` zuweisen)*.
3. Das angezeigte **Token-Secret** kopieren und im folgenden Format für die `config.json` bereithalten:
   `PVEAPIToken=root@pam!watchdog=DEIN-SECRET-UUID`

### 2. Tasmota Grundeinstellungen setzen
Öffne auf der Tasmota-Steckdose **Consoles -> Console** und führe einmalig folgende Befehle aus:

```text
Backlog PowerOnState 1; SetOption132 0
```
* `PowerOnState 1`: Stellt sicher, dass das Relais der Steckdose nach einem echten Haus-Stromausfall immer sofort eingeschaltet wird.
* `SetOption132 0`: Erlaubt `webclient()` Verbindungen zu HTTPS-Endpunkten mit selbstsignierten TLS-Zertifikaten (wichtig für Proxmox auf Port `8006`).

### 3. Dateien auf die Steckdose hochladen
1. Kopiere `config.example.json` auf deinem PC zu `config.json` und trage deine Proxmox-IP, den API-Token und deine Uptime-Kuma-URL ein.
2. Öffne im Tasmota-Webinterface **Tools (Werkzeuge) -> Manage File System**.
3. Lade sowohl die **`config.json`** als auch die **`autoexec.be`** hoch.
4. Starte die Steckdose neu (oder gib in der *Berry Scripting Console* `load("autoexec.be")` ein).
5. Auf der Tasmota-Hauptseite erscheinen nun unter den Energiewerten die neuen Statuszeilen des Watchdogs.

---

## ⚙️ Konfiguration (`config.json`)

Alle Einstellungen sind von der Programmlogik getrennt und liegen in der `config.json`:

| Parameter | Typ | Standard | Beschreibung |
| :--- | :--- | :--- | :--- |
| `pve_host` | String | `https://...:8006` | Basis-URL des Proxmox-Servers inkl. Port `8006` (HTTPS). |
| `pve_node` | String | `"pve"` | Name des Proxmox-Nodes (wie in der Proxmox-UI links im Baum angezeigt). |
| `pve_api_token` | String | `"PVEAPIToken=..."` | Vollständiger API-Token-String (`PVEAPIToken=USER@REALM!TOKENID=UUID`). |
| `kuma_push_url` | String | `"http://..."` | Basis-Push-URL eines Uptime-Kuma "Push"-Monitors (ohne `?status=...`-Parameter). Leer lassen (`""`), falls nicht genutzt. |
| `git_raw_url` | String | `"https://..."` | Raw-URL zur `autoexec.be` im Git-Repository für direkte Updates über den Befehl `GitUpdate`. |
| `dry_run` | Boolean | `true` | **Trockenlauf-Modus:** Bei `true` werden API-Reboots und Relais-Schaltungen nur simuliert und im Log/Kuma mit `DRY_` markiert. Für den Echtbetrieb auf `false` setzen! |
| `check_interval_s` | Integer | `60` | Prüfintervall in Sekunden für Proxmox-Health-Check, Leistungsmessung und Uptime-Kuma-Heartbeat. |
| `freeze_min_watts` | Float | `75.0` | Schwellenwert in Watt, ab dem der Server bei gleichzeitigem API-Ausfall als "eingefroren (Kernel/I/O-Freeze)" gewertet wird. |
| `freeze_max_delta` | Float | `3.0` | Maximale Leistungsänderung (Watt) zur Vor-Minute, um eine starre Freeze-Linie von dynamischer Arbeitslast zu unterscheiden. |
| `softoff_watts` | Float | `15.0` | Schwellenwert in Watt, unter dem der Server (aber `> 0.5 W`) als ausgeschaltet (Soft-Off / S5) erkannt wird. |
| `soft_threshold` | Integer | `3` | Anzahl aufeinanderfolgender Fehlversuche im Freeze-Zustand, nach denen **Stufe 1** (Sanfter Reboot per Proxmox-API) ausgelöst wird. |
| `hard_threshold` | Integer | `5` | Anzahl aufeinanderfolgender Fehlversuche, nach denen **Stufe 2** (Harter Power-Cycle über das Relais der Steckdose) ausgelöst wird. |
| `off_time_s` | Integer | `15` | Dauer in Sekunden, für die der Strom beim harten Power-Cycle getrennt bleibt. |
| `cooldown_checks` | Integer | `8` | Anzahl der Prüfzyklen (z. B. 8 × 60s = 8 Minuten), die nach einem Power-Cycle pausiert wird, damit der Server in Ruhe booten kann. |

---

## 🧪 Testen & Trockenlauf (Dry-Run)

Standardmäßig startet das Skript mit `"dry_run": true`. In diesem Modus werden weder der Proxmox-Reboot noch das Abschalten des Relais wirklich ausgeführt – du kannst die gesamte Eskalationskette im laufenden Betrieb gefahrlos testen.

Öffne dazu **Consoles -> Berry Scripting Console** auf der Steckdose:

### 1. Einzelfunktionen prüfen
```python
# Prüfen, ob Proxmox auf Port 8006 erreichbar ist (sollte 'true' liefern):
print(global.watchdog.is_proxmox_alive())

# Aktuelle Leistungsmessung prüfen (liefert Wattzahl, z. B. 52.1):
print(global.watchdog.get_current_power())
```

### 2. Komplette Freeze-Simulation im Zeitraffer durchspielen
```python
# Prüfintervall auf 5 Sekunden verkürzen und Freeze (82.6 W + Port 8006 tot) simulieren:
global.watchdog.check_interval_s = 5
global.watchdog.simulate_freeze = true
```
Beobachte nun die Konsole oder die Tasmota-Startseite:
* Bei `Fail 3/5` löst **Stufe 1** (`DRYRUN_Soft_Reboot`) aus.
* Bei `Fail 5/5` löst **Stufe 2** (`DRYRUN_PowerCycle_FREEZE`) aus, wartet 15 Sekunden und geht danach in den Boot-Cooldown (`Boot_Cooldown_8` bis `0`).

### 3. Simulation beenden und Watchdog scharfschalten
Wenn der Test erfolgreich war, schaltest du die Simulation aus und aktivierst den Echtbetrieb dauerhaft:
```python
global.watchdog.simulate_freeze = false
global.watchdog.check_interval_s = 60
global.watchdog.dry_run = false
global.watchdog.save_config()
```
*(Durch `save_config()` wird `"dry_run": false` direkt in die `config.json` auf der Steckdose zurückgeschrieben, sodass der Watchdog auch nach einem Neustart scharf bleibt).*

---

## 🔄 Updates & Wartungsbefehle

Das Skript registriert zwei eigene Befehle in Tasmota, die du jederzeit über die normale **Tasmota-Konsole**, per **MQTT** oder per **HTTP-Aufruf** ausführen kannst:

* **`GitUpdate`**: Lädt die neueste `autoexec.be` direkt von der in `git_raw_url` hinterlegten Git-URL herunter, prüft die Datei auf Integrität und führt einen **Hot-Reload** im laufenden Betrieb durch (ohne dass die Steckdose neu starten muss und ohne dass deine lokale `config.json` überschrieben wird).
* **`ReloadConfig`**: Liest die `config.json` im laufenden Betrieb neu ein, falls du Parameter über das Webinterface geändert hast.

### Optional: Automatisches nächtliches Git-Update per Tasmota-Rule
Wenn sich die Steckdose jede Nacht um 03:00 Uhr automatisch die neueste Skript-Version aus deinem Git-Repository holen soll, gib in der normalen Tasmota-Konsole ein:
```text
Rule1 ON Time#Minute=180 DO GitUpdate ENDON
Rule1 1
```

### Optional: Schneller Upload vom PC per `curl` (für Entwickler)
Wenn du lokal am Code arbeitest, kannst du Änderungen mit zwei Befehlen direkt auf die Steckdose schieben und live neu laden:
```bash
TASMOTA_IP="192.168.1.55"
curl -s -F "ufsu=@autoexec.be" "http://${TASMOTA_IP}/ufsu" > /dev/null
curl -s "http://${TASMOTA_IP}/cm?cmnd=Br%20load(%22autoexec.be%22)"
```

---

## 💡 Bonus-Tipp: Ursache in Proxmox entschärfen (`vzdump` I/O-Limit)

Um zu verhindern, dass die NVMe/SSD beim wöchentlichen Backup überhaupt erst in die thermische Notabschaltung läuft, empfiehlt es sich, auf dem Proxmox-Host in der Datei `/etc/vzdump.conf` ein globales Bandbreitenlimit (z. B. `50000` KB/s = 50 MB/s) zu setzen:

```text
bwlimit: 50000
```
Dadurch dauert das Backup im Hintergrund etwas länger, die Dauerlast und Temperaturspitzen des SSD-Controllers sinken jedoch drastisch.
