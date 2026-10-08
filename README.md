# G30 Connect – iPhone-App 0.6

Native SwiftUI-App für iPhone mit iOS 16 oder neuer. Nach der Bluetooth-Verbindung wähle „Anmelden und Daten lesen“. Drücke die Ein-/Lichttaste auf Aufforderung einmal kurz. Die App behält die verschlüsselte Sitzung und fragt Akku, Geschwindigkeit, Controller-Temperatur und Spannung automatisch ab.

Der Nutzer hat die Anmeldung und verschlüsselte Versionsabfrage in 0.4 am Scooter bestätigt. Die Messwerte in 0.5 verwenden dokumentierte Standardregister; ihre Zuordnung unter XiaoDash muss am Gerät geprüft werden. Fehlende, unplausible oder veraltete Werte erscheinen nicht als aktuelle Daten. „Einstellungen auslesen“ prüft elf dokumentierte Einstellungsregister ausschließlich mit Lesebefehlen. XiaoDash-Tuning ist noch nicht implementiert. Keine Änderung von Fahrparametern oder Firmware. Keine Netzwerk-Uploads. Details zu Quellen, Lizenz und Teststand stehen in NOTICE.md.

Version 0.6 wurde auf Windows vorbereitet. Der folgende GitHub-Workflow muss die enthaltenen Swift-Tests und den iOS-Build noch ausführen.
## 1. Auf GitHub hochladen

1. Entpacke G30Connect-Update-0.6.zip auf deinem Windows-Laptop.
2. Erstelle auf https://github.com/new ein Repository namens `G30Connect`. Ein öffentliches Repository macht den hochgeladenen Quellcode für alle sichtbar. Es enthält keine persönlichen Scooter-IDs oder Passwörter. Standard-GitHub-Actions-Rechner sind für öffentliche Repositories kostenlos; private Repositories haben Kontingente und können Kosten verursachen. Prüfe bei privater Nutzung vorher deine Abrechnungseinstellungen.
3. Wähle im leeren Repository „uploading an existing file“. Lade den INHALT des entpackten Ordners hoch, nicht die ZIP-Datei und nicht einen zusätzlichen übergeordneten Ordner. `project.yml`, `README.md` und `Sources` müssen direkt im Repository liegen.
4. Wichtig: Auch `.github/workflows/build.yml` muss enthalten sein. Wenn der Browser den Punktordner beim Hochladen auslässt: Nach dem ersten Commit „Add file → Create new file“ wählen, als Dateinamen `.github/workflows/build.yml` eingeben und den Inhalt der lokalen gleichnamigen Datei hineinkopieren. Anschließend committen.

## 2. iPhone-App bauen

1. Öffne im Repository „Actions“.
2. Wähle „iPhone-App bauen“, dann „Run workflow“, nochmals „Run workflow“.
3. Warte auf das grüne Häkchen. Bei einem roten Kreuz den fehlgeschlagenen Schritt öffnen und dessen Fehlermeldung hier im Chat teilen.
4. Öffne den erfolgreichen Lauf. Unter „Artifacts“ lade `G30Connect-AltStore` herunter.
5. Entpacke diese Datei. Darin liegt `G30Connect.ipa`.

Der Workflow läuft nur bei manuellem Start. Er verwendet einen Standard-macOS-Runner, erzeugt das Xcode-Projekt mit XcodeGen und baut eine unsignierte Geräte-App. Das Artefakt bleibt drei Tage verfügbar. Apple-Zugangsdaten werden für diesen Build nicht benötigt und gehören nicht ins Repository. Erst AltStore signiert die App zur Installation mit deinem Account.

## 3. Auf dem iPhone installieren

1. Übertrage `G30Connect.ipa` in die Dateien-App deines iPhones, beispielsweise über iCloud Drive.
2. Lass AltServer auf dem Laptop laufen. Verbinde das iPhone per USB oder nutze die bereits eingerichtete WLAN-Verbindung mit AltServer.
3. Öffne AltStore Classic auf dem iPhone → „My Apps“ → „+“ und wähle die IPA.
4. Falls erforderlich, Entwicklerprofil und Entwicklermodus in den iPhone-Einstellungen bestätigen.
5. Öffne G30 Connect und erlaube Bluetooth.

Mit einem kostenlosen Apple-Account müssen seitlich installierte Apps regelmäßig (nach sieben Tagen) erneuert werden. AltStore Classic ist für diesen Weg erforderlich.

## 4. Erster Verbindungstest

1. Scooter einschalten; XiaoDash und andere Scooter-Apps auf allen Handys vollständig schließen.
2. In G30 Connect „Scooter suchen“ wählen. Die Suche endet nach 15 Sekunden.
3. Deinen Scooter anhand seines Bluetooth-Namens auswählen. Nicht wahllos andere Geräte verbinden.
4. Wenn Dienste angezeigt werden, „Bericht teilen“ antippen und den Bericht hier in den Chat kopieren. Der Bericht enthält die Schnittstellen, aber keine entschlüsselten XiaoDash-Befehle.
5. Bei einem Timeout erneut prüfen, ob eine andere App verbunden ist, und nochmals suchen.

Die Scannergebnisse können auch Lautsprecher und andere Geräte enthalten. Die App erkennt den Scooter nicht allein anhand einer Bluetooth-Kopplung in iOS. Die Verbindung erfolgt innerhalb dieser App.

## Weitere Entwicklung

Nach Installation von 0.6 im Stand anmelden und die Messwerte prüfen. Danach den Diagnosebericht im Chat teilen. XiaoDash-Konfigurationsregister und Tuning sind weiterhin nicht implementiert.

## Quellen

- Apple CoreBluetooth: https://developer.apple.com/documentation/corebluetooth
- XcodeGen: https://github.com/yonaskolb/XcodeGen
- GitHub Actions: https://docs.github.com/en/actions
- GitHub-Abrechnung: https://docs.github.com/en/billing/concepts/product-billing/github-actions
- AltStore Classic: https://faq.altstore.io/altstore-classic/your-altstore

## Lokaler Build auf einem Mac

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project G30Connect.xcodeproj -scheme G30Connect -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

Die IPA-Verpackung steht in `.github/workflows/build.yml`. Für direktes Installieren mit Xcode muss die Signierung aktiviert und ein eigenes Development Team ausgewählt werden.




## Hintergrund und Prüfung von Einstellungen in 0.6

Die App trennt beim Wechsel in den Hintergrund nicht mehr automatisch. UIBackgroundModes enthält bluetooth-central. iOS entscheidet weiterhin über Hintergrundlaufzeit und kann zeitgesteuerte Abfragen verzögern; eine dauerhaft unveränderte Aktualisierungsrate wird nicht zugesichert. Beendest du die App ausdrücklich, wird keine Weiterarbeit zugesichert. Hintergrundverbindung am iPhone prüfen.

Nach der Anmeldung „Einstellungen auslesen“ wählen. Die App liest einmal die Register 0x72, 0x73, 0x74, 0x75, 0x7B, 0x7C, 0x7D, 0x7F, 0x80, 0x81 und 0x90 abwechselnd mit Messwerten. Antworten sind Rohwerte und werden ohne ungeprüfte Bezeichnung exportiert. Nach Trennen bleiben die letzten Messwerte im Bericht klar als nicht mehr live gekennzeichnet.

Für tatsächliches XiaoDash-Tuning ist eine passende Protokollzuordnung nötig. Eine Nur-Lese-Aufzeichnung der Android-XiaoDash-Verbindung ist der nächste Untersuchungsschritt. Die Akkuspannung ist ein Messwert; die App kann daraus keine höhere physische Akkuspannung einstellen.

