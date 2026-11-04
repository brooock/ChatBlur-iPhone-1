# Brockworks – Protect your Chat (Projektname ChatBlur) 0.3

Store-Name: „Brockworks – Protect your Chat“ · Name auf dem Homescreen: „Protect Chat“ · Bundle-ID: de.brockworks.protectyourchat · Datenschutz/Anleitung: https://brockworks.de/protect-your-chat-dsgvo/

## Bildschirmaufnahmen anonymisieren (iPhone XR, ohne Mac, ohne Kosten)

ChatBlur findet frei eingegebene Schlagwörter (Namen, Telefonnummern, Firmen) in Bildschirmaufnahmen – zuerst WhatsApp-Chats, auch beim Scrollen – und macht die betroffene Textzeile im exportierten Video unkenntlich. Alles läuft lokal auf dem iPhone.

## Status – ehrlich

| | Stand |
|---|---|
| Implementiert | ja (siehe Funktionen) |
| Mit Xcode kompiliert | 0.2: ja (Codemagic, 04.11.2026) · 0.3: beim nächsten Build |
| Auf echtem iPhone XR getestet | 0.2: ja, ohne Abstürze; 2-min-Video ≈ 7–8 min Verarbeitung · 0.3: noch nicht |

## Funktionen

- Video aus „Fotos“ oder „Dateien“ wählen (MP4/MOV). Es wird eine Kopie bearbeitet, das Original nie verändert.
- Mehrere Schlagwörter (pro Zeile oder mit Komma getrennt).
- Texterkennung mit Apple Vision auf Deutsch + Englisch, direkt auf dem Gerät.
- Matching: Groß-/Kleinschreibung, Umlaute/Akzente, Satzzeichen und Mehrfach-Leerzeichen werden ignoriert.
  - Standard: **Ganzwort-/Phrasensuche** („Anna“ findet nicht „Annalena“).
  - Schalter „Auch Wortteile finden“.
  - Schalter „Lesefehler tolerieren“ (Standard an): 1 Fehler ab 5 Buchstaben, 2 ab 10. Solche Treffer gelten als unsicher.
  - Telefonnummern, Steuer-ID/Steuernummer, Kontonummern werden ziffernweise verglichen („0176 123456“ findet auch „+49 176 123456“).
  - IBAN, USt-IdNr. und andere Buchstaben-Ziffern-Codes werden ohne Leerzeichen verglichen und tolerieren 1–2 OCR-Lesefehler (O/0, I/1).
- Scrollende Chats: OCR alle 0,08–0,33 s (einstellbar), Treffer werden über die Scrollgeschwindigkeit von Bild zu Bild verfolgt, die Maske wird dazwischen flüssig mitbewegt und kurz vor/nach der Erkennung in Scrollrichtung weitergeführt.
- Unkenntlichmachung: Pixelierung + Unschärfe, Stärke einstellbar.
- Export als neue MP4 mit Originalton.
- Fortschritt mit Restzeit, **Abbrechen**, Speicherplatzprüfung, verständliche Fehlermeldungen.
- **Vorschau** des Ergebnisses mit Trefferliste (Zeitpunkt antippen = dorthin springen); unsichere Treffer sind orange markiert.
- Teilen / In Dateien sichern / In Fotos sichern – erst nach Bestätigung „Ich habe das Video angesehen“.
- Beschleunigung: Steht der Bildschirm still, wird das letzte Texterkennungs-Ergebnis wiederverwendet (spätestens jede Sekunde und bei jeder sichtbaren Änderung wird neu gescannt).
- Temporäre Kopien werden beim nächsten Start bzw. beim Wechsel des Videos gelöscht.

## Grenzen

Keine Garantie auf vollständige Anonymisierung. OCR kann Text übersehen – bei sehr schnellem Scrollen, kleiner Schrift, Kompression, Animationen oder sehr kurzen Einblendungen. Verwischt wird die ganze erkannte Textzeile (nicht nur das Wort, nicht die ganze Blase). Noch nicht enthalten: manuelles Hinzufügen/Verschieben von Blur-Rechtecken, Wahl Wort/Zeile/Blase (P1).

Die App muss während der Verarbeitung geöffnet bleiben. Grobe Laufzeit auf dem XR (geschätzt, nicht gemessen): 1 Minute Video ≈ 3–8 Minuten bei „Ausgewogen“.

---

## Kostenlos aufs iPhone XR – ohne Mac

Kosten: 0 €. Du brauchst: GitHub-Konto, Codemagic-Konto (Login mit GitHub), deine normale Apple-ID, USB-Kabel.
Einschränkung von Apple bei kostenloser Apple-ID: Die App läuft **7 Tage**, danach mit Sideloadly einfach neu aufspielen. (Dauerhaft geht nur mit dem kostenpflichtigen Apple-Developer-Programm.)

### 1. Code zu GitHub (einmalig)
1. Auf github.com → **New repository** → Name `ChatBlur` → **Private** → *Create*.
2. Auf der leeren Repo-Seite: **uploading an existing file**.
3. Den **Inhalt** dieses Ordners (nicht den Ordner selbst) hineinziehen: `ChatBlur`, `ChatBlur.xcodeproj`, `codemagic.yaml`, `README.md`, `.github`.
   Tipp: Ordner, die mit Punkt beginnen (`.github`), zeigt der Windows-Explorer evtl. nicht an – der ist nur die optionale Alternative zu Codemagic und kann fehlen.
4. **Commit changes**.

### 2. Bauen mit Codemagic
1. codemagic.io → *Sign up with GitHub* → **Personal account** (nur der hat die 500 Gratis-Minuten).
2. **Add application** → GitHub → Repo `ChatBlur` → Projekttyp **iOS App** (bzw. „Other“) → Codemagic erkennt `codemagic.yaml`.
3. **Start new build** → Workflow **ChatBlur – unsignierte IPA für Sideloadly** → Branch `main`.
4. Nach ca. 3–6 Minuten unter **Artifacts** `ChatBlur-unsigned.ipa` herunterladen.
5. Falls der Build rot ist: das Log `chatblur-build.log` (oder den kopierten Fehlertext) an Claude geben – dann gibt es die konkrete Korrektur.

### 3. Auf das iPhone XR installieren (Windows 10)
1. **iTunes** und **iCloud** direkt von apple.com installieren – *nicht* die Microsoft-Store-Versionen (die ggf. vorher deinstallieren).
2. **Sideloadly** von sideloadly.io installieren.
3. iPhone per USB anschließen, entsperren, „Diesem Computer vertrauen“.
4. In Sideloadly: IPA hineinziehen, Apple-ID eintragen, **Start**, Passwort/2FA-Code eingeben.
5. Auf dem iPhone: *Einstellungen › Allgemein › VPN und Geräteverwaltung* → deine Apple-ID → **Vertrauen**.
6. *Einstellungen › Datenschutz & Sicherheit › Entwicklermodus* → **an**, iPhone neu starten, bestätigen.
7. ChatBlur öffnen.

Nach 7 Tagen: Schritt 3.3–3.4 wiederholen (Daten der App sind dabei unwichtig, Videos liegen in Fotos).

### Alternative zu Codemagic
Im Repo liegt `.github/workflows/ios-unsigned-ipa.yml`: auf GitHub Reiter **Actions** → *ChatBlur unsigned IPA* → **Run workflow**. Ergebnis unter *Artifacts* (ZIP mit der IPA). Bei privaten Repos zählt jede macOS-Minute 10-fach gegen das Gratis-Kontingent.

---

## Technischer Ablauf

1. `AVAssetImageGenerator` holt Analysebilder im eingestellten Abstand (native Auflösung bis 1920 px).
2. `VNRecognizeTextRequest` (accurate, de-DE + en-US) liefert Textzeilen mit normierten Koordinaten (0…1); die besten 3 Lesarten jeder Zeile werden geprüft.
3. `KeywordMatcher` vergleicht normalisierten Text mit den Schlagwörtern.
4. Tracking: Jede Spur sagt anhand der letzten Scrollgeschwindigkeit voraus, wo ihr Text im nächsten Analysebild sein müsste, und übernimmt den nächstgelegenen Treffer desselben Schlagworts. Lücken bis ca. 3 Scanintervalle werden überbrückt.
5. Export: `AVVideoComposition` + Core Image (`CIPixellate` + `CIGaussianBlur`) pro Videobild, `AVAssetExportSession` übernimmt die Tonspur.

Dateien: `App.swift`, `ContentView.swift` (UI), `VideoProcessor.swift` (Analyse, Tracking, Export), `KeywordMatcher.swift` (Suche), `MovieTransferable.swift` (Import/Teilen), `Info.plist`.
