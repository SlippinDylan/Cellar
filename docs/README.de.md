<div align="center">
  <img src="images/readme/app-icon.png" width="160" height="160" alt="Cellar-App-Symbol">
  <h1>Cellar</h1>
  <p>Verwalte die Entwicklungstools deines Mac in einer nativen App.</p>
  <p>
    <a href="../README.md">English</a> ·
    <a href="README.zh-CN.md">简体中文</a> ·
    <a href="README.zh-TW.md">繁體中文</a> ·
    <a href="README.ja.md">日本語</a> ·
    <a href="README.ko.md">한국어</a> ·
    <strong>Deutsch</strong> ·
    <a href="README.fr.md">Français</a> ·
    <a href="README.es.md">Español</a>
  </p>
</div>

Cellar vereint Homebrew-Software, globale npm-Pakete, Node.js-Versionen und Terminalkonfiguration in einer macOS-App. Sieh nach, was installiert ist, finde neue Tools, aktualisiere deine Software und prüfe vor einer Deinstallation, was entfernt wird.

> [!NOTE]
> Cellar 1.0 ist noch nicht öffentlich veröffentlicht. Es gibt noch kein Installationspaket zum Herunterladen und keinen Homebrew-Cask. Du kannst die App aus dem Quellcode bauen; die Abnahmeprüfungen mit einer echten Umgebung und der Benutzeroberfläche stehen noch aus.

## Was du tun kannst

| Aufgabe | In Cellar |
|---|---|
| Umgebung prüfen | Auf der Startseite siehst du den Status von Homebrew, Node.js, npm, nvm und der Terminalumgebung. |
| Installierte Software verwalten | Durchsuche und filtere Homebrew-Formulae, Casks und globale npm-Pakete in der Mediathek. Aktualisiere einzelne Einträge oder eine gefilterte Auswahl und deinstalliere einzelne Einträge. |
| Neue Tools finden | Suche unter „Entdecken“ nach Homebrew- und npm-Paketen und installiere einzelne Einträge, oder installiere unter „Wartung“ mehrere Pakete desselben Typs gleichzeitig. |
| Umgebung konfigurieren | Verwalte globale Node.js-Versionen mit nvm, Homebrew-Taps, npm-Registries sowie Themes und Plugins für Oh My Zsh. |
| Prüfen und bereinigen | Führe Homebrew-Diagnosen, npm-Cache-Prüfungen und Stapelinstallationen aus. Prüfe anschließend die unterstützten Bereinigungsaufgaben für Caches, ungenutzte Node-Versionen und alte Manager-Protokolle. |

Aufgabenfortschritt und aktuelle Ergebnisse bleiben beim Wechsel zwischen Seiten sichtbar. Bei teilweise erfolgreichen Stapelaufgaben werden auch die einzelnen Ergebnisse angezeigt.

Die Oberfläche unterstützt **Englisch, vereinfachtes Chinesisch, traditionelles Chinesisch, Japanisch, Koreanisch, Deutsch, Französisch und Spanisch**. Die Voreinstellung ist **Systemsprache verwenden**. Unter „Einstellungen > Allgemein“ kannst du eine Sprache auswählen; ein Sprachwechsel startet Cellar neu.

## Voraussetzungen und Verfügbarkeit

- **macOS 26 oder neuer** auf einem **Mac mit Apple Silicon** (`arm64`).
- **Xcode 26 oder neuer**, um die App aus dem Quellcode zu bauen.
- Homebrew, Node.js, npm und nvm sind Tools, die Cellar verwaltet; sie werden nicht mit der App ausgeliefert.

Wenn Command Line Tools oder Homebrew fehlen, kann Cellar den Systeminstallationsablauf öffnen. Das offizielle Homebrew-Installationspaket wird vor dem Öffnen überprüft. Für nvm stellt Cellar eine Installationsanleitung bereit.

App-Updates sind mit Sparkle über den gemeinsamen [Homebrew-Tap](https://github.com/SlippinDylan/homebrew-tap) konfiguriert. Der signierte Updatefeed und der Cask werden bei der ersten passenden Veröffentlichung erstellt. In Debug-Builds und gewöhnlichen lokalen Builds sind App-Updates deaktiviert.

## Aus dem Quellcode bauen

```bash
git clone https://github.com/SlippinDylan/Cellar.git
cd Cellar
open Cellar.xcodeproj
```

Wähle in Xcode das Scheme **Cellar**, **My Mac** und die Konfiguration **Debug** aus und drücke **⌘R**. Debug verwendet eine lokale Ad-hoc-Signatur (Sign to Run Locally). Du musst dich daher weder bei einem Apple-Entwicklerkonto anmelden noch ein Signaturzertifikat installieren.

Build über die Befehlszeile:

```bash
xcodebuild build \
  -project Cellar.xcodeproj \
  -scheme Cellar \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData-Debug
```

Die gebaute App liegt unter `build/DerivedData-Debug/Build/Products/Debug/Cellar.app`. Informationen zu Tests, Signaturen und Release-Builds findest du im [Entwicklungsleitfaden](development.md).

## Vor Änderungen an deiner Umgebung

- Globale npm-Pakete gehören zu einer bestimmten Node.js-Installation. Suchen und Vorgänge verwenden die ausgewählte Node-Umgebung; Cellar verwaltet keine projektlokalen npm-Abhängigkeiten.
- Für npm-Paketsuche und Änderungen ist eine unterstützte nvm-Installation erforderlich; andere erkannte Node-Installationen bleiben lesbar. Registry-Benutzereinstellungen und Cache-Wartung behalten ihre eigenen Voraussetzungen. Registry-URLs unterstützen HTTPS ohne Zugangsdaten und lokales HTTP auf `localhost`, `127.0.0.1` oder `[::1]`; andere HTTP-Adressen werden nicht unterstützt.
- Ein Wechsel der von Cellar verwendeten Node-Version gilt nur für die aktuelle Cellar-Sitzung, nicht für bereits geöffnete Terminals. Cellar verwaltet globale Node-/npm-Umgebungen und keine projektspezifischen `.nvmrc`-Dateien.
- Einzelne Paketinstallationen und Updates über die Karten in der Mediathek und unter „Entdecken“ starten direkt. Bei der Installation von Terminalkomponenten, Stapelvorgängen, Deinstallationen, Bereinigungen und Konfigurationsänderungen bestätigst du zuerst den Umfang. Laufende Aufgaben können nicht manuell gestoppt werden, und Cellar verhindert das Beenden, solange Aufgaben aktiv sind.
- Bei der Deinstallation von Homebrew-Casks können auch zuvor bestätigte zugehörige Daten entfernt werden, deren Zuordnung überprüfbar ist. Gemeinsam genutzte oder nicht überprüfbare Daten bleiben erhalten. Die Deinstallation von Formulae und npm-Paketen umfasst diese Bereinigung zugehöriger Daten nicht. Cellar führt kein Homebrew cleanup aus und entfernt verwaiste Abhängigkeiten nicht automatisch.
- Für die Bereinigung einiger Restdateien sind eine macOS-Autorisierung mit Administratorrechten oder Festplattenvollzugriff erforderlich. macOS verarbeitet die Passwörter; Cellar erfasst sie nicht und installiert keinen dauerhaften Dienst mit erhöhten Rechten. Eine Autorisierung garantiert nicht, dass jede Datei entfernt werden kann.
- Vorgänge können teilweise erfolgreich sein. Cellar meldet abgeschlossene und fehlgeschlagene Einträge, verspricht aber kein Zurücksetzen. Die Datei `.zprofile` und die Anmeldeshell bleiben unverändert.

## Daten und Netzwerk

Cellar hat keine Konten, keine Telemetrie und kein eigenes Backend. Toolabfragen, Suchen, Installationen, Plugins und App-Updates greifen auf offizielle Dienste oder von dir konfigurierte Quellen zu. Homebrew- und npm-Abfragen können außerdem in ihre eigenen Caches schreiben.

Installierte Homebrew-Casks lesen zuerst ihre lokalen `.app`-Symbole aus `/Applications` und `~/Applications`. Wenn kein lokales Symbol verfügbar ist, stammen Symbole offizieller Homebrew-Casks von [CaskFlow](https://github.com/alielsokary/CaskFlow) und werden über `cdn.jsdelivr.net` geladen. Das CDN erhält die angeforderte Cask-Kennung und übliche Verbindungsinformationen. Die MIT-Lizenz von CaskFlow wird mit der App ausgeliefert; die Rechte an den Softwarelogos bleiben bei ihren jeweiligen Inhabern.

| Lokale Daten | Speicherort |
|---|---|
| Laufzeitkopien der mitgelieferten Manager | `~/Library/Application Support/Cellar/Managers/<version>/` |
| Protokolle | `~/Library/Logs/Cellar/` |
| Heruntergeladene Softwaresymbole | `~/Library/Caches/com.dylanwang.Cellar/CatalogIcons/` |

Protokollstufe und Aufbewahrungsdauer lassen sich unter „Einstellungen > Allgemein“ festlegen. Protokolldateien enthalten weder rohe Befehle noch deren stdout/stderr. Aufgabenergebnisse bleiben nur für die aktuelle Sitzung erhalten.

## Dokumentation

Die ausführlichen Projektdokumente sind derzeit auf Chinesisch verfügbar: [Dokumentationsübersicht](README.md), [Produktanforderungen](requirements/product-requirements.md), [Architektur](architecture/macos-app-architecture.md), [Entwicklungsleitfaden](development.md) und [manuelle Abnahmecheckliste](manual-smoke-checklist.md).
