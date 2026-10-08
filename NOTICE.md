# G30 Connect 0.7 – Moduswahl mit Rückleseprüfung

Hardwareberichte des Nutzers: 0.4 bestätigte Anmeldung und verschlüsselte Version 0x8888. 0.5 bestätigte Akku, Geschwindigkeit, Controller-Temperatur und Spannung. 0.6 bestätigte elf Einstellungs-Leseantworten. Vergleich der Fahrmodi: 0x75 = 2 bei Sport, 1 nach Eco-Wechsel und 0 im ausdrücklich gemeldeten Drive-Modus; die anderen Register blieben gleich.

0.7 implementiert einen einzelnen Modus-Schreibbefehl CMD 02, Controller 0x20, Register 0x75, Daten [Modus, 0]. Quelle: NB_CTL_WORKMODE im Originaldokument https://cloud.scooterhacking.org/release/nbdoc.pdf : 0 NORMAL, 1 ECO, 2 SPORT, S16 R/W. Die Zuordnung ist beim Nutzer für Lesen bestätigt. Schreibfähigkeit und Persistenz unter seiner XiaoDash-Firmware sind noch ungetestet. Es wird kein separater Save-Befehl gesendet.

Kontrollablauf: frische Geschwindigkeitsabfrage, aktueller Modus, einmal schreiben, Bluetooth-Übertragung abwarten, lesen und Zielwert vergleichen. Abbruch bei Bewegung, unbekanntem Modus, zu alter Stillstandsmessung, Fehler oder Zeitlimit. Keine automatische Wiederholung und keine Aussage über Erfolg ohne passende Rückleseantwort. Hintergrundwechsel während einer laufenden Modusänderung trennt die Verbindung. Normale Telemetrie trennt beim Hintergrundwechsel weiterhin nicht absichtlich.

Neue pure Swift-Zustandstests prüfen Bewegung, ungültige Werte, bereits gewählten Modus, unpassende Antworten, Übertragungsbestätigung ohne falsche Erfolgsmeldung sowie abweichendes und passendes Rücklesen. Der Workflow führt diese zusammen mit den bestehenden unabhängigen .NET-Kryptovektoren, Tag-/Replay- und Telemetrietests aus. 0.7 ist auf Windows vorbereitet; noch kein Swift-Testlauf/iOS-Build oder Modus-Schreibtest am Gerät bestätigt.

Kryptografie: abgeleitet aus https://github.com/scooterhacking/NinebotCrypto (AGPL-3.0), C++/Swift; Upstream Swift Robert Trencheny (2020), Lex Nastin (2023). Änderungen: CommonCrypto statt CryptoSwift, Längen-/Tag-/Replay-Prüfungen, begrenzte Puffer, Tastenbestätigung, Zeitlimits, kein Schlüssel-/Seriennummer-Logging. Gesamtes Projekt AGPL-3.0-only, LICENSE liegt bei.

Weitere Recherche: https://nootnooot.codeberg.page/segway-ninebot-ble/devices/ninebot-kickscooter-max/ . G30-Stock-Adressen und ES-Adressen unterscheiden sich, etwa 0x73 und 0x90. Deshalb keine Schreibfreigabe der weiteren elf Rohwerte. Keine Motorstrom-, Geschwindigkeitslimit-, Feldschwächungs-, BMS- oder Firmwareänderungen. XiaoDash-Profile bleiben ungeprüft.
