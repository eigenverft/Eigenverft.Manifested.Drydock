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
- `dotnet nuget add source` mit Token → schreibt die Quelle/Credentials erfolgreich in die NuGet-Konfiguration; dieser Befehl validiert das Token nicht gegen den Server

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

## Verifikation des letzten grünen Laufs

Der grüne Lauf vom 2026-04-16 hat den Remote-Publish-Pfad nicht nur übersprungen:

- Workflow-Run `24489910401` meldet den Schritt `Workflow Build/Deploy` als erfolgreich.
- Um `03:10:42Z` wurde anschließend der erwartete Commit `[2026-04-16] Auto ver bump from CICD to 1.20262.10856 [skip ci]` erzeugt.
- Dieser Commit liegt im Skript **nach** dem Publish zu lokalem Feed, GitHub Packages und PSGallery.

Damit ist belegt, dass der unveränderte Code im April einschließlich `Register-PSRepository` und der nachfolgenden Publish-Schritte erfolgreich durchlief. Der Unterschied zwischen April und Juli ist somit real und nicht lediglich ein wegen `remoteResourcesOk = $false` übersprungener Publish-Pfad.

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

Zusätzlich wurde PowerShell laut offizieller Runner-Ankündigung [`actions/runner-images#14150`](https://github.com/actions/runner-images/issues/14150) zwischen **2026-06-15 und 2026-06-22** auf sämtlichen Images von 7.4.x auf 7.6.x aktualisiert. Die Ankündigung nennt ausdrücklich, dass PowerShell 7.6 auf .NET 10 basiert, während 7.4 auf .NET 8 basierte, und dass Skripte mit Abhängigkeit von spezifischem .NET-Laufzeitverhalten betroffen sein können.

## Zwischenstand: Analyse des PowerShellGet-Quellcodes

Der betroffene Befehl stammt weiterhin aus **PowerShellGet 2.2.5**. Seine Signatur enthält den Parameter `-Credential`; diese Funktionalität ist also nicht mit PowerShell 7.6 neu hinzugekommen oder entfernt worden.

Der offizielle Quellcode zeigt folgenden Ablauf:

1. `Register-PSRepository` ruft `Resolve-Location` und anschließend `Ping-Endpoint` auf.
2. Nur ein explizit an `Register-PSRepository -Credential` übergebenes `PSCredential` wird bei diesem HTTP-Test verwendet.
3. Erhält der Test ohne Credential HTTP 401, versucht PowerShellGet einen eigenen Credential Provider.
4. `Get-CredsFromCredentialProvider` unterstützt dabei ausdrücklich nur Azure-Artifacts-Adressen (`pkgs.dev.azure.com` / `pkgs.visualstudio.com`). Für `nuget.pkg.github.com` liefert die Funktion sofort `$null`.
5. Bleibt der HTTP-Status 401, erzeugt PowerShellGet exakt die beobachtete Meldung `RepositoryCannotBeRegistered`.

Wichtige Folgerung: Das vorherige

```powershell
dotnet nuget add source ... --username ... --password ...
```

beweist nur, dass der .NET-/NuGet-Client die Quelle und die übergebenen Credentials in die NuGet-Konfiguration schreiben konnte. Laut offizieller .NET-Dokumentation fügt der Befehl eine Paketquelle zu den NuGet-Konfigurationsdateien hinzu; eine erfolgreiche Server-Authentifizierung wird dabei nicht nachgewiesen. Der PowerShellGet-Quellcode liest diese gespeicherten `dotnet nuget`-Credentials bei der Registrierung zudem nicht als `PSCredential` ein. `dotnet nuget add source` und `Register-PSRepository` verwenden hier getrennte Authentifizierungswege.

Damit ist die bisherige Annahme zu präzisieren:

- **Bestätigt:** Der konkrete Fehler entsteht, weil `Register-PSRepository` den GitHub-Packages-Feed ohne explizites `-Credential` prüft und dabei HTTP 401 erhält.
- **Noch nicht bestätigt:** Warum derselbe Ablauf im April 2026 erfolgreich war. Der Image-Wechsel bleibt ein plausibler Auslöser für die Verhaltensänderung, ist aber derzeit nur zeitlich korreliert.
- **Versionsvergleich:** Im April-Image waren PowerShell `7.4.14` und PowerShellGet `2.2.5` enthalten; im Juli-Fail laufen PowerShell `7.6.3` und weiterhin PowerShellGet `2.2.5`. Damit hat sich nicht die PowerShellGet-Funktion selbst aktualisiert, wohl aber die PowerShell-/ .NET-Laufzeit, über deren `HttpClientHandler` der Feed-Test erfolgt.

### Verifizierter Runner-Image-Vergleich

Offizielle `actions/runner-images`-Manifeste nahe den beiden Läufen zeigen:

| Komponente | letzter grüner Lauf / April-Image | Juli-Image nahe dem Fail |
|---|---:|---:|
| Image-Familie | Windows Server 2025 + Visual Studio 2022 | Windows Server 2025 + Visual Studio 2026 |
| Image-Version | `20260413.84.1` | `20260628.158.1` (nahe dem im Log genannten `20260707.563`) |
| PowerShell | `7.4.14` | `7.6.3` |
| PowerShellGet | `1.0.0.1`, `2.2.5` | `1.0.0.1`, `2.2.5` |
| NuGet CLI | `7.3.0.70` | `7.6.0.59` |
| Visual Studio | 2022 | 2026 |

Daraus folgt:

- Eine Änderung der **PowerShellGet-Version** oder der sichtbaren `Register-PSRepository`-Parameter ist als direkte Ursache unwahrscheinlich.
- Geändert haben sich jedoch PowerShell/.NET, NuGet und die gesamte Visual-Studio-/Credential-Provider-Umgebung.
- Von diesen Änderungen ist für die konkrete Fehlermeldung primär die PowerShell/.NET-HTTP-Ausführung relevant, weil `Ping-Endpoint` einen `System.Net.Http.HttpClientHandler` erzeugt und den Feed selbst prüft.
- Die NuGet-CLI-Version betrifft zwar den vorherigen `dotnet nuget add source`-Pfad, erklärt aber nicht unmittelbar den 401 aus dem separaten PowerShellGet-Ping.

### Einordnung: latenter Fehler versus auslösende Änderung

GitHub dokumentiert für die NuGet-Registry, dass für öffentliche wie private Pakete eine Authentifizierung erforderlich ist. Gleichzeitig unterstützt `Register-PSRepository` ausdrücklich `-Credential` und fordert diesen Parameter in der beobachteten Fehlermeldung an.

Daher ist die robusteste Bewertung:

- **Latenter Implementierungsfehler:** Das Skript konfiguriert Credentials für den `dotnet`-/NuGet-Client, übergibt sie aber nicht an den separaten PowerShellGet-Aufruf.
- **Wahrscheinlicher Trigger:** Der Wechsel von PowerShell 7.4/.NET 8 auf 7.6/.NET 10 beziehungsweise das neue Runner-Image hat ein zuvor erfolgreiches, aber nicht vertraglich garantiertes Verhalten verändert oder offengelegt.
- **Konsequenz:** Selbst wenn ein Rollback auf ein älteres Image den Build wieder grün macht, sollte die Credential-Übergabe korrigiert werden. Andernfalls bleibt der Workflow von einem zufälligen beziehungsweise extern veränderlichen Authentifizierungsverhalten abhängig.

### Minimaler, noch zu verifizierender Fix

Vor dem Aufbau von `$GitHubSourceRegistration` ein `PSCredential` aus Benutzername und Workflow-Token erzeugen und in den Splat-Hashtable aufnehmen:

```powershell
$GitHubCredential = New-Object System.Management.Automation.PSCredential (
    $GitHubPackagesUser,
    (ConvertTo-SecureString $NuGetGitHubPush -AsPlainText -Force)
)

$GitHubSourceRegistration = @{
    Name                  = $GitHubSourceName
    SourceLocation        = $GitHubSourceUri
    PublishLocation       = $GitHubSourceUri
    ScriptSourceLocation  = $GitHubSourceUri
    ScriptPublishLocation = $GitHubSourceUri
    InstallationPolicy    = 'Trusted'
    Credential            = $GitHubCredential
}
```

Dieser Fix ist aus dem PowerShellGet-Quellcode und der offiziellen GitHub-NuGet-Authentifizierungsdokumentation abgeleitet, wurde im Workflow aber noch nicht als A/B-Lauf bestätigt.

Referenzen:

- [GitHub Docs: Working with the NuGet registry](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-nuget-registry)
- [Microsoft Learn: dotnet nuget add source](https://learn.microsoft.com/en-us/dotnet/core/tools/dotnet-nuget-add-source)
- [Runner Images: PowerShell 7.4 → 7.6 rollout](https://github.com/actions/runner-images/issues/14150)

Quellcodebezug:

- `PowerShell/PowerShellGetv2`, `Register-PSRepository.ps1`
- `PowerShell/PowerShellGetv2`, `Ping-Endpoint.ps1`
- `PowerShell/PowerShellGetv2`, `Get-CredsFromCredentialProvider.ps1`

## Was es nicht ist

- kein kaputter Autoresolve / `Get-ConfigValue`
- kein fehlender System-Token (`${{ github.token }}` wird in CI gesetzt und ist nicht leer)
- kein PSGallery-API-Key-Problem (dieser Schritt wird gar nicht erreicht)
- kein Fehler durch `Test-WindowsPathLimits`
- keine lokale Änderung an `cicd.ps1` als Auslöser zwischen Grün und Rot

## Bekannter Community-Kontext

Ähnliche Meldungen zu `Register-PSRepository` / Publish gegen GitHub Packages mit PowerShellGet 2.x und Auth sind bekannt (NuGet-v3-Feed, Credential-Verhalten, teils Unterschiede zu `dotnet nuget`).

Das erklärt die Fehlermeldung; es erklärt allein noch nicht zwingend, warum derselbe Code im April noch durchlief. Der zeitliche Bruch deckt sich aber mit dem Runner-Image-Wechsel und dem ersten CI danach.

## Empfohlene Gegenprüfungen

Die frühere Empfehlung, lediglich auf `windows-2022` zu wechseln, isoliert die wahrscheinlich relevante Änderung **nicht mehr vollständig**: Auch `windows-2022` wurde im Juni 2026 auf PowerShell 7.6 / .NET 10 aktualisiert.

Empfohlene A/B-Tests in dieser Reihenfolge:

1. **Explizites Credential an PowerShellGet übergeben**
   Für `Register-PSRepository` aus Benutzername und `${{ github.token }}` ein `PSCredential` erzeugen und als `-Credential` mitsplatten. Wenn die Registrierung damit auf dem aktuellen Image gelingt, ist der unmittelbare Fehler behoben und der getrennte Auth-Pfad bestätigt.

2. **PowerShell-Laufzeit isolieren**
   Den Workflow testweise mit Windows PowerShell 5.1 (`shell: powershell`) ausführen, sofern der bestehende Kompatibilitätsanspruch des Skripts greift, oder PowerShell 7.4.14 explizit pinnen/installieren. Ein Erfolg unter 7.4/.NET 8 bei unverändertem Image wäre ein deutlich stärkerer Nachweis als nur `windows-2022`.

3. **Image-Familie separat prüfen**
   `windows-2022` kann weiterhin gegen die VS-2026-Image-Familie testen. Da dort jedoch ebenfalls PowerShell 7.6 läuft, trennt dieser Versuch nur Image-/VS-Komponenten, nicht die PowerShell-/.NET-Version.

4. **Sichere Statusdiagnose ergänzen**
   Vor der Registrierung den Feed einmal ohne und einmal mit einem aus dem Workflow-Token gebildeten Basic-/`PSCredential`-Kontext anfragen und ausschließlich HTTP-Status, PowerShell-Version, .NET-Version sowie geladene PowerShellGet-/PackageManagement-Versionen loggen. Keine Header, Tokens oder NuGet.Config-Inhalte ausgeben.

### Aktuelle Ursachenbewertung

- **Hohe Sicherheit – unmittelbare Fehlerursache:** `Register-PSRepository` führt einen eigenen unauthentifizierten HTTP-Test aus, erhält 401 und kann für GitHub Packages keinen unterstützten Credential Provider ermitteln.
- **Mittlere Sicherheit – Auslöser der Regression:** Wechsel von PowerShell 7.4/.NET 8 auf PowerShell 7.6/.NET 10 und gleichzeitig auf die VS-2026-Image-Familie. Der zeitliche Zusammenhang ist exakt durch die offiziellen Rollout-Daten belegt.
- **Noch offen:** Ob die Regression konkret durch .NET-HTTP-Verhalten, eine Änderung am GitHub-Packages-Service-Index oder eine andere Image-Komponente ausgelöst wurde. In den veröffentlichten .NET-10-Breaking-Changes wurde keine passende Änderung an `HttpClientHandler.UseDefaultCredentials` oder Basic-Authentifizierung gefunden.
- **Geringere Wahrscheinlichkeit:** Tokenformat oder Tokenberechtigungen als Ursache genau dieser Registrierungsmeldung, weil das Token dem fehlschlagenden `Register-PSRepository` derzeit gar nicht als Credential übergeben wird.
## Relevante Runs

- Fail 2026-07-23: https://github.com/eigenverft/Eigenverft.Manifested.Drydock/actions/runs/29983748111
- Fail 2026-07-22: https://github.com/eigenverft/Eigenverft.Manifested.Drydock/actions/runs/29915211735
- Letzter Erfolg 2026-04-16: https://github.com/eigenverft/Eigenverft.Manifested.Drydock/actions/runs/24489910401


## Reproduzierbarer Authentifizierungs-Proof

Zur belastbaren Verifikation wurden auf dem isolierten Branch `diagnostic/cicd-auth-proof` zwei Diagnosedateien ergänzt:

- `.github/workflows/cicd-auth-diagnostic.yml`
- `.github/workflows/cicd-auth-diagnostic.ps1`

Der Workflow ist manuell startbar und wird beim Push der beiden Diagnosedateien auf den Diagnose-Branch ausgeführt. Er testet als Matrix:

- `windows-2022`
- `windows-2025`
- `windows-latest`

Der Test baut oder veröffentlicht kein Paket und erstellt weder Commit, Tag noch Release. Seine Berechtigungen entsprechen für GitHub Packages dem Originalworkflow (`contents: read`, `packages: write`), damit der A/B-Test nur die Credential-Übergabe verändert. Das Diagnoseskript enthält dennoch keinen Publish-, Push-, Tag- oder Release-Befehl.

Gemessen werden vier voneinander getrennte Fälle:

1. direkter HTTP-GET auf den GitHub-Packages-Feed ohne Credential,
2. derselbe HTTP-GET mit dem `github.token` als explizitem Basic-/`PSCredential`,
3. der originale Ablauf `dotnet nuget add source` gefolgt von `Register-PSRepository` **ohne** `-Credential`,
4. derselbe `Register-PSRepository`-Aufruf **mit** explizitem `-Credential`.

Ein vollständiger Proof liegt vor, wenn gleichzeitig gilt:

- der anonyme HTTP-Aufruf wird mit HTTP 401/403 abgewiesen,
- der authentifizierte HTTP-Aufruf wird mit HTTP 2xx akzeptiert,
- `dotnet nuget add source` ist erfolgreich, aber `Register-PSRepository` ohne Credential schlägt weiterhin fehl,
- `Register-PSRepository` mit demselben Token als `PSCredential` ist erfolgreich.

Jeder Matrix-Job schreibt zusätzlich ein bereinigtes JSON-Artefakt mit Runner-, PowerShell-, PowerShellGet-, PackageManagement-, NuGet-Provider- und Ergebnisdaten. Token oder Credential-Inhalte werden nicht ausgegeben.

Status: **Authentifizierungsursache durch erfolgreichen Matrix-A/B-Test bestätigt.**


### Erster Testlauf: Harness-Fehler, noch kein Authentifizierungsbefund

Der erste Matrix-Lauf wurde am 2026-07-23 ausgeführt:

- Run: https://github.com/eigenverft/Eigenverft.Manifested.Drydock/actions/runs/29987312874
- Commit: `f967934`
- Runner: `windows-2022`, `windows-2025`, `windows-latest`

Alle drei Jobs erreichten die Laufzeitdiagnose und bestätigten PowerShell `7.6.3` sowie PowerShellGet `2.2.5`. Anschließend brach jedoch das Diagnoseskript selbst mit `The property 'Success' cannot be found on this object` ab. Deshalb ist dieser Lauf **kein Beleg für oder gegen die Auth-Hypothese**.

Ursache ist ein Fehler im Test-Harness: Mindestens eine Hilfsfunktion liefert neben dem strukturierten Ergebnis zusätzliche PowerShell-Pipeline-Ausgabe, sodass der Aufrufer statt genau eines Ergebnisobjekts ein Array erhält. Der Test wird so korrigiert, dass jede Probe genau ein explizites `PSCustomObject` zurückgibt und alle Neben-Ausgaben unterdrückt werden.


### Zweiter Testlauf: Authentifizierungsursache bestätigt

Der korrigierte Matrix-Lauf war auf allen drei Runnern erfolgreich:

- Run: https://github.com/eigenverft/Eigenverft.Manifested.Drydock/actions/runs/29987563652
- Commit: `41a7125`
- Ergebnis: alle drei Jobs grün

| Runner | Image | PowerShell | PowerShellGet | anonymes HTTP | authentifiziertes HTTP | `dotnet nuget add source` | Register ohne Credential | Register mit Credential |
|---|---|---:|---:|---:|---:|---|---|---|
| `windows-2022` | `win22 20260714.244.1` | `7.6.3` | `2.2.5` | `401 Unauthorized` | `200 OK` | erfolgreich, Exit `0` | Fehler `RepositoryCannotBeRegistered` | erfolgreich, Provider `NuGet` |
| `windows-2025` | `win25-vs2026 20260714.173.1` | `7.6.3` | `2.2.5` | `401 Unauthorized` | `200 OK` | erfolgreich, Exit `0` | Fehler `RepositoryCannotBeRegistered` | erfolgreich, Provider `NuGet` |
| `windows-latest` | `win25-vs2026 20260714.173.1` | `7.6.3` | `2.2.5` | `401 Unauthorized` | `200 OK` | erfolgreich, Exit `0` | Fehler `RepositoryCannotBeRegistered` | erfolgreich, Provider `NuGet` |

Die JSON-Artefakte bestätigen für jeden Runner unabhängig:

- `AnonymousRejected = true`
- `AuthenticatedAccepted = true`
- `DotNetSourceDidNotAuthorizePowerShellGet = true`
- `ExplicitCredentialFixedRegistration = true`
- `ProofConfirmed = true`

Die Fehlermeldung ohne Credential entspricht exakt dem produktiven Fehler:

```text
The specified repository 'github-auth-diagnostic' is unauthorized and cannot be registered. Try running with -Credential.
FullyQualifiedErrorId: RepositoryCannotBeRegistered,Register-PSRepository
```

Mit demselben `github.token`, lediglich als explizites `PSCredential` an `Register-PSRepository` übergeben, wird das Repository erfolgreich registriert.

Damit ist die **unmittelbare Ursache des aktuellen CI-Abbruchs bewiesen**:

> Das Token ist gültig und besitzt ausreichenden Zugriff. `dotnet nuget add source` macht diese Credentials jedoch nicht für den separaten HTTP-Test von PowerShellGet verfügbar. Der produktive `Register-PSRepository`-Aufruf fehlt `-Credential`.

Der Test beweist noch nicht, warum der implizite Ablauf im April 2026 funktioniert hat. Er zeigt aber, dass der robuste und notwendige Fix unabhängig von der aktuellen Windows-Image-Familie die explizite Credential-Übergabe ist.


### Laufzeit-Isolation PowerShell 7.4.14 versus 7.6.3

Um den historischen Bruch zwischen April und Juli genauer einzugrenzen, wird derselbe A/B-Test zusätzlich unter der offiziellen portablen PowerShell-Version `7.4.14` ausgeführt. Das offizielle ZIP und die zugehörige `hashes.sha256` werden direkt aus dem PowerShell-Release `v7.4.14` geladen und vor der Ausführung per SHA-256 geprüft.

Die zusätzliche Matrix läuft auf:

- `windows-2022` mit PowerShell `7.4.14`
- `windows-2025` mit PowerShell `7.4.14`

Verglichen wird mit den bereits bestätigten Läufen unter der vorinstallierten PowerShell `7.6.3`. Damit wird die PowerShell-/ .NET-Laufzeit von der Windows-Image-Familie getrennt betrachtet.

Status: **Testimplementierung ergänzt; Messergebnis folgt im nächsten Lauf.**
