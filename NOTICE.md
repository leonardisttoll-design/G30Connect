# G30 Connect 0.5 – Anmeldung und verschlüsselte Messwerte

Der Hardwarebericht für Version 0.4 bestätigt 5B-Antwort, Tastenbestätigung 5C01, Anmeldung 5D01 und eine verschlüsselte Versionsantwort 0x8888. Dieser Wert kann ein Firmware-Override sein. Die anschließenden unverschlüsselten Legacy-Tests antworteten nicht.

Version 0.5 behält die angemeldete Sitzung und liest nacheinander Controller-Register 0x22 (Akku, Prozent), 0x26 (Geschwindigkeit, 0.1 km/h), 0x3E (Temperatur, 0.1 °C), 0x47 (Spannung, 0.01 V). Grundlage: https://cloud.scooterhacking.org/release/nbdoc.pdf . Alle Abfragen sind CMD 01; keine Konfigurationsregister werden beschrieben. Zuordnung und Einheiten müssen am konkreten XiaoDash-Scooter verglichen werden. Unplausible Antworten werden verworfen, fehlende Antworten protokolliert. Werte älter als zehn Sekunden werden nicht angezeigt. Abfragen enden beim Abbruch, Trennen oder Wechsel der App in den Hintergrund.

Quelle und Lizenz der Kryptografie: https://github.com/scooterhacking/NinebotCrypto (AGPL-3.0). Abgeleitet aus C++/Swift; Upstream Swift: Robert Trencheny (2020), Lex Nastin (2023). Anpassungen: CommonCrypto statt CryptoSwift, Längen-, Tag- und Replay-Prüfungen, begrenzte Puffer, Tastenbestätigung, Zeitlimits und kein Schlüssel-/Seriennummer-Logging. LICENSE liegt bei. Das Projekt steht unter AGPL-3.0-only.

Testumfang: Unabhängige .NET-AES/SHA1-Vektoren prüfen Anmeldung, abgeschnittene/beschädigte Frames und Replay-Antworten. Ergänzte Swift-Tests prüfen Telemetrie-Bytefolge, Vorzeichen, Skalierung und Wertebereiche. Der Workflow führt diese Tests und den iOS-Build auf macOS aus. Version 0.4 wurde vom Nutzer erfolgreich gebaut und am Scooter getestet. Version 0.5 ist auf Windows vorbereitet; Swift-Tests und iOS-Build sind noch auszuführen. Keine zugesicherte Tuningunterstützung.

Upload: Inhalt einschließlich Sources, Tests, .github, project.yml, LICENSE und NOTICE.md im bestehenden Repository aktualisieren; Workflow manuell starten und neue IPA über AltStore installieren.

Test im Stand: Verbinden → „Anmelden und Daten lesen“ → auf Aufforderung Ein-/Lichttaste kurz drücken → Messwerte mit XiaoDash vergleichen → Bericht teilen. Keine Anmelde-Rohpakete oder persönlichen Scooter-IDs im Export.
