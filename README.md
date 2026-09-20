# CMD-X

Eine kleine native macOS-Menüleisten-App für **⌘X → ⌘V im Finder**. Für einzelne und mehrere Dateien und Ordner. Ab macOS 13, Intel und Apple Silicon, ohne externe Bibliotheken.

## Verwendung

1. `CMD-X.xcodeproj` im vorhandenen Xcode öffnen, Scheme **CMD-X**, Ziel **My Mac**.
2. App starten und unter **Systemeinstellungen → Datenschutz & Sicherheit → Bedienungshilfen** freigeben. CMD-X erkennt die Freigabe automatisch.
3. Dateien oder Ordner im Finder auswählen und **⌘X** drücken.
4. Zielordner im Finder öffnen und **⌘V** drücken. Beim ersten Verschieben die **Finder-Steuerung** erlauben.

| Symbol | Bedeutung |
| --- | --- |
| Grauer Ring | Keine Dateien zum Ausschneiden vorgemerkt |
| Gefüllter Kreis in Akzentfarbe | Auswahl ist zum Verschieben vorgemerkt |
| Orange gepunkteter Kreis | Auswahl wird übernommen oder Finder verschiebt |

Das Menü zeigt die Anzahl vorgemerkter Elemente. **Ausschneiden aufheben** beendet die Vormerkung; die Dateien bleiben an ihrem Ort und die normale Kopie bleibt in der Zwischenablage. Optional kann CMD-X beim Anmelden starten. Für dauerhafte Nutzung die App an einem festen Ort, z. B. Programme, ablegen und dort erneut freigeben.

## Verhalten und Grenzen

- ⌘X lässt Finder die Auswahl nativ kopieren und merkt den Verschiebewunsch. Am Ursprungsort ändert sich bis zum Einfügen nichts.
- ⌘V verschiebt über Finder/Apple Events in dessen aktuellen Einfügeort. Auch ⌥⌘V nutzt bei einer aktiven Vormerkung denselben Ablauf. Ohne Vormerkung bleiben die Tastenkürzel unverändert.
- Textfelder (Umbenennen, Suche, „Gehe zum Ordner“), Dialoge und andere Apps werden nicht umbelegt. Bei unbekanntem Accessibility-Kontext bleibt die Originaltaste erhalten.
- Neue Zwischenablageinhalte oder ⌘C heben die Vormerkung auf. Ein laufender Transfer wird dadurch nicht abgebrochen. Neu kopierte Inhalte werden bei dessen Abschluss nicht überschrieben.
- Vor dem Verschieben werden Geräte-/Dateiidentität geprüft. Wurde eine Quelle gelöscht, ersetzt, umbenannt oder ist sie nicht erreichbar, muss sie neu ausgeschnitten werden.
- **Namenskonflikte werden nicht überschrieben oder zusammengeführt.** Finder meldet einen Fehler; die betroffenen Elemente bleiben vorgemerkt. Konflikt im Finder lösen oder anderes Ziel wählen und erneut ⌘V drücken. Erfolgreich verschobene Elemente werden aus der Vormerkung entfernt.
- Quelle und Ziel im gleichen Ordner gelten als offener Vorgang, nicht als erfolgreicher Transfer.
- Virtuelle Ziele wie Suchergebnisse müssen sich durch Finder als echter Einfügeort auflösen lassen. Sonst bleibt die Auswahl erhalten.
- Finder führt Transfers aus; es gibt keinen eigenen Lösch-/Kopier-Fallback und keine eigene Undo-Historie. Eine zuverlässige ⌘Z-Rücknahme von AppleScript-Verschiebungen wird nicht zugesichert.
- Keine Persistenz ausgeschnittener Elemente nach App-Neustart. Keine abgeblendeten Finder-Icons und kein „Ausschneiden“-Eintrag im Finder-Kontextmenü in dieser Version.
- Während eines Transfers wartet CMD-X auf Finder und verhindert doppelte Einfügevorgänge. Bei einem hängenden Laufwerk den Vorgang im Finder klären; CMD-X beendet ihn nicht zwangsweise.

## Projekt

AppKit / Swift 5-Modus, Deployment Target macOS 13. Ad-hoc-Signierung für lokale Entwicklung, Hardened Runtime und Apple-Events-Entitlement; keine App Sandbox. Für Distribution sind eigene Signierung und Notarisierung nötig.

Build-Produkte, Zwischenprodukte und Derived Data liegen unter **`Build/` im Projektordner**. Das geteilte Workspace-Setting setzt den Xcode-Derived-Data-Pfad; für CLI-Aufrufe zusätzlich immer `-derivedDataPath "$PWD/Build/DerivedData"` verwenden. Keine GitHub Actions.

- `ShortcutController.swift`: Event-Tap, Clipboard-Generation und Cut-Zustand.
- `FinderContext.swift`: konservative Accessibility-Prüfung des Finder-Fokus.
- `FinderMover.swift`: Dateireferenzen, asynchroner AppleScript-Prozess und Ergebnisse pro Element.
- `AppDelegate.swift`: Menüleiste, Berechtigungen, optionaler Autostart.

**Verifikationsstand:** Projektstruktur und Plist/XML-Dateien statisch geprüft. In der Implementierungsumgebung waren weder macOS noch Swift/Xcode verfügbar. Kompilierung, Finder-Scripting, Berechtigungsdialoge und Bedienung am Mac sind noch zu prüfen; dies ist keine bereits am Gerät verifizierte Release-Version. Siehe [Mac-Prüfung](docs/MACOS-CHECK.md).

API-Grundlage: [Apple CGEvent-Taps](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate(tap:place:options:eventsofinterest:callback:userinfo:)), [AppleScript-Sprachreferenz](https://developer.apple.com/library/archive/documentation/AppleScript/Conceptual/AppleScriptLangGuide/reference/ASLR_cmds.html).
