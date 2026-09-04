# PowerProfile Switcher

Eine kleine Windows-11-App für den **XMG Neo 16 (E25)**, mit der du per
**einem Klick** zwischen Energieprofilen wechselst:

| Profil | Wann | Was passiert |
|---|---|---|
| 🎮 **Gaming** | Zuhause an der Steckdose | Maximale CPU-Leistung, Bildschirm/Standby bleiben aus, WLAN auf höchste Leistung, Helligkeit 100 %, **240 Hz**, **dedizierte GPU aktiv** |
| ⚖️ **Ausgeglichen** | Standard | Windows-Standardschema ("Ausbalanciert"), Helligkeit 60 %, Bildwiederholrate/GPU bleiben unverändert |
| 🔋 **Unterwegs** | Akku soll möglichst lange halten | CPU gedrosselt, Bildschirm/Standby schalten früh ab, WLAN im Sparmodus, Helligkeit 35 %, **60 Hz**, **dedizierte GPU wird deaktiviert (nur integrierte Grafik)** |

Kein Zusatzprogramm nötig – die App besteht nur aus PowerShell-Skripten,
die bereits in Windows 11 enthaltene Bordmittel nutzen (`powercfg`,
Bildschirmhelligkeit über WMI, `pnputil` für die GPU, die native
Windows-Anzeige-API für die Bildwiederholrate). Es wird nichts aus dem
Internet nachgeladen und keine Fremdsoftware installiert.

## GPU-Umschaltung (nur integrierte Grafik im Unterwegs-Profil)

Im Profil "Unterwegs" wird die dedizierte GPU (NVIDIA, bzw. AMD bei der
A-Modellvariante) automatisch über den Geräte-Manager deaktiviert
(`pnputil /disable-device`) – danach läuft der Laptop nur noch mit der
integrierten Intel-Grafik, was spürbar Akku spart. Beim Wechsel zurück
auf "Gaming" wird die dedizierte GPU automatisch wieder aktiviert.

Da Grafiktreiber ihre Ressourcen oft erst nach einem Neustart vollständig
freigeben, fragt die App beim Deaktivieren per Dialog nach, ob **jetzt in
60 Sekunden neu gestartet** werden soll (abbrechbar mit `shutdown /a` in
einer Konsole, oder einfach "Nein" wählen und später manuell neu
starten). Ein automatischer Neustart ohne Rückfrage findet **nie** statt,
damit keine ungespeicherte Arbeit verloren geht.

> **Hinweis:** Das funktioniert zuverlässig, solange der Laptop im
> BIOS im normalen Optimus/Hybrid-Grafikmodus läuft (Werkseinstellung
> beim XMG Neo 16) – dort ist die integrierte Grafik fest mit dem
> internen Display verbunden. Falls im BIOS stattdessen "dGPU only"
> eingestellt ist, bitte diese Funktion **nicht** nutzen, da sonst das
> Bild schwarz bleiben könnte.

## Bildwiederholrate (240 Hz / 60 Hz)

Die App stellt die Bildwiederholrate des internen Displays direkt über
die Windows-eigene Anzeige-API um – ohne Neustart, ohne Zusatzprogramm.
"Gaming" schaltet auf 240 Hz, "Unterwegs" auf 60 Hz (spart zusätzlich
Akku). Falls dein Panel keine 240 Hz unterstützt oder ein externer
Monitor als Hauptbildschirm eingestellt ist, meldet die App das per
Warnung in der Konsole, ohne das Umschalten der übrigen Einstellungen zu
verhindern.

## Spar- und Boost-Optionen im Detail

Diese Werte setzt die App pro Profil, jeweils getrennt für Netzbetrieb
(AC) und Akkubetrieb (DC):

| Einstellung | Was sie bewirkt | Gaming (AC/DC) | Unterwegs (AC/DC) |
|---|---|---|---|
| `PROCTHROTTLEMIN` / `PROCTHROTTLEMAX` | Min./Max. CPU-Takt in % | 100/20 – 100/100 | 5/5 – 100/60 |
| `PERFBOOSTMODE` | **Turbo/Boost-Modus**: 0=aus, 1=ein, 2=aggressiv, 3/4=effiziente Varianten | 2/1 | 1/**0 (aus)** |
| `PERFBOOSTPOL` | **Boost-Bereitschaft** 0–100: wie schnell/oft der Turbo greift | 100/60 | 50/0 |
| `PERFEPP` | **Energy Performance Preference** 0–100 (0 = volle Leistung, 100 = maximale Effizienz). Der eigentliche Regler hinter Windows' Leistungs-Schieber auf modernen Intel-CPUs | 0/25 | 50/**100** |
| `CPMINCORES` / `CPMAXCORES` | **Core Parking**: wie viele Kerne wach bleiben müssen/dürfen | 100/20 – 100/100 | 10/5 – 100/**50** |
| `RTCWAKE` | **Aufwachtimer**: verhindert im Unterwegs-Profil, dass der Laptop in der Tasche von selbst aufwacht (häufigste Ursache für leeren Akku + Hitze) | 1/1 (erlaubt) | 1/**0 (aus)** |
| `ESBATTTHRESHOLD` | Ab wie viel % Akku Windows' **Energiesparmodus** automatisch anspringt | –/20 % | –/**100 % (immer an)** |
| `ASPM` (PCIe) | Stromsparen der PCIe-Verbindungen: 0=aus, 1=moderat, 2=maximal | 0/1 | 1/2 |
| `USBSELECTSUSPEND` | USB-Geräte im Leerlauf schlafen legen | aus/an | an/an |
| WLAN-Sparmodus | 0=max. Leistung … 3=max. Einsparung | 0/1 | 2/3 |
| `DISKIDLE`, `VIDEOIDLE`, `STANDBYIDLE`, `HIBERNATEIDLE` | Zeiten (Sekunden) bis Platte/Bildschirm/Standby/Ruhezustand, 0 = nie | 0/… | 600/180 … |

Nicht unterstützte Einstellungen (je nach CPU/Treiber) werden automatisch
übersprungen, ohne den Rest des Profils zu blockieren – das Skript
probiert dabei sowohl den Kurznamen als auch die GUID der Einstellung.

**Noch nicht enthalten** (bewusst, weil riskant oder nicht zuverlässig
skriptbar): eine feste MHz-Obergrenze (`PROCFREQMAX`), das
Umschalten des Windows-Leistungsschiebers selbst (dessen "Overlay"-Modus
ist nicht offiziell dokumentiert – die App setzt stattdessen direkt EPP,
was denselben Effekt hat), sowie Lüfterkurven, Akku-Ladelimit und
Undervolting (nur über XMG Control Center bzw. BIOS).

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

Das Tray-Icon zeigt immer den aktuell aktiven Modus:

- 🔴 rot = Gaming, 🔵 blau = Ausgeglichen, 🟢 grün = Unterwegs
- Tooltip (Maus über dem Icon) nennt das aktive Profil im Klartext
- Im Rechtsklick-Menü ist der aktive Eintrag mit einem Haken markiert

## Warum das Tray-Icon vorher verschwunden ist (und jetzt nicht mehr)

Zwei Ursachen waren dafür verantwortlich, dass das Icon nach dem
Umschalten aus der Taskleiste verschwand:

1. **Windows beendet geplante Aufgaben standardmäßig, sobald der Laptop
   auf Akku wechselt** (`StopIfGoingOnBatteries`) – genau der Moment, in
   dem man auf "Unterwegs" umschaltet. Das Tray-Icon lief als geplante
   Aufgabe und wurde dadurch abgeschossen.
2. Das Umschalten der GPU (`pnputil`) und der Bildwiederholrate löst
   kurz einen Grafiktreiber-Reset aus, bei dem Windows Explorer
   gelegentlich alle Tray-Icons "vergisst", die sich nicht von selbst neu
   anmelden.

Behoben durch:

- Die geplante Aufgabe für das Tray-Icon läuft jetzt explizit **auch im
  Akkubetrieb weiter**, hat **kein 72-Stunden-Zeitlimit** mehr (Windows'
  Standardlimit für geplante Aufgaben – hätte das Icon spätestens nach 3
  Tagen ohnehin beendet) und **startet sich bei einem Absturz bis zu 3x
  automatisch neu**.
- `Start-Tray.ps1` hat jetzt einen **Selbstheilungs-Timer**: alle 15
  Sekunden (und zusätzlich 4 Sekunden nach jedem Profilwechsel) setzt es
  `Visible = $true` erneut und aktualisiert Icon/Tooltip – falls Windows
  das Icon zwischendurch entfernt hat, taucht es so innerhalb weniger
  Sekunden von selbst wieder auf.
- Fehler in einzelnen Menü-/Timer-Ereignissen werden abgefangen und nach
  `%LOCALAPPDATA%\PowerProfileSwitcher\tray.log` protokolliert, statt den
  ganzen Tray-Prozess abstürzen zu lassen.

**Wichtig:** Diese Verbesserungen wirken erst nach einer erneuten
Installation – bitte `Install.ps1` einmal neu ausführen (siehe unten),
damit die geplante Aufgabe mit den neuen Einstellungen neu angelegt wird.

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

Die Bildwiederholrate steht direkt bei den Aufrufen `Set-RefreshRate
-Hertz 240` bzw. `-Hertz 60`. Welche GPU als "dediziert" erkannt wird,
lässt sich in `Get-DiscreteGpuDevice` über das Namensmuster
(`NVIDIA|Radeon RX|...`) anpassen, falls z. B. die AMD-Modellvariante des
Neo 16 verwendet wird.

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
- Das aktuell aktive Profil steht in
  `%LOCALAPPDATA%\PowerProfileSwitcher\current.json`, Tray-Fehler in
  `...\tray.log` – hilfreich, falls doch mal etwas nicht wie erwartet
  reagiert.
- `Install.ps1` ist gefahrlos mehrfach ausführbar (z. B. nach einem
  Update dieser Skripte): bestehende Aufgaben/Verknüpfungen werden vorher
  entfernt und neu angelegt, eine bereits laufende Tray-Instanz wird vor
  dem Neustart sauber beendet.

## Voraussetzungen

- Windows 11 (getestet für den XMG Neo 16 E25, funktioniert aber auf
  jedem Windows-11-Laptop)
- Ein Benutzerkonto mit Administratorrechten (für die einmalige
  Installation)
- Keine weiteren Abhängigkeiten – nur in Windows enthaltene Bordmittel
  (PowerShell 5.1, `powercfg`, Taskplaner)
