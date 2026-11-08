import string
import json
import math
import path

class ProxmoxWatchdog
  # === KONFIGURATIONSVARIABLEN (werden aus config.json geladen) ===
  var pve_host
  var pve_node
  var pve_api_token
  var kuma_push_url
  var git_raw_url
  
  var dry_run
  var simulate_freeze
  var check_interval_s
  var freeze_min_watts
  var freeze_max_delta
  var softoff_watts
  var soft_threshold
  var hard_threshold
  var off_time_s
  var cooldown_checks

  # === INTERNE LAUFZEIT-VARIABLEN ===
  var tick_count
  var fail_count
  var cooldown_count
  var reboot_locked
  var soft_reboot_sent
  var last_power
  var prev_power
  var last_status_msg

  def init()
    self.simulate_freeze = false
    self.tick_count = 0
    self.fail_count = 0
    self.cooldown_count = 0
    self.reboot_locked = false
    self.soft_reboot_sent = false
    self.last_power = 0.0
    self.prev_power = 0.0
    self.last_status_msg = "Booting_Watchdog"
    
    # Konfiguration aus Datei laden
    self.load_config()
    
    tasmota.cmd("Power ON")
    tasmota.add_driver(self)
    print("Proxmox-Watchdog: Gestartet (DRY_RUN=" .. str(self.dry_run) .. ").")
  end

  # Hilfsfunktion: Wert aus Map holen oder Fallback nutzen
  def get_val(map_obj, key, default_val)
    if map_obj != nil && map_obj.find(key) != nil
      return map_obj[key]
    end
    return default_val
  end

  # Liest die config.json aus dem Tasmota-Dateisystem
  def load_config()
    var c = nil
    if path.exists("config.json")
      try
        var f = open("config.json", "r")
        c = json.load(f.read())
        f.close()
        print("Watchdog: config.json erfolgreich geladen.")
      except .. as e, m
        print("Watchdog: FEHLER beim Lesen der config.json:", e, m)
      end
    else
      print("Watchdog: WARNUNG - Keine config.json gefunden! Nutze Fallback-Werte.")
    end

    # Werte zuweisen (mit sicheren Standardwerten als Fallback)
    self.pve_host         = str(self.get_val(c, "pve_host", "https://192.168.1.100:8006"))
    self.pve_node         = str(self.get_val(c, "pve_node", "pve"))
    self.pve_api_token    = str(self.get_val(c, "pve_api_token", ""))
    self.kuma_push_url    = str(self.get_val(c, "kuma_push_url", ""))
    self.git_raw_url      = str(self.get_val(c, "git_raw_url", ""))
    
    self.dry_run          = bool(self.get_val(c, "dry_run", true))
    self.check_interval_s = int(self.get_val(c, "check_interval_s", 60))
    self.freeze_min_watts = real(self.get_val(c, "freeze_min_watts", 75.0))
    self.freeze_max_delta = real(self.get_val(c, "freeze_max_delta", 3.0))
    self.softoff_watts    = real(self.get_val(c, "softoff_watts", 15.0))
    self.soft_threshold   = int(self.get_val(c, "soft_threshold", 3))
    self.hard_threshold   = int(self.get_val(c, "hard_threshold", 5))
    self.off_time_s       = int(self.get_val(c, "off_time_s", 15))
    self.cooldown_checks  = int(self.get_val(c, "cooldown_checks", 8))
  end

  # Speichert aktuelle Einstellungen (z.B. wenn dry_run per Konsole geändert wurde) zurück in die config.json
  def save_config()
    var c = {
      "pve_host": self.pve_host,
      "pve_node": self.pve_node,
      "pve_api_token": self.pve_api_token,
      "kuma_push_url": self.kuma_push_url,
      "git_raw_url": self.git_raw_url,
      "dry_run": self.dry_run,
      "check_interval_s": self.check_interval_s,
      "freeze_min_watts": self.freeze_min_watts,
      "freeze_max_delta": self.freeze_max_delta,
      "softoff_watts": self.softoff_watts,
      "soft_threshold": self.soft_threshold,
      "hard_threshold": self.hard_threshold,
      "off_time_s": self.off_time_s,
      "cooldown_checks": self.cooldown_checks
    }
    var f = open("config.json", "w")
    f.write(json.dump(c))
    f.close()
    print("Watchdog: Aktuelle Konfiguration in config.json gespeichert.")
  end

  def update_from_git()
    if self.git_raw_url == ""
      print("Watchdog: Keine git_raw_url in config.json hinterlegt!")
      return false
    end
    print("Watchdog: Lade neueste autoexec.be von Git...")
    var code = tasmota.urlfetch(self.git_raw_url, "autoexec.tmp")
    if code == 200 && path.exists("autoexec.tmp")
      var f = open("autoexec.tmp", "r")
      var content = f.read()
      f.close()
      if size(content) > 100
        var out = open("autoexec.be", "w")
        out.write(content)
        out.close()
        path.remove("autoexec.tmp")
        print("Watchdog: Git-Update erfolgreich! Lade Skript neu (config.json bleibt erhalten)...")
        tasmota.set_timer(500, / -> load("autoexec.be"))
        return true
      end
    end
    print("Watchdog: Git-Update fehlgeschlagen! HTTP-Code:", code)
    return false
  end

  def get_current_power()
    if self.simulate_freeze
      return 82.6
    end
    var sensors = json.load(tasmota.read_sensors())
    if sensors != nil && sensors.find("ENERGY") != nil
      return real(sensors["ENERGY"]["Power"])
    end
    return -1.0
  end

  def is_proxmox_alive()
    if self.simulate_freeze
      return false
    end
    var wc = webclient()
    wc.set_timeouts(3000, 3000)
    wc.begin(self.pve_host .. "/api2/json/access/domains")
    var code = wc.GET()
    wc.close()
    return (code > 0)
  end

  def trigger_proxmox_api_reboot()
    self.soft_reboot_sent = true
    if self.dry_run
      print("Watchdog [TROCKENLAUF]: STUFE 1 - Würde jetzt Proxmox API-Reboot senden.")
      self.last_status_msg = "DRYRUN_Soft_Reboot"
      return true
    end

    print("Watchdog: STUFE 1 - Sende Reboot-Command an Proxmox API...")
    var wc = webclient()
    wc.set_timeouts(3000, 3000)
    var url = string.format("%s/api2/json/nodes/%s/status", self.pve_host, self.pve_node)
    wc.begin(url)
    wc.add_header("Authorization", self.pve_api_token)
    wc.add_header("Content-Type", "application/x-www-form-urlencoded")
    var code = wc.POST("command=reboot")
    wc.close()
    
    if code == 200
      self.last_status_msg = "PVE_API_Reboot_Sent"
      return true
    else
      self.last_status_msg = "PVE_API_Unreachable"
      return false
    end
  end

  def push_kuma(status, msg)
    if self.kuma_push_url == ""
      return
    end
    var wc = webclient()
    wc.set_timeouts(2000, 2000)
    var prefix = self.dry_run ? "DRY_" : ""
    var url = string.format("%s?status=%s&msg=%s%s&ping=%.1f", 
                            self.kuma_push_url, status, prefix, msg, self.last_power)
    wc.begin(url)
    var code = wc.GET()
    wc.close()
  end

  def trigger_power_cycle(reason)
    if self.dry_run
      print(string.format("Watchdog [TROCKENLAUF]: STUFE 2 (%s) - Würde Relais für %ds ausschalten!", reason, self.off_time_s))
      self.last_status_msg = "DRYRUN_PowerCycle_" .. reason
      self.push_kuma("up", self.last_status_msg)
      tasmota.set_timer(self.off_time_s * 1000, / -> self.restore_power())
      return
    end

    print(string.format("Watchdog: STUFE 2 KRITISCH (%s) - Starte harten Power-Cycle...", reason))
    self.last_status_msg = "Hard_PowerCycle_" .. reason
    self.push_kuma("up", self.last_status_msg)
    
    tasmota.cmd("Power OFF")
    tasmota.set_timer(self.off_time_s * 1000, / -> self.restore_power())
  end

  def restore_power()
    if self.dry_run
      print("Watchdog [TROCKENLAUF]: Timer abgelaufen - Würde Strom wieder einschalten.")
    else
      print("Watchdog: Schalte Strom wieder EIN.")
      tasmota.cmd("Power ON")
    end
    self.cooldown_count = self.cooldown_checks
    self.fail_count = 0
    self.soft_reboot_sent = false
    self.reboot_locked = true 
    self.last_status_msg = "Wait_For_PVE_Boot"
  end

  def every_second()
    self.tick_count += 1
    if self.tick_count < self.check_interval_s
      return
    end
    self.tick_count = 0

    self.prev_power = self.last_power
    self.last_power = self.get_current_power()
    var power_delta = math.abs(self.last_power - self.prev_power)

    if self.cooldown_count > 0
      self.cooldown_count -= 1
      self.last_status_msg = string.format("Boot_Cooldown_%d", self.cooldown_count)
      self.push_kuma("up", self.last_status_msg)
      return
    end

    if self.is_proxmox_alive()
      self.fail_count = 0
      self.reboot_locked = false
      self.soft_reboot_sent = false
      self.last_status_msg = "OK_PVE_Online"
    else
      var is_frozen  = (self.last_power >= self.freeze_min_watts && power_delta <= self.freeze_max_delta)
      var is_softoff = (self.last_power > 0.5 && self.last_power <= self.softoff_watts)

      if is_frozen || is_softoff
        self.fail_count += 1
        var state_type = is_frozen ? "FREEZE" : "SOFTOFF"
        print(string.format("Watchdog: %s erkannt (%.1f W, Delta %.2f W). Fail %d/%d", 
                            state_type, self.last_power, power_delta, self.fail_count, self.hard_threshold))
        self.last_status_msg = string.format("%s_Wait_%d", state_type, self.fail_count)

        if is_frozen && self.fail_count == self.soft_threshold && !self.soft_reboot_sent
          self.trigger_proxmox_api_reboot()
        end

        if self.fail_count >= self.hard_threshold
          if !self.reboot_locked
            self.trigger_power_cycle(state_type)
            return
          else
            self.last_status_msg = "LOCKED_After_Reboot"
          end
        end
      else
        self.fail_count = 0
        self.last_status_msg = string.format("PVE_Busy_%.0fW", self.last_power)
      end
    end

    self.push_kuma("up", self.last_status_msg)
  end

  def web_sensor()
    var mode_str = self.dry_run ? "TROCKENLAUF (Sicher)" : "SCHARF (Aktiv)"
    if self.simulate_freeze
      mode_str += " [SIMULATION]"
    end
    var msg = string.format(
      "{s}Watchdog Modus{m}%s{e}" ..
      "{s}PVE Watchdog Status{m}%s{e}" ..
      "{s}PVE Fehlerzähler{m}%d / %d (API bei %d){e}",
      mode_str, self.last_status_msg, self.fail_count, self.hard_threshold, self.soft_threshold
    )
    tasmota.web_send_decimal(msg)
  end
end

# Bestehende Instanz & Befehle sauber entfernen (Hot-Reload-fähig)
if global.watchdog != nil
  tasmota.remove_driver(global.watchdog)
end
tasmota.remove_cmd("GitUpdate")
tasmota.remove_cmd("ReloadConfig")

# Neu starten und Tasmota-Konsolenbefehle registrieren
global.watchdog = ProxmoxWatchdog()
tasmota.add_cmd("GitUpdate", / -> global.watchdog.update_from_git())
tasmota.add_cmd("ReloadConfig", / -> global.watchdog.load_config())
