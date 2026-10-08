# G30 Connect – iPhone-App 0.7

Native SwiftUI-App für iPhone mit iOS 16 oder neuer. Bluetooth-Anmeldung mit kurzer Tastenbestätigung, verschlüsselte Messwerte und eine erste Bedienfunktion: Drive/Eco/Sport auswählen.

## Stand und Funktionen

Der Nutzer hat 0.6 erfolgreich am Scooter getestet. Alle elf geprüften Einstellungsregister antworteten. Register 0x75 folgte den gemeldeten Fahrmodi: Sport 2, Eco 1, Drive 0. Dies entspricht NB_CTL_WORKMODE im dokumentierten Ninebot-Protokoll.

0.7 liest den Fahrmodus regelmäßig. Bei einer Auswahl liest die App zuerst aktuelle Geschwindigkeit und aktuellen Modus. Nur bei Stillstand (Geschwindigkeitsrohwert höchstens ±1, entsprechend ±0.1 km/h), bekanntem Modus und frischer Prüfung sendet sie genau einen verschlüsselten CMD 02 an Controller 0x20, Register 0x75, zwei Byte Little Endian. Die anschließende Leseantwort muss den Zielwert enthalten. Eine Bluetooth-Bestätigung gilt nicht als erfolgreicher Moduswechsel. Keine automatische Wiederholung des Schreibbefehls.

Die Lesefunktion ist am Gerät bestätigt. Der Modus-Schreibbefehl ist dokumentiert, aber auf diesem Scooter noch nicht getestet. 0.7 ist auf Windows vorbereitet; die Swift-Tests und der iOS-Build stehen aus. Motorstrom, Geschwindigkeitsgrenzen, Feldschwächung und XiaoDash-Profile sind weiterhin nicht implementiert.

## Hochladen und bauen

1. G30Connect-Update-0.7.zip entpacken.
2. Den Inhalt im bestehenden GitHub-Repository hochladen und committen. Sources, Tests, project.yml und .github/workflows/build.yml gehören direkt ins Repository.
3. Actions → iPhone-App bauen → Run workflow. Der Workflow führt Kryptografie-, Telemetrie- und Modus-Transaktionstests aus und kompiliert mit Xcode.
4. Bei Grün das Artefakt G30Connect-AltStore herunterladen und entpacken. Darin liegt G30Connect.ipa.
5. IPA über iCloud Drive in AltStore Classic → My Apps → + installieren. AltServer auf dem Laptop laufen lassen und das iPhone wie bisher verbinden.

## Erster Moduswechsel

Im Stand verbinden und anmelden. Warten, bis die Geschwindigkeit und der aktuelle Fahrmodus angezeigt werden. Einen anderen Modus wählen, etwa Eco → Sport. Display und Rücklese-Ergebnis vergleichen, anschließend Bericht teilen. Falls keine Rückleseantwort erscheint, zeigt die App das Ergebnis als unbekannt; den tatsächlichen Modus am Display prüfen. Für den Test ist keine Fahrt nötig.

## Hintergrund

Die App trennt beim normalen App-Wechsel nicht automatisch; bluetooth-central ist aktiviert. Die iOS-Hintergrundlaufzeit und Aktualisierungsrate sind noch nicht am Gerät bestätigt. Ein laufender Moduswechsel wird beim Wechsel in den Hintergrund durch Trennen beendet, damit kein wartender Bedienbefehl später ausgeführt wird. Ein bereits gesendeter Befehl kann dadurch nicht zurückgenommen werden; Ergebnis am Display prüfen.

## Diagnose und Daten

„Einstellungen auslesen“ prüft elf dokumentierte Adressen ausschließlich mit CMD 01. Rohwerte bleiben ohne unbelegte XiaoDash-Feldbezeichnungen. Ein Moduswechsel kann nicht gleichzeitig mit dieser Prüfung starten. Keine Seriennummern, Schlüssel oder Anmelde-Rohpakete werden exportiert. Keine Analytics oder Netzwerk-Uploads. Letzte Messwerte bleiben nach Trennen klar als nicht mehr live gekennzeichnet im Bericht.

Quellen und Lizenz stehen in NOTICE.md; das Projekt steht unter AGPL-3.0-only, LICENSE liegt bei.
