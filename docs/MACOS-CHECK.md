# Einmalige Prüfung auf dem Mac

Für Laufzeittests im Xcode-Target das eigene Team auswählen und die App mit **Apple Development** signieren. Ein Build mit `CODE_SIGNING_ALLOWED=NO` unten ist nur eine Compilerprüfung, keine Grundlage für Berechtigungstests. Alte Ad-hoc-Build-Einträge in Bedienungshilfen einmal durch das neue signierte App-Bundle ersetzen.

Mit Testdaten, nicht mit Originalen prüfen:

1. Bedienungshilfen zunächst ablehnen: Menüleiste erklärt fehlende Freigabe; normale Tastenkürzel funktionieren. Danach erlauben: Erkennung im Statusfenster prüfen; bei veraltetem Eintrag die genaue App erneut hinzufügen und neu starten.
2. Eine Datei, mehrere Dateien und eine Mischung aus Ordnern/Dateien ausschneiden. Vor ⌘V bleiben alle Quellen bestehen, Kreis gefüllt. In anderen Ordner einfügen: Inhalt vollständig am Ziel, Quellen verschoben, Ring leer.
3. Finder-Ansichten Symbole/Liste/Spalten/Galerie, Schreibtisch, mehrere Fenster/Tabs: Einfügeort ist der aktive Finder-Ort. Unbekannter Fokus darf nicht abgefangen werden.
4. Datei umbenennen, Finder-Suche, „Gehe zum Ordner“, TextEdit: normales Text-⌘X/⌘V. Ohne ausgeschnittene Dateien bleibt ⌘C/⌘V im Finder unverändert.
5. Nach ⌘X etwas anderes kopieren, auch in einer anderen App: Vormerkung weg. Während eines größeren Transfers kopieren: neue Zwischenablage nach Abschluss erhalten.
6. Namenskollision mit einer von mehreren Quellen: Zielinhalt bleibt unverändert, andere Elemente dürfen erfolgreich verschoben werden; nur Fehler bleiben vorgemerkt. Nach Auflösen erneut einfügen.
7. Gleiches Verzeichnis, schreibgeschütztes Ziel, abgelehnte Finder-Automation, entfernte/ersetzte Quelldatei: keine fälschliche Erfolgsmeldung, keine Datenverluste.
8. Unicode, Anführungszeichen, Backslash und Zeilenumbruch in Dateinamen. Externes Laufwerk und iCloud-Platzhalter separat prüfen. Symlinks/Finder-Aliasse ausdrücklich vor produktiver Nutzung prüfen.
9. ⌘V halten oder mehrfach drücken: kein zweiter Transfer. Leeren Zustand, Aufheben, Neustart und optionalen Autostart prüfen.

10. Beim Start nur ein Einrichtungsfenster. „Zugriff anfordern“ fragt ausschließlich nach bewusstem Klick die erste noch fehlende Freigabe über die System-API an (PostEvent, anschließend bei Bedarf AX); kein paralleles Öffnen der Einstellungen, keine automatisch wiederholten Anfragen. Unter macOS 27 heißt der Bereich „Gerätesteuerung und Datenzugriff“. Nach Freigabe erkennt die App den Wechsel; bei Widerruf stoppt die Überwachung. `needsAccessibility`, `needsPostEventAccess` und `tapUnavailable` getrennt prüfen. Auch bei verdecktem Menüleisten-Symbol die App erneut öffnen und das Statusfenster erreichen.
11. Falls ⌘X weiterhin piept: eine Testdatei im Finder markieren, einmal ⌘X drücken, dann Kreismenü → „Diagnose kopieren“. Bericht enthält OS/Build, laufenden App-Pfad, AX/PostEvent, tatsächlichen Tap-Status, Empfangszähler und letzten Fokus/Copy-Schritt. Keine Dateinamen oder Texteingaben werden erfasst. Diagnose kopiert bewusst neue Zwischenablage und hebt die vorgemerkte Auswahl auf; während eines Transfers ist sie deaktiviert. Bericht muss `permission-flow-2` enthalten.

Stand dieser Änderung: Quellen statisch geprüft; kein macOS-Build und kein Finder-Laufzeittest in dieser Umgebung. Der ausbleibende Tastaturempfang auf Patricks Mac ist noch nicht als behoben bestätigt. Referenzen: [AX-Anfrage](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions), [PostEvent-Anfrage](https://developer.apple.com/documentation/coregraphics/cgrequestposteventaccess%28%29), [macOS-27-Berechtigungsänderungen, Entwicklerberichte und Apple DTS](https://developer.apple.com/forums/thread/836770).

## Kopierbarer Codex-Auftrag

Modell: GPT-6 Astra · Effort: Medium · Arbeitsort: vorhandener lokaler Checkout von `patrick-boesch/CMD-X` auf dem Mac (für Xcode und Finder notwendig).

```text
Ziel: Die initiale CMD-X-Menüleisten-App auf macOS kompilierbar machen und verbleibende konkrete Integrationsfehler beheben.
Kontext: Repository patrick-boesch/CMD-X; AGENTS.md und README.md lesen. Implementierung bisher nur statisch in Linux geprüft. Vor Änderungen Branch, Remote und Arbeitsbaum prüfen; fremde Änderungen erhalten.
Scope: AppKit-Menüleiste, Finder-AX-Fokus, ⌘X/⌘V, Clipboard-Generationen, Finder-AppleScript und bestätigte Ergebnisse. Vorhandenes Xcode nutzen, keine Fenster blind öffnen.
Grenzen: Keine GitHub Actions, keine Simulatoren, keine Refactorings oder Dependencies. Höchstens ein erster macOS-Build, bei konkretem Codefehler gezielt korrigieren und einmal erneut prüfen. Hänger abbrechen und Log auswerten; ohne neue Erkenntnisse nicht wiederholen. Outputs ausschließlich im Projektordner.
Build nur falls nötig: xcodebuild -project CMD-X.xcodeproj -scheme CMD-X -configuration Debug -destination 'generic/platform=macOS' -derivedDataPath "$PWD/Build/DerivedData" CODE_SIGNING_ALLOWED=NO build
Akzeptanz: Build ohne Compilerfehler. Keine Dateilöschung bei ⌘X; kein Überschreiben bei Konflikten; ein- und mehrfache Datei-/Ordnerauswahl; Texteingabe bleibt normal; neue Clipboard-Inhalte werden erhalten; Ring erst nach bestätigtem Erfolg leer. Reale Finder-UI-Tests führt Patrick am Gerät aus; Teststatus und verbleibende Prüflücken ehrlich dokumentieren.
Stop: Nach gezielter Verifikation stoppen. Kein Signieren, Veröffentlichen oder zusätzlicher Build ohne konkreten Bedarf. Ergebnis und betroffene Dateien knapp nennen.
```

Modell: GPT-6 Astra · Effort: Medium.
