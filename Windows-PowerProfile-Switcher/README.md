# PowerProfile Switcher

Eine kleine Windows-11-App für den **XMG Neo 16 (E25)**, mit der du per
**einem Klick** zwischen Energieprofilen wechselst:

| Profil | Wann | Was passiert |
|---|---|---|
| 🎮 **Gaming** | Zuhause an der Steckdose | Maximale CPU-Leistung, Bildschirm/Standby bleiben aus, WLAN auf höchste Leistung, Helligkeit 100 % |
| ⚖️ **Ausgeglichen** | Standard | Windows-Standardschema ("Ausbalanciert"), Helligkeit 60 % |
| 🔋 **Unterwegs** | Akku soll möglichst lange halten | CPU gedrosselt, Bildschirm/Standby schalten früh ab, WLAN im Sparmodus, Helligkeit 35 % |

Kein Zusatzprogramm nötig – die App besteht nur aus PowerShell-Skripten,
die bereits in Windows 11 enthaltene Bordmittel nutzen (`powercfg`,
Bildschirmhelligkeit über WMI). Es wird nichts aus dem Internet
nachgeladen und keine Fremdsoftware installiert.

## Was die App NICHT steuert

Lüfterkurven, RGB-Beleuchtung und das Akku-Ladelimit sind proprietär und
nur über die **XMG Control Center** App ansteuerbar – dafür gibt es keine
offiziell dokumentierte Schnittstelle. Das Tray-Menü bietet daher (falls
installiert) einen direkten Link zum Öffnen von XMG Control Center, damit
du diese Einstellungen bei Bedarf mit einem Klick daneben erreichst.

## Installation

1. Diesen Ordner (`Windows-PowerProfile-Switcher`) auf den XMG Neo 16
   kopieren, z. B. auf den Desktop.
2. Rechtsklick auf `Install.ps1` → **Mit PowerShell ausführen**.
   - Falls eine Sicherheitswarnung zur Ausführungsrichtlinie erscheint,
     stattdessen PowerShell öffnen und ausführen:
     ```powershell
     powershell -ExecutionPolicy Bypass -File .\Install.ps1
     ```
3. Es erscheint eine Administrator-Abfrage (UAC) – bestätigen. Das ist
   **einmalig** nötig, damit die geplanten Aufgaben eingerichtet werden
   können. Danach läuft das Umschalten ganz ohne weitere UAC-Fenster.

Nach der Installation hast du:

- Drei Verknüpfungen auf dem **Desktop** (`Gaming - Höchstleistung`,
  `Ausgeglichen`, `Unterwegs - Akku sparen`) – Doppelklick genügt.
- Einen Eintrag im **Startmenü** (`PowerProfile Switcher`) mit denselben
  drei Verknüpfungen (lässt sich an die Taskleiste anheften).
- Ein **Tray-Icon** unten rechts (startet automatisch bei jeder
  Anmeldung), Rechts- oder Linksklick öffnet das Umschalt-Menü.

## Nutzung

Einfach die passende Verknüpfung anklicken oder im Tray-Menü das Profil
auswählen. Eine kurze Benachrichtigung bestätigt die Umschaltung. Der
Wechsel dauert nur ein bis zwei Sekunden.

## Anpassen

Alle konkreten Werte (CPU-Grenzen, Zeiten bis Bildschirm/Standby,
Helligkeit, WLAN-Sparmodus) stehen gesammelt in `Set-PowerProfile.ps1` in
den drei `switch`-Blöcken (`Gaming`, `Balanced`, `Travel`). Werte dort
anpassen und anschließend `Install.ps1` erneut ausführen, damit die
geplanten Aufgaben die aktualisierte Datei verwenden.

Beispiel: Wenn dir 60 % maximale CPU-Leistung im Profil "Unterwegs" zu
wenig ist, einfach den Wert bei

```powershell
Set-PowerValue -SchemeGuid $guid -SubGroup SUB_PROCESSOR -Setting PROCTHROTTLEMAX -Ac 100 -Dc 60
```

anpassen (`-Dc 60` = 60 % im Akkubetrieb).

## Deinstallation

`Uninstall.ps1` per Rechtsklick → **Mit PowerShell ausführen**. Entfernt
alle geplanten Aufgaben, Verknüpfungen, das Tray-Icon und setzt das
aktive Energieschema auf "Ausbalanciert" zurück. Optional werden auch die
selbst angelegten Energieschemata ("XMG Gaming", "XMG Unterwegs")
gelöscht.

## Technischer Hintergrund

- `Set-PowerProfile.ps1 -Mode Gaming|Balanced|Travel` ist das eigentliche
  Kernskript und kann auch direkt (mit Adminrechten) aufgerufen werden.
- `Install.ps1` legt drei geplante Aufgaben (Taskplaner) mit
  **"Mit höchsten Rechten ausführen"** an. Windows erlaubt es, eine so
  konfigurierte Aufgabe ohne erneuten UAC-Dialog auszulösen (sofern das
  angemeldete Konto Administratorrechte hat) – dadurch ist ein
  UAC-freies Umschalten per Klick möglich, obwohl `powercfg` intern
  erhöhte Rechte braucht.
- `Start-Tray.ps1` läuft **ohne** erhöhte Rechte und löst die geplanten
  Aufgaben nur aus (`Start-ScheduledTask`).
- Die eigenen Energieschemata werden per `powercfg /duplicatescheme`
  erzeugt; ihre GUIDs merkt sich die App in
  `%LOCALAPPDATA%\PowerProfileSwitcher\schemes.json`, damit bei
  wiederholtem Aufruf nicht ständig neue Schemata entstehen.
- Die Bildschirmhelligkeit wird sofort (nicht erst nach X Minuten
  Inaktivität) über die WMI-Klasse `WmiMonitorBrightnessMethods`
  gesetzt – funktioniert nur beim eingebauten Laptop-Display, nicht bei
  extern angeschlossenen Monitoren.

## Voraussetzungen

- Windows 11 (getestet für den XMG Neo 16 E25, funktioniert aber auf
  jedem Windows-11-Laptop)
- Ein Benutzerkonto mit Administratorrechten (für die einmalige
  Installation)
- Keine weiteren Abhängigkeiten – nur in Windows enthaltene Bordmittel
  (PowerShell 5.1, `powercfg`, Taskplaner)
