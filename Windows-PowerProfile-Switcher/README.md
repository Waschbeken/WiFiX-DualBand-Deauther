# PowerProfile Switcher

Eine kleine Windows-11-App für den **XMG Neo 16 (E25)**, mit der du per
**einem Klick** zwischen Energieprofilen wechselst:

| Profil | Wann | Was passiert |
|---|---|---|
| 🎮 **Gaming** (erst ab 40 % Akku) | Zuhause an der Steckdose | Maximale CPU-Leistung, Bildschirm/Standby bleiben aus, WLAN auf höchste Leistung, Helligkeit 100 %, **240 Hz**, **dedizierte GPU aktiv** |
| ⚖️ **Ausgeglichen** | Standard | Windows-Standardschema ("Ausbalanciert"), Helligkeit 60 %, Bildwiederholrate/GPU bleiben unverändert |
| 🔋 **Unterwegs** | Akku soll möglichst lange halten | CPU gedrosselt, Bildschirm/Standby schalten früh ab, WLAN im Sparmodus, Helligkeit 35 %, **60 Hz**, **dedizierte GPU wird deaktiviert (nur integrierte Grafik)** |
| 🎬 **Video / Streaming** | Film schauen, Präsentation | Bildschirm geht **nie** von selbst aus, CPU sparsam ohne Turbo, 60 Hz, Helligkeit 55 %, GPU wird nicht angefasst |

Kein Zusatzprogramm nötig – die App besteht nur aus PowerShell-Skripten,
die bereits in Windows 11 enthaltene Bordmittel nutzen (`powercfg`,
Bildschirmhelligkeit über WMI, `pnputil` für die GPU, die native
Windows-Anzeige-API für die Bildwiederholrate). Es wird keine Fremdsoftware
installiert; die einzige Internetverbindung entsteht, wenn du im Tray-Menü
selbst „Nach Updates suchen" anklickst.

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

## Watt-Zähler & Akku-Hochrechnung

Damit du siehst, **wie viel ein Profil tatsächlich bringt**, misst die App
den echten Verbrauch:

- **Beim Profilwechsel** (nur im Akkubetrieb): 4 Sekunden Einpendeln,
  dann 4 Messpunkte über ~8 Sekunden. Anschließend erscheint eine zweite
  Benachrichtigung, z. B.:
  *„12,4 W – Akku (78 %) reicht noch ca. 4 h 55 min, bei 100 % ca. 6 h 20 min.
  Zuletzt gemessen – Gaming: 31,7 W, Ausgeglichen: 18,2 W"*
- **Laufend im Tray**: Das Tray-Menü hat oben eine Zeile mit dem aktuellen
  Verbrauch und der Restlaufzeit (gleitender Mittelwert der letzten 8
  Messungen, alle 15 s aktualisiert). Auch der Tooltip zeigt
  `Unterwegs - 12,4 W, ~4 h 55 min`.
- **Klick auf diese Zeile** öffnet eine Detailansicht mit Ladestand,
  Verbrauch, Restlaufzeit, Hochrechnung bei vollem Akku, **Akku-Zustand**
  (aktuelle vs. ursprüngliche Kapazität), Ladezyklen und einer
  **Vergleichstabelle aller drei Profile** – damit hast du direkt die
  Einschätzung, wie effektiv das Unterwegs-Profil gegenüber Gaming ist.

Woher die Daten kommen: die Windows-eigenen WMI-Klassen `BatteryStatus`,
`BatteryFullChargedCapacity` und `BatteryStaticData` (Namespace
`root\WMI`) liefern die momentane Entladerate in mW und die
Restkapazität in mWh. Restlaufzeit = Restkapazität ÷ Entladerate.

Einschränkungen, die man kennen sollte:

- **Nur im Akkubetrieb messbar** – am Netzteil fließt kein Entladestrom.
  Am Netz zeigt die App deshalb „Am Netzteil" statt einer Wattzahl.
- Der Messwert ist eine **Momentaufnahme kurz nach dem Umschalten**, also
  im Wesentlichen der Ruheverbrauch. Beim Zocken liegt der reale
  Verbrauch deutlich höher – der Vergleich zwischen den Profilen bleibt
  aber aussagekräftig, weil er unter gleichen Bedingungen entsteht.
- Manche Akku-Firmware meldet keine Entladerate; dann steht dort
  „Verbrauch nicht messbar" statt einer Schätzung.
- Die Messwerte pro Profil liegen in
  `%LOCALAPPDATA%\PowerProfileSwitcher\metrics.json`.

**Langzeit-Verlauf:** Zusätzlich schreibt das Tray-Icon jeden Messpunkt
(alle 15 s) nach `power-log.csv` – mit Zeit, Profil, Watt und Ladestand.
Die Detailansicht zeigt daraus den **echten Durchschnittsverbrauch je
Profil über die gesamte Nutzungsdauer** samt Anzahl der Messungen. Das
ist deutlich belastbarer als die kurze Messung direkt nach dem
Umschalten, weil auch normale Arbeitslast mit einfließt. Die Datei wird
automatisch gekürzt, sobald sie 2 MB überschreitet.

## Automatische Kalibrierung der CPU-Grenze

Tray-Menü → **„CPU-Grenze kalibrieren (Akkubetrieb)"**. Statt einen Wert
zu raten, misst die App ihn: Sie probiert nacheinander 40/50/60/70/85/100 %
CPU-Maximum durch und misst bei jedem Wert Leistung *und* Verbrauch.
Ergebnis ist eine Tabelle plus zwei Empfehlungen:

- **Bester Wirkungsgrad** – meiste Leistung je Watt, der Vorschlag für den
  Akkubetrieb
- **Knick der Kurve** – der günstigste Wert, der noch ~95 % der
  Spitzenleistung liefert

Auf Wunsch wird der empfohlene Wert direkt übernommen; sonst bleibt alles
wie vorher. **Die ursprüngliche Einstellung wird in jedem Fall wieder
hergestellt** (auch bei Abbruch), und der Test läuft nur im Akkubetrieb ab
30 % Ladung. Dauer: ein bis zwei Minuten unter Volllast — der Lüfter wird
dabei hörbar. Einmal UAC-Abfrage, weil `powercfg` erhöhte Rechte braucht.

## Einrichtungs-Assistent

Tray-Menü → **„Einrichtung (Hardware erkennen)"**, und beim allerersten
Start automatisch einmal. Der Assistent liest aus, was wirklich da ist —
**welche Bildwiederholraten dein Panel tatsächlich anbietet**, Auflösung,
dedizierte GPU, Akkukapazität samt Zustand, CPU und Kernzahl — und leitet
daraus Startwerte ab: Gaming bekommt die höchste gemeldete Frequenz,
Unterwegs/Video die niedrigste ab 48 Hz.

Damit stehen dort gemessene statt geratener Werte. Meldet dein Panel z. B.
kein 240 Hz, sagt der Assistent das und trägt den echten Maximalwert ein.
Die CPU-Grenzen lässt er bewusst in Ruhe — dafür gibt es die Kalibrierung.

## Watt-Zahl im Tray-Icon

Sobald ein Messwert vorliegt (also im Akkubetrieb), zeigt das Icon selbst
die aktuelle Wattzahl auf dem Profil-Farbpunkt — du siehst den Verbrauch
also permanent, ohne das Menü zu öffnen. Am Netzteil erscheint wieder der
einfarbige Punkt. Bei 16×16 Pixeln sind zwei Ziffern lesbar, ab 100 W
zeigt das Icon „99".

## Akku-Zustand im Verlauf

Einmal täglich hält das Tray-Icon die aktuelle Akkukapazität in
`battery-health.csv` fest. Im Verbrauchs-Bericht erscheint daraus ein
Balkendiagramm mit dem Kapazitätsverlauf plus Vergleich gegen den
Neuzustand („aktuell 74,8 von 80,0 Wh — das sind 94 %"). Aussagekräftig
wird die Kurve erst nach einigen Monaten; kurzfristige Schwankungen sind
normal, weil Akku-Firmware die Kapazität regelmäßig neu schätzt.

## Leistungstest (was ein Profil leistet, nicht nur was es kostet)

Tray-Menü → **„Leistungstest fuer dieses Profil"** lässt etwa 20 Sekunden
eine reine Rechenlast laufen (einkernig und über alle Kerne) und misst
dabei gleichzeitig Verbrauch und CPU-Takt. Ergebnis z. B.:

```
Profil: Unterwegs
Einkern-Leistung   : 12,40 Durchlaeufe/s
Alle Kerne (24)    : 148,20 Durchlaeufe/s
CPU-Takt (Mittel)  : 1850 MHz
Verbrauch dabei    : 21,3 W
Effizienz          : 6,96 Durchlaeufe/s je Watt

Vergleich mit frueheren Messungen:
  Gaming         100 % Leistung    54,7 W   (04.09. 19:12)
  Unterwegs       38 % Leistung    21,3 W   (04.09. 19:31)
```

Damit siehst du erstmals das **Preis-Leistungs-Verhältnis**: Wenn
„Unterwegs" nur noch 38 % Leistung bringt, aber 61 % Strom spart, passt
die Drosselung – bringt es dagegen 20 % Leistung bei 30 % Ersparnis, ist
sie zu hart eingestellt und `CPU-Maximum` sollte höher.

Den Test in **jedem Profil einmal** unter gleichen Bedingungen starten
(gleiche Stromquelle, nichts anderes aktiv) – danach steht der Vergleich
auch im Verbrauchs-Bericht. Die Zahlen sind relativ und nur untereinander
vergleichbar, kein absoluter Benchmark-Wert.

## Hintergrund-Bremse

Im Unterwegs-Profil pausiert die App stromhungrige Hintergrunddienste und
gibt sie bei „Gaming"/„Ausgeglichen" wieder frei:

- `WSearch` – Windows-Suchindizierung
- `DoSvc` – Update-Auslieferungsoptimierung (lädt Updates auch für andere
  PCs im Netz hoch)

Wieder gestartet werden **ausschließlich Dienste, die die App selbst
gestoppt hat** (gemerkt in `services.json`) – manuell deaktivierte Dienste
bleiben unangetastet, und die Deinstallation gibt alles wieder frei.

Weitere Dienste oder Programme lassen sich in `Profiles.ps1` über
`$BackgroundServices` bzw. `$BackgroundProcesses` ergänzen. `$BackgroundProcesses`
ist bewusst leer: Programme wie OneDrive würden beendet und **nicht**
automatisch wieder gestartet – nur eintragen, wenn du das willst.
Abschalten lässt sich das Ganze pro Profil im Einstellungsfenster.

## Einstellungsfenster

Tray-Menü → **„Einstellungen ..."** öffnet ein Fenster für die Werte, die
man am ehesten anpassen will, ohne `Profiles.ps1` zu bearbeiten:

- je Profil: Helligkeit, Bildwiederholrate, CPU-Maximum, Turbo/Boost,
  Hintergrund-Bremse an/aus
- allgemein: Gaming-Mindestakku (die 40-%-Regel) und automatisches
  Umschalten beim An-/Abstecken

Gespeichert wird nach `profile-overrides.json`; `Profiles.ps1` liest die
Datei bei jedem Profilwechsel. Zwei Vorteile: es ist **keine
Neuinstallation nötig**, und ein Update überschreibt deine Anpassungen
nicht. „Standardwerte" löscht die Datei wieder. Alles andere (Zeiten,
WLAN, PCIe, Aufwachtimer …) bleibt in `Profiles.ps1`.

## Verbrauchs-Bericht (Diagramm)

Tray-Menü → **„Verbrauchs-Bericht anzeigen"** erzeugt aus `power-log.csv`
eine HTML-Seite und öffnet sie im Browser:

- **Verlaufsdiagramm** der gemessenen Watt, farbig nach Profil (rot =
  Gaming, blau = Ausgeglichen, grün = Unterwegs), mit Tooltip pro Balken
- Kennzahlen: Gesamtdurchschnitt, sparsamstes Profil, aufgezeichnete
  Akku-Stunden, aktuelle Akkukapazität
- Tabelle je Profil: Mittel-/Minimal-/Maximalverbrauch, hochgerechnete
  Laufzeit bei vollem Akku, Anzahl Messpunkte – inklusive Satz wie
  *„Unterwegs verbraucht im Mittel 58 % weniger als Gaming"*
- Tabelle je Tag (letzte 14 Tage)

Das Diagramm ist reines Inline-SVG – keine Bibliothek, kein Internet, die
Datei (`%LOCALAPPDATA%\PowerProfileSwitcher\verbrauch.html`) lässt sich
also auch offline öffnen oder weitergeben. Zeitraum ändern:
`New-PowerReport.ps1 -Days 30` (`0` = alles).

Weil nur im Akkubetrieb protokolliert wird, zeigt die Zeitachse
aneinandergereihte Akku-Phasen, nicht die durchgehende Kalenderzeit.

## Updates

Tray-Menü → **„Nach Updates suchen"** lädt das aktuelle Archiv aus dem
GitHub-Repository, vergleicht `$PowerProfileVersion` aus `Profiles.ps1`
mit der installierten Fassung und bietet die Aktualisierung an. Bestätigst
du, läuft das mitgelieferte `Install.ps1` (einmal UAC-Abfrage), danach
startet das Tray-Icon neu. Ohne Bestätigung passiert nichts, und
heruntergeladene Dateien werden anschließend wieder gelöscht.

Aktuelle Version: **1.7.1**

## Profil-Laufzeit im Menü

Unter der Verbrauchszeile steht jetzt, seit wann das aktuelle Profil
läuft und was es gekostet hat – z. B. *„Unterwegs seit 1 h 20 min – 18 %
Akku verbraucht"* (beim Laden entsprechend *„… – 12 % geladen"*). Der
Ladestand zum Zeitpunkt des Wechsels wird dafür in `current.json`
mitgeschrieben.

## Schutzregel: Gaming erst ab 40 % Akku

Liegt der Ladestand **unter 40 %**, wird das Gaming-Profil **nicht
aktiviert** – auch nicht am Netzteil. Stattdessen kommt eine
Benachrichtigung „Akku bei X % – Gaming ist erst ab 40 % vorgesehen",
und das bisherige Profil bleibt unverändert. So kann der Akku bei
niedrigem Stand erst laden, statt unter Volllast zu hängen.

Das gilt an allen Stellen gleich: Desktop-Verknüpfung, Startmenü, Hotkey
und automatisches Umschalten.

- Im Tray-Menü ist der Gaming-Eintrag währenddessen ausgegraut und heißt
  „Gaming – erst ab 40 % Akku".
- Beim **automatischen** Umschalten wird der Wunsch gemerkt: Steckst du
  bei 25 % das Netzteil an, meldet die App „Gaming folgt automatisch,
  sobald 40 % erreicht sind" – und schaltet dann von selbst um, sobald
  der Akku so weit geladen ist. Wählst du zwischenzeitlich von Hand ein
  Profil, wird die Vormerkung verworfen.
- Ohne verlässliche Akku-Werte (z. B. Desktop-PC oder Akku meldet nichts)
  greift die Regel nicht.
- **Schwelle ändern:** `$GamingMinBatteryPercent` ganz oben in
  `Profiles.ps1` (`0` schaltet die Regel ab), danach `Install.ps1` erneut
  ausführen.
- **Einmalig übergehen:** in einer Administrator-PowerShell
  `…\PowerProfileSwitcher\Set-PowerProfile.ps1 -Mode Gaming -Force`.
- Die Diagnose zeigt unter „Akku und Verbrauchsmessung", ob die Sperre
  gerade greift.

## Automatik, Hotkeys & Diagnose

**Automatisch umschalten** (standardmäßig **aus**, im Tray-Menü
aktivierbar): Netzteil abgezogen → Unterwegs, Netzteil angeschlossen →
Gaming. Erkannt wird das über den 15-Sekunden-Takt des Tray-Icons, der
Wechsel erfolgt also spätestens 15 s nach dem Um-/Ausstecken.
Die **GPU-Abschaltung bleibt dabei bewusst außen vor** (eigene Aufgabe
`PowerProfileSwitcher-Travel-NoGpu` mit `-SkipGpu`), damit nicht bei
jedem Ausstecken eine Neustart-Abfrage kommt. Willst du die dedizierte
GPU wirklich abschalten, wähle „Unterwegs" einmal von Hand.

**Hotkeys** – funktionieren auch im Vollbild-Spiel:

| Tastenkombination | Profil |
|---|---|
| `Strg+Alt+1` | Gaming |
| `Strg+Alt+2` | Ausgeglichen |
| `Strg+Alt+3` | Unterwegs |
| `Strg+Alt+4` | Video / Streaming |

Ist eine Kombination schon von einem anderen Programm belegt, wird sie
übersprungen und das in `tray.log` vermerkt – die übrigen funktionieren
weiter.

**Akku-Warnung**: Bei 20 % und 10 % Restladung meldet sich das Tray-Icon
mit der geschätzten Restlaufzeit beim aktuellen Verbrauch.

**Diagnose** (Tray-Menü → „Diagnose ausfuehren"): `Test-PowerProfile.ps1`
liest mit `powercfg /query` **zurück, welche Einstellungen auf deinem
Gerät tatsächlich angekommen sind**, und listet Soll- gegen Ist-Werte
mit Status `OK` / `ABWEICHUNG` / `NICHT UNTERSTUETZT`. Dazu kommen:
mögliche Bildwiederholraten deines Panels, erkannte Grafikkarten samt
Status, Akku-Zustand und ob die Verbrauchsmessung funktioniert, sowie der
Zustand aller geplanten Aufgaben. Der Bericht landet in
`%LOCALAPPDATA%\PowerProfileSwitcher\diagnose.txt` und öffnet sich im
Editor.

Damit kannst du direkt nachsehen, ob z. B. `PERFEPP` oder `CPMAXCORES`
auf deiner CPU wirklich greifen – falls dort `NICHT UNTERSTUETZT` steht,
ist das kein Fehler, sondern heißt nur, dass dein Gerät diesen Regler
nicht anbietet.

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

## Wenn das Tray-Icon verschwindet

Daran wurde in mehreren Schritten gearbeitet — der Stand in 1.7.1:

**Fehler in Version 1.4–1.7.0:** Die „Selbstheilung" setzte alle 15 s
`Visible = $true`. Das ist wirkungslos, denn WinForms bricht diesen Setter
ab, wenn die Eigenschaft aus seiner Sicht schon `true` ist — eine
Neuanmeldung bei der Taskleiste wurde also **nie** verschickt. Genau in dem
Fall, für den die Funktion gedacht war, tat sie nichts.

**Jetzt behoben durch drei Ebenen:**

1. **Echtes Neuanmelden**: `Visible` wird aus- *und* wieder eingeschaltet,
   was die Shell zwingt, das Symbol neu aufzunehmen.
2. **Auf die richtigen Ereignisse reagieren**: Das versteckte Fenster der
   App horcht jetzt auf `TaskbarCreated` (Explorer baut die Taskleiste neu
   auf) und `WM_DISPLAYCHANGE` (Anzeige- oder Grafiktreiber-Wechsel, z. B.
   beim GPU-Umschalten) — beides sind die Momente, in denen Windows die
   Symbole vergisst. Zusätzlich meldet sich das Icon alle 5 Minuten
   vorsorglich neu an.
3. **Watchdog**: Eine eigene geplante Aufgabe prüft alle 5 Minuten, ob der
   Tray-Prozess überhaupt noch läuft, und startet ihn sonst neu. Das greift
   auch dann, wenn der ganze Prozess stirbt und sich nicht mehr selbst
   helfen kann.

**So findest du heraus, was bei dir passiert:** In
`%LOCALAPPDATA%\PowerProfileSwitcher\tray.log` steht alle 30 Minuten
„Tray laeuft.", dazu jedes Neuanmelden des Icons und jeder Neustart durch
den Watchdog. Verschwindet das Icon und die Einträge laufen weiter, war es
die Taskleiste; brechen sie ab, ist der Prozess gestorben — dann steht die
Ursache meist direkt darüber im Protokoll.

**Bitte prüfe außerdem**, ob das Symbol nur im Überlauf gelandet ist:
Taskleisten-Einstellungen → *Andere Symbolleistenelemente* → PowerShell auf
„Ein" stellen. Windows verschiebt neu angemeldete Symbole gerne dorthin.

### Früher behoben (Version 1.4)

Zwei weitere Ursachen waren schon vorher behoben worden:

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
Helligkeit, Bildwiederholrate, GPU, WLAN-Sparmodus) stehen gesammelt in
**`Profiles.ps1`** – eine Zeile pro Einstellung mit Klartext-Label sowie
`Ac`- und `Dc`-Wert. Werte dort anpassen und anschließend `Install.ps1`
erneut ausführen, damit die geplanten Aufgaben die aktualisierte Datei
verwenden. Mit der Diagnose lässt sich danach prüfen, ob die neuen Werte
angekommen sind.

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
  Ein benannter Mutex verhindert, dass zwei Profilwechsel gleichzeitig
  laufen und sich gegenseitig überschreiben.
- `PowerMetrics.ps1` enthält die Mess-Funktionen (Watt, Restlaufzeit,
  Akku-Zustand) und wird von beiden Skripten eingebunden.
- `Profiles.ps1` enthält die Soll-Werte aller drei Profile an **einer**
  Stelle – sowohl das Setzen (`Set-PowerProfile.ps1`) als auch das Prüfen
  (`Test-PowerProfile.ps1`) benutzt genau diese Liste, damit Soll und Ist
  nicht auseinanderlaufen. Werte ändern → `Install.ps1` erneut ausführen.
- `Test-PowerProfile.ps1` erzeugt den Diagnose-Bericht (ohne Adminrechte
  lauffähig).
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
