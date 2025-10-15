# Windows 10 LTSC 2021 - Clean & Quiet Baseline (Official Tools Only)

**Status:** Adopted
**Version:** 1.0.0
**Scope:** Windows 10 Enterprise 2021 LTSC (21H2, EditionID=EnterpriseS, build 19044+)
**Repository:** [https://github.com/tagor-sian/win10-ltsc-2021-clean-quiet-baseline](https://github.com/tagor-sian/win10-ltsc-2021-clean-quiet-baseline)
**License:** MIT
**Description:** A lean, predictable Windows 10 LTSC 2021 baseline with minimal background activity and telemetry. Uses official Microsoft mechanisms only (Policies/Registry, DISM Features & Capabilities, Scheduled Tasks, RunOnce). Conservative, no hacks; deterministic and idempotent. Ships the automation scripts (`PreOOBE.cmd`, `SetupComplete.cmd`, PowerShell helpers); deployment answer files are managed separately.

This document records the decisions, rationale, scope boundaries, and verification steps for the baseline. It is the single source of truth for what the project does and why.

---
---

## ADR: Fix PS interpolation in CreatePrimaryAdmin ($User: → ${User}:)

- **Context:** Stage A мог падать на сообщении `ADSI update failed for $User:` — PowerShell 5.1 некорректно парсил `$User:` и прерывал выполнение во время ADSI-обновления.
- **Decision:** точечно заменить текст на `ADSI update failed for ${User}:` без иных правок скрипта.
- **Consequences:** устранён фатальный стопор Stage A; прогнозируемость прогона повысилась.
- **Related:** см. “Idempotent Stage A; guard Stage B” про идемпотентность Stage A и защиту Stage B.

## 2A. Переезд сервисинга из XML в SetupComplete
- **Constraint (SKU):** Target **Windows 10 Enterprise LTSC 2021 (EnterpriseS)** or compatible **Enterprise** SKUs. Reason: `AllowTelemetry=0` (Security level) is supported on Enterprise.

**Решение.** Все операции DISM, политики (IE/Edge, DO, телеметрия, OneDrive и т.п.) выполняются в `SetupComplete.cmd`. В `autounattend.xml` остаются только базовые фазы (`windowsPE`, `generalize`, `specialize`, `oobeSystem`), без `FirstLogonCommands`.

**Мотивация.** Предсказуемость фаз, единая точка логирования, отсутствие гонок во время OOBE, идемпотентность. Перезагрузка не делается внутри SetupComplete, а планируется через RunOnce.

**Ограничения.** `SetupComplete.cmd` не вызывает `shutdown`. Перезагрузка возможна только через `RunOnce` при RC 3010/1641 или флаге `ALWAYS_REBOOT_AFTER_FIRST_LOGON=1`.

---

## 3A. Контракт между файлами

* `autounattend.xml`: без `FirstLogonCommands`, без `RunSynchronous`, без `ProductKey`; `ComputerName=*`, `TimeZone=Romance Standard Time`, `InstallToAvailablePartition=false`. Локали en-US на WinPE и oobeSystem.
* `SetupComplete.cmd`: весь пост-инсталл, DISM/политики/службы/задачи, подробное логирование, платформа-гейт на LTSC 2021, идемпотентность, запись RunOnce на единственный ребут.

---

## 6A. Таблица переноса настроек из XML
- **Pre-OOBE delivery:** `PreOOBE.cmd` is **embedded** into `install.wim` at `Windows\Setup\Scripts\`, and is invoked from unattend (`specialize`/`RunSynchronous`).

| Функция               | Раньше (XML) | Теперь (SetupComplete) | Как выполняется |
|-----------------------|--------------|-------------------------|-----------------|
| IE First Run policy   | FirstLogon   | SetupComplete           | `reg add ... DisableFirstRunCustomize=1` |
| Отключение IE feature | FirstLogon   | SetupComplete           | `DISM /Disable-Feature` с предчеком |
| WMP/XPS/Fax/Scan/PSR  | FirstLogon   | SetupComplete           | `DISM /Disable-Feature` |
| Work Folders          | FirstLogon   | SetupComplete           | `DISM /Disable-Feature` |
| RDC Infrastructure    | FirstLogon   | SetupComplete           | `DISM /Disable-Feature` |
| Анти-Edge                    | Разные места | SetupComplete           | Политики EdgeUpdate (UpdateDefault=0, опц. InstallDefault=0); без деинсталляции |
| Телеметрия/WER        | Разные места | SetupComplete           | Политики, службы, задачи |
| Delivery Optimization | Разные места | SetupComplete           | Политики DO (Mode 0) |
| RunOnce на ребут      | —            | SetupComplete           |`HKLM\...\RunOnce` + `shutdown /r` (условно при RC 3010/1641 или флаге ALWAYS_REBOOT_AFTER_FIRST_LOGON=1)|

---

## 6B. Профиль OOBE и инварианты XML

* Нет авто-создания пользователя и автологина.
* Онлайн-экраны MSA скрыты, локальный путь доступен.
* `ComputerName=*`, `TimeZone=Romance Standard Time`.
* `InstallToAvailablePartition=false`, ручная разметка.
* en-US локали в WinPE и oobeSystem.

---

## 6C. Правила качества

* Все операции DISM сопровождаются предчеком и логированием.
* Скрипты идемпотентны, повторный запуск безопасен.
* В `SetupComplete.cmd` запрещены прямые перезагрузки.

## 1. Objectives and principles

* Build a clean, quiet, predictable Windows 10 LTSC 2021 workstation profile.
* Minimal background activity and minimal telemetry.
* Official tools only: Group Policies and Registry under HKLM, DISM Features & Capabilities, Scheduled Tasks, and RunOnce. No hacks, no unsupported tricks.
* Deterministic and idempotent execution. Safe to re-run without harmful side effects.
* No reboots inside SetupComplete. A single reboot may be scheduled via RunOnce only when servicing returned 3010/1641 or when ALWAYS_REBOOT_AFTER_FIRST_LOGON=1 is set.

---

## 2. Installation flow

1. Install from media with `autounattend.xml` (en-US defaults, accept EULA, correct image index, OOBE flows toward local account creation).
2. After OOBE completes, Windows executes `SetupComplete.cmd` as SYSTEM.
3. All post-install configuration runs once, with detailed logging and guarded checks.
4. Post-install configuration completes. A reboot is scheduled via RunOnce **only** when servicing returned `3010/1641`, or when `ALWAYS_REBOOT_AFTER_FIRST_LOGON=1` is set.
5. First interactive sign-in happens. If a RunOnce reboot was scheduled, it occurs immediately after the first sign-in; otherwise the system remains logged in without an automatic reboot.
## 3. File layout and key paths

* Unattended answer file (stored outside this repo, delivered with the media)
  `autounattend.xml` on installation media root.

* Pre-OOBE script inside image
  `%WINDIR%\Setup\Scripts\PreOOBE.cmd`

* SetupComplete script location on media
  `\sources\$OEM$\$$\Setup\Scripts\SetupComplete.cmd`

* Companion PowerShell helpers
  `%WINDIR%\Setup\Scripts\BootstrapLocalAdmin.ps1`, `%WINDIR%\Setup\Scripts\CreatePrimaryAdmin.ps1`

* Runtime logs (review in this order)
  1. `%WINDIR%\Panther\PreOOBE.log`
  2. `%WINDIR%\Panther\SetupComplete.log`
  3. `%WINDIR%\Logs\DISM\SetupComplete-DISM.log`

* Script header in `SetupComplete.cmd` (compact):

  ```bat
  @echo off
  REM SPDX-License-Identifier: MIT
  REM Copyright (c) 2025 tagor-sian
  REM Source: https://github.com/tagor-sian/win10-ltsc-2021-clean-quiet-baseline
  REM Project: Windows 10 LTSC 2021 - Clean & Quiet Baseline (Official Tools Only)

  setlocal EnableExtensions EnableDelayedExpansion
  set "LOGFILE=%WINDIR%\Panther\SetupComplete.log"
  set "FAILED=0"
  goto :main
  ```

---

## 4. Logging and idempotence

* A dedicated `:log` subroutine writes timestamped lines into `%WINDIR%\Panther\SetupComplete.log`.
* Timestamp generation uses PowerShell (`Get-Date -Format o`), falling back to `%DATE% %TIME%` only if PowerShell fails.
* Each step logs `[SECTION]` and `[STEP]`. Warnings and errors include numeric return codes.
* Groups of related `reg add` operations use a local error flag to produce one consolidated warning.
* Single commands use an immediate `if errorlevel 1` handler on the next line.
* The script returns `%FAILED%` at exit, but never forces a reboot inside SetupComplete.
* Installers are invoked with reboot suppression: **MSI** via `REBOOT=ReallySuppress /norestart`; **EXE** with an equivalent `/norestart` switch to avoid reboots inside SetupComplete.

* **Unattend hygiene:** after `SetupComplete` finishes, remove `%WINDIR%\Panther\Unattend.xml` and `%WINDIR%\Panther\UnattendGC\*.xml`.

---

* **Timestamps:** ISO-8601 in logs via PowerShell (`Get-Date -Format o`).
* **Centralized DISM logging:** every DISM call goes through a runner that appends `/LogPath:%WINDIR%\Logs\DISM\SetupComplete-DISM.log /LogLevel:4`.
* **Return codes:** a single handler treats `0` as success; `3010/1641` as success with reboot required (sets `NEEDS_REBOOT=1`); anything else is failure and sets `FAILED=1`.
* **Config flags (defaults):** `LOG_TS_ENGINE=POWERSHELL`, `REBOOT_ON_RC=1`, `ALWAYS_REBOOT_AFTER_FIRST_LOGON=0`.
## 5. Platform gate

* The script validates it runs on Windows 10 Enterprise 2021 LTSC:

  * `EditionID=EnterpriseS`
  * `DisplayVersion=21H2`
  * `CurrentBuild >= 19044`

См. раздел **§5.1** ниже для подробностей и примера кода проверки.

---

**Mismatch policy (clarified):**
- **Edition** or **Build** mismatch → log **ERROR** and **exit** without changes.
- **DisplayVersion** mismatch → behavior is controlled by `STRICT_DISPLAYVERSION`:
  - `1` → log **ERROR** and **exit**;
  - `0` → log **WARN** and **continue** (best‑effort).

### 5.1 Platform gate — подробности и код

```bat
if /i not "%ED%"=="%REQUIRED_EDITION%" exit /b 1
for /f "tokens=1" %%# in ("%CB%") do set /a BUILD=%%#
if %BUILD% LSS %MIN_BUILD% exit /b 1
if /i not "%DV%"=="%REQUIRED_DV%" (
  if "%STRICT_DISPLAYVERSION%"=="1" exit /b 1 else call :log "[WARN] DV mismatch; proceeding"
)
```
## 6. Major decisions and rationale

### 6.1 Microsoft Edge

* Control Edge via **supported policies** only:
  - `HKLM\SOFTWARE\Policies\Microsoft\EdgeUpdate\UpdateDefault=0`
  - (optional) `InstallDefault=0` to block new channel installs.
* Do **not** remove Edge binaries and do **not** disable scheduled tasks by default. Those tactics are brittle across updates and are unnecessary when policies control updates/installs.
* Rationale: supported, predictable, and update-resilient behavior.
### 6.2 SmartScreen and Windows Defender

* SmartScreen is disabled for Explorer and for Edge as per profile requirements.
* Windows Defender is minimized using supported preferences:

  * No cloud protection and no sample submissions.
  * Real-time, IOAV, behavior monitoring, and PUA features are off as per this baseline.
  * We do not attempt to bypass Tamper Protection.
* If later a local-only PUA detection is desired, `PUAProtection=1` can be considered. Current baseline uses `0`.

### 6.3 Telemetry, Diagnostics, and WER

* Enterprise-allowed diagnostics level: `AllowTelemetry=0`.
* Feedback, CEIP, diagnostics, and Windows Error Reporting are disabled via policies and tasks.
* `WerSvc` is disabled. Tasks under Diagnostics and WER are disabled with soft handling if missing.

### 6.4 Delivery Optimization

* Delivery Optimization is set to HTTP-only:

  * `HKLM\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization\DODownloadMode=0`
* Rationale: quiet online baseline with no P2P. Mode 0 is supported and reliable across LTSC. Mode 99 (Simple) is more restrictive and typically used for air-gapped scenarios, which is outside this baseline.

### 6.5 Network quieting: WPAD, WinHTTP, LLMNR, IPv6 transition

* WPAD disabled on both stacks:

  * WinINET policy: `HKLM\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Internet Settings\DisableWpad=1`
  * WinHTTP key: `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\WinHttp\DisableWpad=1`
  * Reset WinHTTP proxy to direct:

    ```
    netsh winhttp reset proxy
    ```
* We do not disable the WinHttpAutoProxySvc service because it can break Windows Update and other WinHTTP clients in proxied or complex network environments. The keys above are the supported and sufficient control plane.
* LLMNR disabled:

  * `HKLM\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient\EnableMulticast=0`
* IPv6 transition technologies disabled if present:

  * `netsh interface teredo set state disabled`
  * `netsh interface 6to4 set state disabled`
  * `netsh interface isatap set state disabled`

### 6.6 OneDrive

* Block the Next Gen Sync Client via policy:
  - `HKLM\SOFTWARE\Policies\Microsoft\Windows\OneDrive\DisableFileSyncNGSC=1`
* Do **not** uninstall the client by default; policy-based disablement is idempotent and survives updates.
### 6.7 Services

* Disabled services with guarded checks:

  * `SysMain`, `WSearch`, `Spooler`, `DiagTrack`, `dmwappushsvc`, `WerSvc`, `WebClient`
* Nonexistent services are logged as info and do not count as failures.

### 6.8 Features and Capabilities

* SMBv1 and PowerShell 2.0 are disabled only if they are enabled, using DISM with no restart.
* Capabilities are removed with correct return code handling:

  * Quick Assist:

    ```
    dism /online /remove-capability /capabilityname:App.Support.QuickAssist~~~~0.0.1.0
    ```
  * SNMP Client:

    ```
    dism /online /remove-capability /capabilityname:SNMP.Client~~~~0.0.1.0
    ```
  * WMI SNMP Provider:

    ```
    dism /online /remove-capability /capabilityname:WMI-SNMP-Provider~~~~0.0.1.0
    ```
* DISM return codes are interpreted precisely:

  * `0` success
  * `3010` success, restart required
  * `1641` success, restart initiated by servicing stack
* Output is appended to the script log for diagnostics.

### 6.9 Windows Update

* Notify-only updates:

  * `AUOptions=2`
* Exclude drivers from quality updates:

  * `ExcludeWUDriversInQualityUpdate=1`
* No preview builds:

  * `ManagePreviewBuilds=1`, `ManagePreviewBuildsPolicyValue=1`
* No other Microsoft products:

  * `AllowMUUpdateService=0`
* Block OS upgrade offers:

  * `DisableOSUpgrade=1`
* Device metadata from Internet is off to reduce background network noise.

### 6.10 UX tweaks

* Autorun and AutoPlay disabled.
* Fast Startup disabled.
* File Explorer quick access recent and frequent items disabled.
* Power plan "Ultimate Performance" activated if it exists.

### 6.11 Component cleanup and reboot

* **Component Store:** `Dism /Online /Cleanup-Image /StartComponentCleanup [/ResetBase]` is executed via the DISM runner (central log + RC handling).
* **`/ResetBase`** permanently removes superseded component versions — rollback of previously installed updates becomes impossible; future updates install normally.
* **Reboot handling:** never reboot inside `SetupComplete`. If servicing returns `3010` or `1641`, set `NEEDS_REBOOT=1` and schedule a RunOnce `shutdown /r` to occur after the first interactive logon. Optional “always reboot after first logon” is off by default and can be enabled via `ALWAYS_REBOOT_AFTER_FIRST_LOGON=1`.
## 7. What we explicitly do not do

* Do not disable WinHttpAutoProxySvc. WPAD is controlled by supported keys instead.
* Do not manipulate undocumented Edge services. Policies and tasks are the supported path.
* Do not write under HKCU from SYSTEM context. All configuration is under HKLM or via policies.
* Do not ACL-deny or delete system folders for feature blocking.
* Do not embed reboots inside SetupComplete.

---

## 8. Risks and trade-offs

* SmartScreen disabled and Defender minimized by design. This reduces protection surface and is a conscious trade-off for a silent profile. Consumers of the baseline must understand and accept the risk.
* `DISM /ResetBase` removes rollback for the currently installed updates. This is intended for a clean, sealed base image.
* With WPAD disabled, environments that later introduce a proxy will require explicit WinHTTP proxy configuration.

---

## 9. Verification checklist after install

* Log exists at `%WINDIR%\Panther\SetupComplete.log` with no `[ERROR]`. Warnings are understood.
* Edge policies applied.
* OneDrive sync policy applied.
* Defender preferences applied as per baseline. SmartScreen disabled for Explorer and Edge.
* WPAD disabled on WinINET and WinHTTP. `netsh winhttp show proxy` reports direct access.
* LLMNR disabled. Teredo, 6to4, ISATAP disabled.
* WU UI shows notify behavior. Drivers and other MS products are not offered automatically, and no OS upgrade offers appear.
* Services `SysMain`, `WSearch`, `Spooler`, `DiagTrack`, `dmwappushsvc`, `WerSvc`, `WebClient` are disabled.
* SMBv1 and PowerShell 2.0 are disabled if they were enabled.
* Quick Assist, SNMP Client, and WMI SNMP Provider capabilities are removed or reported not applicable with correct DISM codes.
* Component cleanup executed. Reboot happened only once via RunOnce.

---

## 10. Change control and versioning

* Bump `Version:` in script header and `DECISIONS.md` when behavior changes, not for comment-only edits.
* Any new feature must meet the principles: official tooling, deterministic, idempotent, no reboots inside SetupComplete.

---

We do not append dated addenda; each decision is integrated into its canonical section (flow, logging, servicing, or feature-specific subsections). The git history acts as the chronological record of changes.
## 11. References in repository

* `README.md` - quick start, file placement, how to read the log, minimal how-to.
* `DECISIONS.md` - this document.
* `SECURITY.md` - enumerates security trade-offs and recommended compensating controls if needed.
* `LICENSE` - MIT.
* `autounattend.xml` - unattended installation.
* `SetupComplete.cmd` - post-install baseline script.

---

## 12. Maintainer

* Maintainer: `@tagor-sian`
  [https://github.com/tagor-sian](https://github.com/tagor-sian)

Contributions are welcome via issues and pull requests. Please keep changes aligned with the principles: official tools only, deterministic and idempotent behavior, and no reboots inside SetupComplete.

## Update (2025-09-19)

**Disk selection:** Use Windows Setup UI intentionally: set `OSImage/WillShowUI=Always`, omit `InstallTo` and `InstallToAvailablePartition`. Rationale: avoid unintended writes on multi-disk hosts; preserve control on prod.

**Policy application timing:** Apply privacy & local-account policies in `specialize` via `Microsoft-Windows-Deployment/RunSynchronous` so they take effect **before OOBE**.

**Privacy scope covered:** Disable Privacy Experience UI; enforce OFF state for diagnostics, tailored experiences, advertising ID, input personalization/online speech, location, find-my-device.

- **Decision:** Critical HKLM policies for OOBE are moved from inline `RunSynchronousCommand` to external `PreOOBE.cmd` (pass `specialize`), invoked by a **single** command. Motivation: XML validity, readability, escaping limits, centralized logging and RC.

## ADR-001: AutoAdminLogon только для консоли (Console)

**Дата:** 2025-10-02
**Контекст:** Нужно гарантированно войти локально после PreOOBE без сети/служб.
**Решение:** Используем стандартный `AutoAdminLogon` Winlogon, который работает **только** для консольной сессии.
**Последствия:** В VMConnect **Enhanced** (RDP) всегда будет экран входа — это ожидаемо и не является ошибкой автолога.

## ADR-002: Запись реестра через `reg.exe` с явными типами

**Дата:** 2025-10-02
**Контекст:** Провайдер реестра PowerShell в ранних тестах писал типы «не так»/не успевал «флашиться» до ребута.
**Решение:** Все ключи Winlogon/политик пишем через `reg.exe` с явным `REG_SZ`/`REG_DWORD`.
**Последствия:** Больше «шумного» кода, но предсказуемые типы и надёжность.

Дополнение: Прямой вызов `reg.exe` в PS 5.1: `& reg.exe … | Out-Null 2>$null`; читаем `$LASTEXITCODE`. Для `DELETE` допустимые RC: `{0,2}` (идемпотентность).

## ADR-003: RNG-шим для WinPS 5.1

**Дата:** 2025-10-02
**Контекст:** В Windows PowerShell 5.1 нет `RandomNumberGenerator.Fill`, нужен стойкий пароль без внешних модулей.
**Решение:** Добавлен `Invoke-RngFill` на `RandomNumberGenerator.Create()` и `New-StrongPassword` (≥20 символов, все классы).
**Последствия:** Нет внешних зависимостей; одинаковая криптография на всех хостах.

## ADR-004: Идемпотентность «взвод/откат»

**Дата:** 2025-10-02
**Контекст:** Скрипты могут запускаться повторно (ручные прогоны, кастомные сборки).
**Решение:** Операции безопасны при повторе: допуск кода 1378 для `Administrators`, удаления значений — «молча» при отсутствии, выход только при целевом состоянии.
**Последствия:** Стабильное поведение при регрессе/переустановках.

## ADR-005: Idempotent Stage A; guard Stage B

**Date:** 2025-10-15

**Context:** Previous runs of `CreatePrimaryAdmin.ps1` could attempt to re-add a user to Administrators and proceed with Winlogon rollback even when Stage A partially failed.

**Decision:**
- Stage A performs an ADSI membership pre-check and treats `net.exe localgroup` return codes `0` and `1378` as success, logging `A: SKIP (already member)` when no change is needed.
- Stage B (Winlogon and RunOnce rollback, `bootstrap` deactivation) executes only after Stage A reports success.
- Ban `cmd /c` wrappers in Windows PowerShell 5.1; invoke `net.exe` directly to preserve `$LASTEXITCODE` and reduce noise.

**Consequences:**
- Re-running the script is safe: existing Administrators membership is detected and Stage B is skipped on Stage A failure.
- Guarding Stage B prevents unwanted Winlogon resets if account provisioning fails, reducing lockout risk.

## ADR-006: EOL policy (CRLF for scripts, LF for Markdown)

**Date:** 2025-10-13

**Context.** Windows script hosts (`*.ps1/*.cmd/*.bat`) expect CRLF line endings. Markdown and most tooling are LF-friendly. Mixed/incorrect EOLs caused CI and runtime issues.

**Decision.**
- `.ps1/.cmd/.bat` → CRLF via `.gitattributes` and a CI guard (`.github/workflows/eol-guard.yml`).
- `.md` → LF.
- Other text → `* text=auto` (Git attributes).

**Consequences.**
- Deterministic behavior on Windows hosts.
- PRs that introduce LF-only lines in scripts are blocked by CI until fixed.
- Editors should be configured accordingly (see `CONTRIBUTING.md`).

