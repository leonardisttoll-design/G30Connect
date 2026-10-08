# G30 Connect 0.4 – Anmeldung mit Taste

Der Nutzer hat den Build und Hardwaretest von 0.3 durchgeführt: Bluetooth-Verbindung, Notifications und Übertragung der Legacy-Leseanfrage erfolgreich; keine Antwort vom Scooter. 0.4 versucht den dokumentierten verschlüsselten Ninebot-Anmeldeablauf 5B → 5C (Taste) → 5D und anschließend eine einzelne Versionsabfrage.

Quelle und Lizenz: https://github.com/scooterhacking/NinebotCrypto (AGPL-3.0). Die Verschlüsselung ist aus den C++/Swift-Implementierungen abgeleitet und angepasst. Upstream Swift: Robert Trencheny (2020) und Lex Nastin (2023). Änderungen in G30 Connect: CommonCrypto statt CryptoSwift, Prüfungen für Paketlänge und Prüfsumme/Authentifizierungstag, Replay-Prüfung, begrenzte Puffer, Tastenbestätigung, zeitlich begrenzte Anmeldung und Entfernen von Schlüssel-/Seriennummer-Logging. Das vollständige Projekt wird unter AGPL-3.0-only bereitgestellt; LICENSE ist beigefügt.

Kompatibilität: Die Upstream-Dokumentation verifiziert Max BLE110/113/114. BLE117 und XiaoDash V3.7 sind nicht verifiziert. Eine erfolgreiche GATT-Verbindung belegt das Anmeldeprotokoll nicht. Keine zugesicherte Tuningunterstützung.

Testumfang: Unabhängige .NET-AES/SHA1-Testvektoren mit künstlichen Schlüsseln für Hello, Hello-Antwort, Tastenanforderung, Tastenbestätigung und Abschluss erzeugt. Der GitHub-Workflow kompiliert den Swift-Crypto-Test auf macOS und prüft dieselben Vektoren sowie abgeschnittene Frames, beschädigte Prüfsummen/Tags und Replay-Antworten. Diese Swift-Tests und der iOS-Build konnten auf dem Windows-Rechner noch nicht ausgeführt werden.

Der Test tauscht einen Kommunikationsschlüssel aus. Andere Apps können eine erneute Anmeldung benötigen. Auf tatsächliche Taste-01-Bestätigung warten; keine Umgehung durch Taste-00. Maximal 30 Sekunden Taste-Abfrage, maximal drei Abschlussversuche, Versionsabfrage einmal. Die gesamte Session bleibt im Speicher und wird nach Testende verworfen. Keine Firmware-, Tuning- oder Akkuschutzänderungen. Anmeldepakete und Schlüssel werden nicht exportiert.

Upload: Entpackten Inhalt einschließlich Sources, Tests, .github, project.yml, LICENSE und NOTICE.md in das bestehende Repository hochladen. Bereits vorhandene Dateien werden aktualisiert. Workflow danach manuell starten, neue IPA über AltStore installieren.

Test am Scooter: Im Stand verbinden, „Anmeldung mit Taste testen“ wählen. Erst auf Aufforderung die Ein-/Lichttaste einmal kurz drücken, nicht halten. Der Test fragt nach erfolgreicher Anmeldung automatisch das Versionsregister ab. Danach „Bericht teilen“. ESC-Override 8888 ist keine verlässliche Firmwareidentifikation.

