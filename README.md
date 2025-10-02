# Windows 10 LTSC 2021 - Clean & Quiet Baseline (Official Tools Only)

A lean, predictable Windows 10 LTSC 2021 baseline with minimal background activity and telemetry. Uses official Microsoft mechanisms only (Policies/Registry, DISM Features & Capabilities, Scheduled Tasks, RunOnce). Conservative, no hacks; deterministic and idempotent. Includes `autounattend.xml` and `SetupComplete.cmd`.

## Scope

## Supported SKUs / Requirements

> This baseline is intended for **Windows 10 Enterprise LTSC 2021 (EnterpriseS)** or compatible **Enterprise** SKUs.
> **Rationale:** the diagnostic data level **`AllowTelemetry=0`** ("Security") is supported on Enterprise tiers; on non-Enterprise editions the minimum effective level may be higher and behavior may differ.

* Windows 10 Enterprise LTSC 2021 (21H2, EditionID=EnterpriseS, build 19044+)
* No corporate integration required

## Files in this repo

* `autounattend.xml` - unattended install answer file
* `SetupComplete.cmd` - post-install baseline script
* `DECISIONS.md` - design decisions and rationale
* `BACKGROUND.md` - archived notes and history
* `LICENSE` - MIT

## Placement

> **Pre-OOBE delivery:** `PreOOBE.cmd` is **embedded** into the target OS image (`install.wim`) at
> `Windows\Setup\Scripts\PreOOBE.cmd`. Unattend (`specialize` → `RunSynchronous`) calls this path **inside** the deployed OS; it is **not** read from the installation media.

> Privacy/Security policies are applied **before OOBE** via external `PreOOBE.cmd`, invoked from `Autounattend.xml` in pass `specialize` (`Microsoft-Windows-Deployment/RunSynchronous`). The script resides at `%WINDIR%\Setup\Scripts\PreOOBE.cmd` inside the installed OS.


* Put `autounattend.xml` in the root of the installation media.
* Put `SetupComplete.cmd` at:

  ```
  \sources\$OEM$\$$\Setup\Scripts\SetupComplete.cmd
  ```
* Runtime log:

  ```
  %WINDIR%\Panther\SetupComplete.log
  ```

### Media layout example

```
<USB-ROOT>
├─ autounattend.xml
└─ sources
   └─ $OEM$
      └─ $$
         └─ Setup
            └─ Scripts
               └─ SetupComplete.cmd
```

> Note: save `SetupComplete.cmd` as UTF-8 without BOM, with CRLF line endings.


### Image binding (autounattend.xml)
- This answer file targets **Index 1** and sets `<cpi:offlineImage name="Windows 10 Enterprise LTSC">`.
- At runtime, Windows Setup selects the image by **Index**; the `<cpi:offlineImage>` entry is for **WSIM validation** and **self‑documentation** and does not affect drive letters or media paths.
- If you use another WIM/ESD, update the `name` to **exactly** match `Get-WindowsImage ... | Select ImageName` output, **or** remove the `name` attribute and keep `Index=...`.

## Install flow

1. Boot from media with `autounattend.xml`.
2. Finish OOBE. Windows runs `SetupComplete.cmd` as SYSTEM.
3. Script applies the baseline once.
4. First interactive sign-in happens. If servicing returned **3010/1641** (reboot required) or `ALWAYS_REBOOT_AFTER_FIRST_LOGON=1` is set, a single reboot is scheduled via **RunOnce** and occurs immediately after the first sign-in; otherwise **no reboot is scheduled**.

### Post-install hygiene
* Remove `%WINDIR%\Panther\Unattend.xml` and `%WINDIR%\Panther\UnattendGC\*.xml` after `SetupComplete` finishes.
## What this baseline does

> We do **not** disable the **WinHttpAutoProxySvc**; WPAD is controlled via supported WinINET/WinHTTP keys.

* Microsoft Edge **controlled via policies** (`EdgeUpdate\\UpdateDefault=0`; optional `InstallDefault=0`). No uninstall and no scheduler tampering by default.
* SmartScreen off for Explorer and Edge. Windows Defender minimized using supported preferences.
* Diagnostics level 0, CEIP and WER off.
* Delivery Optimization set to mode 0 (HTTP-only, no P2P).
* Network quieting: WPAD off via WinINET and WinHTTP keys, LLMNR off, Teredo/6to4/ISATAP off.
* OneDrive **sync disabled via policy** (`DisableFileSyncNGSC=1`). No client uninstall by default.
* Services disabled with guards: SysMain, WSearch, Spooler, DiagTrack, dmwappushsvc, WerSvc, WebClient.
* Features and Capabilities: SMBv1 and PowerShell 2.0 off if enabled; remove Quick Assist, SNMP Client, and WMI SNMP Provider with correct DISM return-code handling.
* Windows Update in notify-only mode, no drivers, no preview, no other Microsoft products, OS upgrade offers blocked.
* Component cleanup with `/ResetBase` to seal the image.

## Post-install quick check

* Log exists at `%WINDIR%\Panther\SetupComplete.log` with no `[ERROR]`.
* `netsh winhttp show proxy` shows direct access. No WPAD or LLMNR.
* Edge and OneDrive are **controlled/blocked by policy**.
* WU UI shows notify behavior. No drivers or other MS products auto-offered.
* Disabled services stay disabled after reboot.
* DISM capability removals reported success or not applicable.

For the full verification list, see `DECISIONS.md` §9.

### Логирование

- Таймстемпы **ISO-8601** через **PowerShell**; фоллбэк — `%DATE%`/`%TIME%`.
- **DISM** пишет в стандартный `%WINDIR%\Logs\DISM\dism.log`. В `SetupComplete.log` логируются вызванные команды DISM и финальные коды возврата.
- Подавление ребутов установщиков: **MSI** запускаются с `REBOOT=ReallySuppress /norestart`, **EXE** — с эквивалентным `/norestart`.* WebClient disabled is visible in the log as: `[OK] WebClient Start=0x4 State=1 (STOPPED)`.

## Known trade-offs

See `SECURITY.md` for details. Highlights:

* SmartScreen is disabled and Defender is minimized by design.
* `/ResetBase` removes rollback for the currently installed updates.
* With WPAD off, proxies must be configured explicitly if needed later.

See also `DECISIONS.md` §8 for rationale and boundaries.

## License

MIT

## Maintainer

`@tagor-sian` - [https://github.com/tagor-sian](https://github.com/tagor-sian)

## Contributing

Issues and pull requests are welcome. Please keep changes aligned with the project principles: official tools only, deterministic and idempotent behavior, and no reboots inside SetupComplete.



### File encoding & EOL
- All scripts (`*.cmd`, `*.bat`, `*.ps1`) and deployment XMLs are stored as **UTF-8 (no BOM)** with **CRLF** line endings.
- Markdown and other docs can use LF or CRLF consistently (repo policy prefers LF for `.md`).
- Reasoning: batch interpreters may misbehave with UTF-8 BOM; Windows tooling expects CRLF by default.

**Contributing note.** To keep diffs clean and reviews easy: **pull requests that change only file encodings or line endings should avoid mixing those changes with unrelated edits**. If a PR unintentionally rewrites EOL/encoding across files, maintainers may ask to **revert the unrelated EOL-only diffs** or split them into a separate PR.
## Further reading

* `DECISIONS.md` - authoritative design decisions
* `BACKGROUND.md` - archived reasoning and notes
## Smoke test (короткая проверка)

- WSIM валидирует `autounattend.xml` без ошибок.
- Установка проходит до OOBE с локальным путём, без MSA-экранов.
- `SetupComplete.cmd` исполнился один раз и записал `%WINDIR%\Panther\SetupComplete.log`.
- Если сервисинг вернул 3010/1641 или включён `ALWAYS_REBOOT_AFTER_FIRST_LOGON=1`, сразу после первого входа выполнится один ребут через RunOnce; иначе ребут не планируется.
- После ребута функции IE/WMP/XPS/Fax/Scan/WorkFolders/PSR отключены, Edge не возвращается.
- Телеметрия и DO по политике, службы и задачи выключены как задумано.

---

## Ключевые дополнения

### Совместимость
Скрипт **SetupComplete.cmd** рассчитан на **Windows 10 Enterprise LTSC 2021** (21H2, сборка ≥ 19044). В шапке скрипта есть параметры совместимости, которые позволяют либо строго требовать нужную версию, либо работать в «best‑effort» режиме:
**По умолчанию:** репозиторий поставляется с `STRICT_DISPLAYVERSION=0` (режим *best‑effort*).


```bat
:: --- compatibility controls ---
set "REQUIRED_EDITION=EnterpriseS"
set "REQUIRED_DV=21H2"
set "MIN_BUILD=19044"
set "STRICT_DISPLAYVERSION=0"  :: 1 = строгий отказ при несовпадении DV, 0 = предупреждение и продолжение
```

Логика проверки в `SetupComplete.cmd`:
- Если `EditionID` ≠ `EnterpriseS` → **ошибка и выход**.
- Если `CurrentBuild` < `19044` → **ошибка и выход**.
- Если `DisplayVersion` ≠ `21H2`:
  - при `STRICT_DISPLAYVERSION=1` → **ошибка и выход**;
  - при `STRICT_DISPLAYVERSION=0` → **предупреждение в логе** и продолжение (best‑effort).

**Рекомендация.** Для контролируемых продакшн‑окружений включайте `STRICT_DISPLAYVERSION=1`. Для форков и адаптаций оставляйте `0` и меняйте `REQUIRED_*` под свою цель.

Дополнительно: все шаги `SetupComplete.cmd` пишутся живыми метками времени (вычисляются при каждом вызове `:log`), что помогает увидеть длительные места, сопоставить события с логами `DISM`/`CBS` и разбирать багрепорты. Реализация целиком на `cmd` без вызова PowerShell на каждую строку.

## Update (2025-09-19)

- Windows Setup now **always shows disk/partition selection UI** (`WillShowUI=Always`). We removed `InstallTo*` to avoid accidental installs to non-system disks on multi-disk machines.
- OOBE privacy wizard is **suppressed** via policy, and the six underlying toggles are **disabled by policy in `specialize`** (applied before OOBE):
  - Diagnostics data (`AllowTelemetry=0`)
  - Tailored experiences (`DisableTailoredExperiencesWithDiagnosticData=1`)
  - Advertising ID (disabled + enforced by policy)
  - Input personalization / online speech (`AllowInputPersonalization=0`)
  - Location (`DisableWindowsLocationProvider=1`, `DisableLocation=1`)
  - Find My Device (`AllowFindMyDevice=0`)
- Local-account **Security Questions disabled** (`NoLocalPasswordResetQuestions=1`).
