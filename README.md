# lox2HUE

LoxBerry-Plugin, das Philips-Hue-Lampen mit Werten aus Loxone steuert. In Loxone können direkt MQTT-Ausgänge mit den Lampenbausteinen (Lichtsteuerung) in Loxone verbunden werden. Die HUE-PicoC-Programme sind nicht mehr nötig. Außerdem wird so die REST-API v2 von HUE angesprochen, die mit Verschlüsselung und Eventstreams zukunftsfähig ist. V1-API ist für alte Bridges noch als Backup auswählbar.

## Funktionen

Die Umrechnung von den Loxone RGB-%-Werten in HUE-Werte. Unterstützt werden der Loxone-RGB-Wert (R + G×1000 + B×1000000, je 0–100 %), Lumitech-Werte (ab 200000000, Helligkeit und Kelvin), Dimmer, Dimmer mit Glühbirnen-Kennlinie und Ein/Aus. Ziele sind einzelne Lampen oder Hue-Gruppen.

Für Lampen, deren Strom Loxone schaltet oder die an einem Zwischenstecker hängen, sendet das Plugin nach dem Einschalten eine Befehls-Salve, bis die Lampe hochgefahren ist. Mit API v2 meldet die Bridge per Event, wann eine Lampe wieder verbunden ist. Dann geht der Befehl sofort raus, gefolgt von zwei Bestätigungen nach 1 und 3 Sekunden, und die restliche Salve entfällt. Die Salve bleibt für den Fall nötig, dass Strom nur kurz aus war: Die Bridge bemerkt eine stromlose Lampe erst nach etwa 20 bis 30 Sekunden (beobachtet an einer echten Bridge, Firmware 1978545030). Zwischenstecker-Lampen werden zusätzlich überwacht und bei abweichendem Zustand nachgeführt, höchstens dreimal bis zum nächsten Befehl aus Loxone. Wiederholte AUS-Befehle werden 30 Sekunden lang unterdrückt.

Zusätzlich gibt es Kanäle für eine Lichtwecker-Funktion. Hiermit wird die HUE-Lampe langsam über einen einstellbaren Zeitraum von Aus auf einen ebenfalls einstellbaren Zielwert hochgefahren. Ein Lichtwecker-Kanal ist mit einem Lampen-Kanal verknüpft und wird in Loxone mit dem Ausgang A des Wecker-Bausteins verbunden. Solange dort 1 anliegt, fährt das Plugin die Lampe innerhalb der eingestellten Hochfahrzeit linear von 0 auf die Zielfarbe hoch (höchstens ein Befehl pro Sekunde, nur wenn sich der Wert ändert) und hält sie dann. Bei 0 geht die Lampe aus, die Leuchtdauer bestimmt also die Buzzer-Dauer im Baustein. Sendet Loxone während der Routine selbst einen Wert an den Lampen-Kanal, endet die Routine ohne Ausschalten, `alloff` beendet alle laufenden Routinen. Ein Neustart des Daemons beendet eine laufende Routine.

Die Bridge wird über eine Treiberschicht angesprochen. Standard ist die Hue API v2 (HTTPS) mit Event-Stream: Zustandsänderungen und die Erreichbarkeit der Lampen kommen sofort von der Bridge, statt dass das Plugin sie abfragt. Für die runde Bridge der ersten Generation gibt es einen Treiber für die API v1. Weitere Treiber, etwa für Zigbee2MQTT, können später ergänzt werden.

## Voraussetzungen

LoxBerry 4.0 oder neuer, weil die Weboberfläche das LoxBerry Design System nutzt. Für die API v2 eine eckige Hue-Bridge mit Firmware ab 1948086000 oder die Bridge Pro.

## Installation

Das Repository als ZIP herunterladen und in LoxBerry unter Plugin-Verwaltung installieren. Danach in der Plugin-Seite die IP-Adresse der Bridge eintragen, den Knopf auf der Bridge drücken, auf Koppeln klicken und speichern.

## Automatische Updates

Ab Version 0.2.3 bietet das Plugin automatische Updates an. Diese Version muss einmal von Hand installiert werden, danach lässt sich in der LoxBerry-Plugin-Verwaltung wählen, ob LoxBerry nur benachrichtigt oder Releases bzw. Pre-Releases selbst installiert. LoxBerry prüft einmal täglich `release.cfg` und `prerelease.cfg` aus dem main-Branch.

Ablauf für ein neues Release:

1. `VERSION` in `plugin.cfg` erhöhen und nach main mergen.
2. Auf GitHub ein Release mit dem Tag `v<Version>` auf main erstellen (bei einer Testversion „Set as a pre-release“ anhaken).
3. Erst danach in `release.cfg` (bzw. `prerelease.cfg`) `VERSION`, `ARCHIVEURL` und `INFOURL` auf die neue Version setzen und nach main bringen.

`ARCHIVEURL` zeigt auf das Quellcode-Archiv des Tags, ein eigenes ZIP muss nicht hochgeladen werden.

## Anbindung in Loxone

Je Lampe ein virtueller Ausgang, der den Wert an den LoxBerry schickt (MQTT-Bridge 

Empfohlen ist UDP an das MQTT-Gateway des LoxBerry (Standardport 11884). Befehl je Kanal:

    lox2hue/<Kanal> <v>

Also "virtueller Ausgang Befehl", als Analogausgang (Digitalausgang abwählen), bei "Befehl bei ein" eintragen: lox2hue/1 <v>  (für den ersten Kanal etc.), bei "Befehl bei aus" kann man eintragen: lox2hue/1 0 (muss aber nicht, da ja Loxone dann RGB=0 sendet)

Alternativ HTTP, Adresse `http://<loxberry>` und Befehl:

    /plugins/lox2hue/set.cgi?ch=<Kanal>&v=<v>

Alle Lampen schaltet der Kanal `alloff` mit einem Wert ungleich 0 aus.

## Lichtwecker

Anbindung an den Wecker-Baustein in Loxone (Ausgang A). Buzzertime auf gewünschte Leuchtdauer einstellen (Achtung: in Sekunden umrechnen), mit Befehlsausgang für MQTT verbinden (z. B. erster Wecker-Kanal w1: Befehl bei ein: lox2hue/w1 <v>).


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
