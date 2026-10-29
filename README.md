# lox2HUE

LoxBerry-Plugin, das Philips-Hue-Lampen mit Werten aus Loxone steuert. Es übernimmt die Aufgaben des bisherigen Pico-C-Bausteins (HUE_MitSchalter_v02_2026) im Miniserver: Loxone schickt nur noch Kanal und Wert, Umrechnung und Kommunikation mit der Bridge laufen auf dem LoxBerry.

Status: erste Version (0.1.0), noch nicht an einer echten Bridge getestet.

## Funktionen

Die Umrechnung entspricht dem Pico-C-Script und ist mit Tests gegen dessen Rechenweg abgesichert. Unterstützt werden der Loxone-RGB-Wert (R + G×1000 + B×1000000, je 0–100 %), Lumitech-Werte (ab 200000000, Helligkeit und Kelvin), Dimmer, Dimmer mit Glühbirnen-Kennlinie und Ein/Aus. Ziele sind einzelne Lampen oder Hue-Gruppen.

Für Lampen, deren Strom Loxone schaltet oder die an einem Zwischenstecker hängen, sendet das Plugin nach dem Einschalten eine Befehls-Salve, bis die Lampe hochgefahren ist. Zwischenstecker-Lampen werden zusätzlich überwacht und bei abweichendem Zustand nachgeführt, höchstens dreimal bis zum nächsten Befehl aus Loxone. Wiederholte AUS-Befehle werden 30 Sekunden lang unterdrückt.

Lichtwecker-Kanäle ersetzen das separate Pico-C-Programm „Lichtwecker“. Ein Lichtwecker-Kanal ist mit einem Lampen-Kanal verknüpft und wird in Loxone mit dem Ausgang A des Wecker-Bausteins verbunden. Solange dort 1 anliegt, fährt das Plugin die Lampe innerhalb der eingestellten Hochfahrzeit linear von 0 auf die Zielfarbe hoch (höchstens ein Befehl pro Sekunde, nur wenn sich der Wert ändert) und hält sie dann. Bei 0 geht die Lampe aus, die Leuchtdauer bestimmt also die Buzzer-Dauer im Baustein. Haltezeit und Pause des alten Programms entfallen dadurch. Sendet Loxone während der Routine selbst einen Wert an den Lampen-Kanal, endet die Routine ohne Ausschalten, `alloff` beendet alle laufenden Routinen. Ein Neustart des Daemons beendet eine laufende Routine.

Die Bridge wird über eine Treiberschicht angesprochen. Standard ist die Hue API v2 (HTTPS) mit Event-Stream: Zustandsänderungen und die Erreichbarkeit der Lampen kommen sofort von der Bridge, statt dass das Plugin sie abfragt. Für die runde Bridge der ersten Generation gibt es einen Treiber für die API v1. Weitere Treiber, etwa für Zigbee2MQTT, können später ergänzt werden.

## Voraussetzungen

LoxBerry 4.0 oder neuer, weil die Weboberfläche das LoxBerry Design System nutzt. Für die API v2 eine eckige Hue-Bridge mit Firmware ab 1948086000 oder die Bridge Pro.

## Installation

Das Repository als ZIP herunterladen und in LoxBerry unter Plugin-Verwaltung installieren. Danach in der Plugin-Seite die IP-Adresse der Bridge eintragen, den Knopf auf der Bridge drücken, auf Koppeln klicken und speichern.

## Anbindung in Loxone

Je Lampe ein virtueller Ausgang, der den Wert an den LoxBerry schickt.

Empfohlen ist UDP an das MQTT-Gateway des LoxBerry (Standardport 11884). Befehl je Kanal:

    lox2hue/<Kanal> <v>

Alternativ HTTP, Adresse `http://<loxberry>` und Befehl:

    /plugins/lox2hue/set.cgi?ch=<Kanal>&v=<v>

Alle Lampen schaltet der Kanal `alloff` mit einem Wert ungleich 0 aus.

## Umstieg vom Pico-C-Script

| Script | Plugin |
| --- | --- |
| Eingang I1–I12 | Kanal mit frei wählbarer ID, z. B. 1–12 |
| `lightOrGroupID` | Lampe / Gruppe (Nummer wie in der Hue-App bzw. API v1) |
| `inputType` 0 / 4 | Typ RGB (hue/sat) / RGB (xy); bei API v2 immer xy |
| `inputType` 1 / 2 / 5 | Dimmer / Ein/Aus / Dimmer als Glühbirne |
| `inputType` 3 / 6 | Ziel Gruppe |
| `powerMode` 0 / 1 / 2 | Immer Strom / Loxone schaltet Strom / Zwischenstecker |
| `DIMMER_SIMMIN/SIMMAX` | Bulb-Kennlinie je Kanal |
| `TRANSITION_TIME`, `BURST_TICKS`, `WATCH_*` | Erweiterte Einstellungen (in Millisekunden) |
| Eingang 13 „Alles aus“ | Kanal `alloff` |
| Lichtwecker: `DURATIONTIME`, `Rmax/Gmax/Bmax` | Lichtwecker-Kanal: Hochfahrzeit, Zielfarbe in % (255/212/179 entspricht 100/83/70) |
| Lichtwecker: `ADDTIME`, `TimeOut` | entfallen, die Buzzer-Dauer in Loxone bestimmt die Leuchtdauer |

Bewusste Abweichungen vom Script: Helligkeit wird auf 254 begrenzt (das Script sendete bei Lumitech 100 % den Wert 255), Mired auf 153–500, die sRGB-Gammaschwelle ist 0.04045 statt 0.04055, und ein Lumitech-Wert ohne Kelvin sendet nur die Helligkeit statt durch 0 zu teilen. Szenen pro Gruppe aus dem Script sind noch nicht übernommen.

## Aufbau

    bin/lox2hued.pl                    Daemon: MQTT-Eingang, Hauptschleife
    bin/lib/Lox2Hue/Convert.pm         Umrechnung Loxone -> Lampenbefehl
    bin/lib/Lox2Hue/Controller.pm      Salve, Überwachung, Zustand je Lampe
    bin/lib/Lox2Hue/Wakeup.pm          Lichtwecker
    bin/lib/Lox2Hue/Driver/HueV2.pm    Treiber Hue API v2 (+ EventStream.pm)
    bin/lib/Lox2Hue/Driver/HueV1.pm    Treiber Hue API v1
    webfrontend/htmlauth/index.cgi     Weboberfläche und AJAX
    webfrontend/html/set.cgi           HTTP-Eingang für Loxone
    t/                                 Tests (prove t/)

Die Konfiguration liegt in `config/lox2hue.json`. Der Daemon liest sie nach dem Speichern automatisch neu ein.

## Tests

    prove t/

Die Tests laufen ohne LoxBerry. Die Erwartungswerte der Umrechnung stammen aus dem Rechenweg des Pico-C-Scripts, kompiliert als C.
