## Konfiguration (`config.json`)

Kopiere `config.example.json` nach `config.json`, passe die Werte an und lade die Datei über **Tools -> Manage File System** auf die Tasmota32-Steckdose hoch.

| Parameter | Typ | Standard | Beschreibung |
| :--- | :--- | :--- | :--- |
| `pve_host` | String | `https://...:8006` | Basis-URL des Proxmox-Servers inkl. Port `8006` (in Tasmota muss `SetOption132 0` gesetzt sein, um selbstsignierte TLS-Zertifikate zu erlauben). |
| `pve_node` | String | `"pve"` | Name des Proxmox-Nodes (wie in der Proxmox-UI links im Baum angezeigt). |
| `pve_api_token` | String | `"PVEAPIToken=..."` | Vollständiger API-Token-String (`PVEAPIToken=USER@REALM!TOKENID=UUID`), benötigt das Recht `Sys.PowerMgmt` auf `/nodes/<pve_node>`. |
| `kuma_push_url` | String | `"http://..."` | Basis-Push-URL eines Uptime-Kuma "Push"-Monitors (ohne `?status=...`-Parameter am Ende). Leer lassen (`""`), falls nicht genutzt. |
| `git_raw_url` | String | `"https://..."` | Raw-URL zur `autoexec.be` im Git-Repository für Updates über den Tasmota-Befehl `GitUpdate`. |
| `dry_run` | Boolean | `true` | **Trockenlauf-Modus:** Bei `true` werden API-Reboots und Relais-Schaltungen nur simuliert und im Log/Kuma mit `DRY_` markiert. Für den Echtbetrieb auf `false` setzen. |
| `check_interval_s` | Integer | `60` | Prüfintervall in Sekunden für Proxmox-Health-Check, Leistungsmessung und Uptime-Kuma-Heartbeat. |
| `freeze_min_watts` | Float | `75.0` | Schwellenwert in Watt, ab dem der Server bei gleichzeitigem API-Ausfall als "eingefroren (Kernel/I/O-Freeze)" gewertet wird. |
| `freeze_max_delta` | Float | `3.0` | Maximale Leistungsänderung (Watt) zur Vor-Minute, um eine starre Freeze-Linie von dynamischer Boot-/Arbeitslast zu unterscheiden. |
| `softoff_watts` | Float | `15.0` | Schwellenwert in Watt, unter dem der Server (aber `> 0.5 W`) als ausgeschaltet (Soft-Off / S5) erkannt wird. |
| `soft_threshold` | Integer | `3` | Anzahl aufeinanderfolgender Fehlversuche im Freeze-Zustand, nach denen **Stufe 1** (Sanfter Reboot per Proxmox-API) ausgelöst wird. |
| `hard_threshold` | Integer | `5` | Anzahl aufeinanderfolgender Fehlversuche, nach denen **Stufe 2** (Harter Power-Cycle über das Relais der Steckdose) ausgelöst wird. |
| `off_time_s` | Integer | `15` | Dauer in Sekunden, für die der Strom beim harten Power-Cycle getrennt bleibt (Reset-Zeit für Netzteil & NVMe-Controller). |
| `cooldown_checks` | Integer | `8` | Anzahl der Prüfzyklen (z. B. 8 × 60s = 8 Minuten), die nach einem Power-Cycle pausiert wird, damit der Server in Ruhe booten kann. |
