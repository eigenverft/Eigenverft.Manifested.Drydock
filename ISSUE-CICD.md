# CI/CD-Fehlerdiagnose (GitHub Actions)

Stand der Diagnose: 2026-07-23  
Bezug: fehlgeschlagene Läufe von `cicd.yml` / `.github/workflows/cicd.ps1`

## Kurzfassung

Der Build bricht **nicht** wegen fehlendem PSGallery-Key, fehlendem Token oder dem Commit `Test-WindowsPathLimits` ab.

Er bricht bei der Registrierung der GitHub-Packages-Quelle als PowerShell-Repository ab:

```text
Register-PSRepository: The specified repository 'github' is unauthorized and cannot be registered. Try running with -Credential.
```

Stelle: `.github/workflows/cicd.ps1` (Aufruf `Register-PSRepository` für `https://nuget.pkg.github.com/eigenverft/index.json`).

## Was im Log bereits ok war

- `Test-VariableValue` für `NuGetGitHubPush` und `PsGalleryApiKey` → Werte vorhanden
- PSGallery-Voraussetzungen → bestanden
- lokales Publish → ok
- `dotnet nuget add source` mit Token → wird vorher ausgeführt

Nicht erreicht wegen des Abbruchs:

- Publish nach GitHub Packages (`Publish-Module … -Repository github`)
- Publish nach PSGallery
- `gh release create`

## Zeitlicher Verlauf

| Datum | Ergebnis | Hinweis |
|-------|----------|---------|
| 2026-04-16 | letzter erfolgreicher Lauf | Commit: default-gateway relay proxy candidates |
| April–Juli | kein CI | keine Pushes auf `source/**` |
| 2026-07-22 | erster Fail | Commit: proxy status suppression switch |
| 2026-07-23 | gleicher Fail | Commit: Test-WindowsPathLimits |

Zwischen letztem Grün und erstem Rot waren **`cicd.ps1` und `cicd.yml` unverändert**.

## Was sich extern geändert hat

GitHub hat `windows-latest` / `windows-2025` Mitte Juni 2026 auf das Image **Windows Server 2025 + Visual Studio 2026** umgestellt.

Belege:

- [GitHub Changelog 2026-05-14](https://github.blog/changelog/2026-05-14-github-actions-upcoming-image-migrations/)
- [actions/runner-images#14017](https://github.com/actions/runner-images/issues/14017)

Im Fail-Log vom 22.07. steht u. a.:

- `POWERSHELL_DISTRIBUTION_CHANNEL=GitHub-Actions-win25-vs2026`
- Runner-Image-Version `20260707.563`
- PowerShell `7.6.3`, PowerShellGet `2.2.5`

Der erste CI-Lauf nach der langen Pause trifft also das **neue** Runner-Image.

## Was es nicht ist

- kein kaputter Autoresolve / `Get-ConfigValue`
- kein fehlender System-Token (`${{ github.token }}` wird in CI gesetzt und ist nicht leer)
- kein PSGallery-API-Key-Problem (dieser Schritt wird gar nicht erreicht)
- kein Fehler durch `Test-WindowsPathLimits`
- keine lokale Änderung an `cicd.ps1` als Auslöser zwischen Grün und Rot

## Bekannter Community-Kontext

Ähnliche Meldungen zu `Register-PSRepository` / Publish gegen GitHub Packages mit PowerShellGet 2.x und Auth sind bekannt (NuGet-v3-Feed, Credential-Verhalten, teils Unterschiede zu `dotnet nuget`).

Das erklärt die Fehlermeldung; es erklärt allein noch nicht zwingend, warum derselbe Code im April noch durchlief. Der zeitliche Bruch deckt sich aber mit dem Runner-Image-Wechsel und dem ersten CI danach.

## Empfohlene Gegenprüfung (ohne Code-Umbau)

1. Workflow einmal mit `runs-on: windows-2022` starten.
2. Wenn das wieder grün wird → starke Bestätigung für Image-/Umgebungsregression.
3. Wenn es auf `windows-2022` ebenfalls failt → eher GitHub-Packages-/Auth-Verhalten oder Org-/Package-Rechte prüfen.

## Relevante Runs

- Fail 2026-07-23: https://github.com/eigenverft/Eigenverft.Manifested.Drydock/actions/runs/29983748111
- Fail 2026-07-22: https://github.com/eigenverft/Eigenverft.Manifested.Drydock/actions/runs/29915211735
- Letzter Erfolg 2026-04-16: https://github.com/eigenverft/Eigenverft.Manifested.Drydock/actions/runs/24489910401
