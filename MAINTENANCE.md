# Wartung / Maintenance

## Deutsch

- CodeQL prüft GitHub-Actions-Workflows und eigenständige Python-Dateien bei Pull Requests, Änderungen am Hauptbranch und einmal pro Woche.
- Shell-Skripte und eingebettete Python-Blöcke werden weiterhin durch die vorhandenen Syntax- und Funktionstests geprüft. CodeQL deckt diese Bereiche nicht ab.
- Die verwendeten Paperless-, Redis- und PostgreSQL-Images werden täglich sowie bei relevanten Änderungen für Intel (amd64) und ARM (arm64) geprüft. Behebbare hohe/kritische Schwachstellen, Betriebssysteme ohne Sicherheitsunterstützung und unvollständige Prüfungen lassen den Prüflauf fehlschlagen. Sämtliche Befunde bleiben in den Berichten erhalten; die vollständigen Berichte werden 14 Tage aufbewahrt. Dabei werden keine Container gestartet.
- Dependabot schlägt Aktualisierungen als Pull Requests vor. Vor der Übernahme müssen die erforderlichen Prüfungen erfolgreich sein.
- Änderungen an der GitHub-Prüfung aktualisieren keine bereits installierten NAS-Pakete. Für ein Paketupdate gilt das jeweilige Handbuch; vorhandene Konfigurationen vorher sichern und beibehalten.

## English

- CodeQL checks GitHub Actions workflows and standalone Python files on pull requests, changes to the main branch and once a week.
- Existing syntax and functional tests continue to check shell scripts and embedded Python blocks. These areas are not covered by CodeQL.
- The Paperless, Redis and PostgreSQL images are scanned daily and on relevant changes for Intel (amd64) and ARM (arm64). Fixable high/critical vulnerabilities, end-of-life operating systems and incomplete scans fail the check. All findings remain in the reports; complete reports are retained for 14 days. No containers are started.
- Dependabot proposes updates as pull requests. Required checks must pass before merging.
- Changes to GitHub checks do not update packages already installed on a NAS. Follow the package manual for updates; back up and retain existing configuration.
