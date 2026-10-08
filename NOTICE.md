# G30 Connect 0.6 – Anmeldung und verschlüsselte Messwerte

Der Hardwarebericht für Version 0.4 bestätigt 5B-Antwort, Tastenbestätigung 5C01, Anmeldung 5D01 und eine verschlüsselte Versionsantwort 0x8888. Dieser Wert kann ein Firmware-Override sein. Die anschließenden unverschlüsselten Legacy-Tests antworteten nicht.

Version 0.5 behält die angemeldete Sitzung und liest nacheinander Controller-Register 0x22 (Akku, Prozent), 0x26 (Geschwindigkeit, 0.1 km/h), 0x3E (Temperatur, 0.1 °C), 0x47 (Spannung, 0.01 V). Grundlage: https://cloud.scooterhacking.org/release/nbdoc.pdf . Alle Abfragen sind CMD 01; keine Konfigurationsregister werden beschrieben. Zuordnung und Einheiten müssen am konkreten XiaoDash-Scooter verglichen werden. Unplausible Antworten werden verworfen, fehlende Antworten protokolliert. Werte älter als zehn Sekunden werden nicht angezeigt. Abfragen enden beim Abbruch oder Trennen. Seit 0.6 kein automatisches Trennen beim App-Wechsel; bluetooth-central ist aktiviert. iOS kann Timer im Hintergrund verzögern.

Quelle und Lizenz der Kryptografie: https://github.com/scooterhacking/NinebotCrypto (AGPL-3.0). Abgeleitet aus C++/Swift; Upstream Swift: Robert Trencheny (2020), Lex Nastin (2023). Anpassungen: CommonCrypto statt CryptoSwift, Längen-, Tag- und Replay-Prüfungen, begrenzte Puffer, Tastenbestätigung, Zeitlimits und kein Schlüssel-/Seriennummer-Logging. LICENSE liegt bei. Das Projekt steht unter AGPL-3.0-only.

Testumfang: Unabhängige .NET-AES/SHA1-Vektoren prüfen Anmeldung, abgeschnittene/beschädigte Frames und Replay-Antworten. Ergänzte Swift-Tests prüfen Telemetrie-Bytefolge, Vorzeichen, Skalierung und Wertebereiche. Der Workflow führt diese Tests und den iOS-Build auf macOS aus. Version 0.4 wurde vom Nutzer erfolgreich gebaut und am Scooter getestet. Version 0.5 wurde vom Nutzer erfolgreich am Scooter geprüft: alle vier Messwerte bestätigt. Version 0.6 ist auf Windows vorbereitet; Swift-Tests und iOS-Build sind noch auszuführen. Keine zugesicherte Tuningunterstützung.

Upload: Inhalt einschließlich Sources, Tests, .github, project.yml, LICENSE und NOTICE.md im bestehenden Repository aktualisieren; Workflow manuell starten und neue IPA über AltStore installieren.

Test im Stand: Verbinden → „Anmelden und Daten lesen“ → auf Aufforderung Ein-/Lichttaste kurz drücken → Messwerte mit XiaoDash vergleichen → Bericht teilen. Keine Anmelde-Rohpakete oder persönlichen Scooter-IDs im Export.

0.6: Gezielte Nur-Lese-Prüfung der elf dokumentierten Einstellungsadressen 0x72/73/74/75/7B/7C/7D/7F/80/81/90 mit CMD 01. Keine ungeprüften Schreibbefehle. Die öffentliche Community-Tabelle https://github.com/jx-grxf/scooter-tuning-db/blob/main/ninebot.json widerspricht der ES-Dokumentation unter anderem bei 0x74; sie wird deshalb nicht als belegte XiaoDash-Schreibzuordnung übernommen. Profile, Motorströme, Feldschwächung und Speedboost erfordern eine nachgewiesene Zuordnung zum konkreten XiaoDash-Protokoll. Letzte Messwerte bleiben nach Trennen im Export als nicht mehr live erhalten.

Weitere Primärquelle aus der Internetrecherche: https://nootnooot.codeberg.page/segway-ninebot-ble/devices/ninebot-kickscooter-max/ . Aus Segway-App-Konfigurationspaketen extrahierte G30-Tabelle. Dort 0x7B = DecMode/KERS, 0x7C = Cruise, 0x7D = FunBool, 0x7F = StartSpeed. Datenlängen und Schreibmethoden unterscheiden sich je nach Feld; keine XiaoDash-Bestätigung. 0x90 ist dort setMaxSpeed, im ES-Dokument headlight control. Daher nur Roh-Leseprüfung und kein Übernehmen der ES-Bedeutungen als Schreibfunktionen.

Die 0.6-Leseprüfung beginnt mit den modellbezogenen G30-Adressen 0x7B/7C/7D/7F/73/90, anschließend ES-Vergleichsadressen. Fortschritt zählt erfolgreiche und abgelaufene Abfragen. Unterbrochene Prüfungen werden als unvollständig markiert; keine Antwort wird als fehlende Bestätigung exportiert. Kein Feld wird allein anhand seines Rohwertes als beschreibbar freigegeben.

