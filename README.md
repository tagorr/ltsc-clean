# Windows 10 LTSC 2021 - Clean & Quiet Baseline (Official Tools Only)

A lean, predictable Windows 10 LTSC 2021 baseline with minimal background activity and telemetry. Uses official Microsoft mechanisms only (Policies/Registry, DISM Features & Capabilities, Scheduled Tasks, RunOnce). Conservative, no hacks; deterministic and idempotent. Includes `autounattend.xml` and `SetupComplete.cmd`.

## Scope

- Harden Windows 10 LTSC 2021 using **supported policies and servicing** only; no unofficial binaries or hacks.
- Provide deterministic automation via `PreOOBE.cmd`, `SetupComplete.cmd`, and companion PowerShell helpers with **single-pass logging**.
- Expect operators to supply deployment assets (media, `autounattend.xml`) separately; this repo tracks the scripts, decisions, and documentation only.

## Supported SKUs / Requirements

> This baseline is intended for **Windows 10 Enterprise LTSC 2021 (EnterpriseS)** or compatible **Enterprise** SKUs.
> **Rationale:** the diagnostic data level **`AllowTelemetry=0`** ("Security") is supported on Enterprise tiers; on non-Enterprise editions the minimum effective level may be higher and behavior may differ.

* Windows 10 Enterprise LTSC 2021 (21H2, EditionID=EnterpriseS, build 19044+)
* No corporate integration required

## Files in this repo

* `SetupComplete.cmd` - post-install baseline script (post-OOBE hardening)
* `PreOOBE.cmd` - specialize-phase privacy policies and bootstrap trigger
* `BootstrapLocalAdmin.ps1` - temporary admin creation + autologon bootstrapper
* `CreatePrimaryAdmin.ps1` - first-login wizard that finalizes the baseline
* `DECISIONS.md` - design decisions and rationale
* `BACKGROUND.md` - archived notes and history
* `LICENSE` - MIT

> `autounattend.xml` is maintained in a separate, access-controlled repository and is intentionally **not** committed here. Follow `DECISIONS.md` §7 for generation and storage guidance.

## Placement

> **Pre-OOBE delivery:** `PreOOBE.cmd` is **embedded** into the target OS image (`install.wim`) at
> `Windows\Setup\Scripts\PreOOBE.cmd`. Unattend (`specialize` → `RunSynchronous`) calls this path **inside** the deployed OS; it is **not** read from the installation media.

> Privacy/Security policies are applied **before OOBE** via external `PreOOBE.cmd`, invoked from `Autounattend.xml` in pass `specialize` (`Microsoft-Windows-Deployment/RunSynchronous`). The script resides at `%WINDIR%\Setup\Scripts\PreOOBE.cmd` inside the installed OS.

* Put `autounattend.xml` in the root of the installation media.
* Put `SetupComplete.cmd` at:

  ```
  \sources\$OEM$\$$\Setup\Scripts\SetupComplete.cmd
  ```
* Runtime logs:

  1. `%WINDIR%\Panther\PreOOBE.log` — specialize-phase policies and bootstrap status.
  2. `%WINDIR%\Panther\SetupComplete.log` — post-setup baseline run (ISO-8601 timestamps).
  3. `%WINDIR%\Logs\DISM\SetupComplete-DISM.log` — consolidated DISM trace for all servicing actions.

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

- Таймстемпы **ISO-8601**. Движок: **PowerShell** (`Get-Date -Format o`).
- **Централизованный лог DISM**: `/LogPath:%WINDIR%\Logs\DISM\SetupComplete-DISM.log /LogLevel:4`; RC трактуются как `0` success, `3010/1641` success+reboot.
- Подавление ребутов установщиков: **MSI** запускаются с `REBOOT=ReallySuppress /norestart`, **EXE** — с эквивалентным `/norestart`.

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
## Проектные правила PowerShell/CLI

### SCOPE OF APPLICABILITY (critical!)
These rules apply **only** to:
- interactive **Windows PowerShell 5.1** commands (console "Run as administrator");
- project PowerShell scripts (`.ps1`).

These rules do **not** apply to batch scripts (`.cmd/.bat`) such as `SetupComplete.cmd` and `PreOOBE.cmd`. For `.cmd/.bat` use **pure CMD syntax**:
- variables: `%VAR%` (and `!VAR!` when Delayed Expansion is enabled);
- redirection/suppression: `>nul` (STDOUT), `2>nul` (STDERR), both: `>nul 2>&1`;
- control flow: `call :label`, `goto`, `if errorlevel`, `for /f`, etc.

> Note: the "no `>nul/2>nul`" constraint applies **only** to PowerShell context. In `.cmd/.bat` these are valid constructs.

### 0) Общий принцип
- Все команды выдаются **для Windows PowerShell 5.1** (консоль «Запуск от имени администратора»).
- Допускается вызов внешних утилит (`reg.exe`, `schtasks.exe`, `shutdown.exe`), но подавление/редиректы — **только в PowerShell-стиле**.
- **Не** использовать `cmd /c`, если это явно не требуется.

### 1) Переменные и кавычки
- Использовать переменные PowerShell (`$wl`, `$env:COMPUTERNAME`) для путей/аргументов.
- **Одинарные кавычки** `'...'` — по умолчанию (строка «как есть», без подстановки переменных).
- **Двойные кавычки** "..." — только когда нужна подстановка переменных или выражений.

### 2) Пути к реестру
- Для **`reg.exe`** путь указывать в **обычном виде**: `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon` (без `HKLM:\`).
- Для **cmdlet’ов PowerShell** (`New/Set/Remove-ItemProperty`) путь указывать через **провайдер**: `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon`.

### 3) Подавление вывода
- Скрыть обычный вывод (STDOUT / поток 1): `| Out-Null`
- Скрыть ошибки (STDERR / поток 2): `2>$null`
- «Тихий» режим для внешних утилит: дописывать **оба** — `… | Out-Null 2>$null`
- **Запрещено** использовать `>nul` и `2>nul` (это синтаксис CMD, в PowerShell он некорректен).

### 4) Перезагрузка
- По умолчанию использовать: `shutdown.exe /r /t 0`  
  (при необходимости принудительного закрытия приложений — `shutdown.exe /r /t 0 /f`).
- **Не** заменять на `Restart-Computer`, если это явно не оговорено.

### 5) Антипаттерны (запрещено)
- Не смешивать в одном блоке `reg.exe` и PowerShell-cmdlet’ы **без причины**.
- Не указывать пути вида `HKLM:\...` в командах **`reg.exe`**.
- Не использовать «умные» кавычки и нестандартные символы — только обычные ASCII `' " - /`.
- Не давать примеры/ключи из **PowerShell 7** (не совместимы с 5.1).
- In `.cmd/.bat` files, **PowerShell syntax is forbidden** (`$variable`, `| Out-Null`, cmdlets) **unless wrapped** via `powershell.exe ...`.

### Calling PowerShell from CMD scripts (when needed)
**Short one-liner:**
```
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "[DateTime]::Now.ToString('yyyy-MM-dd')"
```
- Inside `-Command "..."`: use **PowerShell syntax** (`$var`, cmdlets).
- Outside (in `.cmd`): use **pure CMD** (`%VAR%`, `if errorlevel`, etc.).
- To avoid quote escaping, prefer alternating quote types as shown, or use `-EncodedCommand`.

**Capture PowerShell output into a CMD variable:**
```
for /f %%G in ('powershell.exe -NoProfile -NonInteractive -Command "[DateTime]::Now.ToString('o')" 2^>nul') do set "TS=%%G"
```

**For anything beyond a single expression, do not inline:**
```
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\Windows\Setup\Scripts\BootstrapLocalAdmin.ps1" -LogPath "%WINDIR%\Panther\PreOOBE.log"
```
> Alternative when quoting is painful: `-EncodedCommand <BASE64-UTF8>`.

### Return codes (short)
- **PowerShell:** after external tools check **`$LASTEXITCODE`** (not `$?`).
- **CMD:** check **`%ERRORLEVEL%`** (`if errorlevel N ...`).
- **Project policy:**
  - `0` — success;
  - `3010` / `1641` — success, reboot required. **Do not reboot inside `SetupComplete.cmd`**; reboot only in a controlled manner after first logon (e.g., via RunOnce).
- For `DISM`/`reg.exe`, log RC; treat `3010` as a deferred reboot, not as an error.

## Playbooks (вставляемые блоки)

### 5) Каноника для Winlogon/автологина (reg.exe из PowerShell)

reg add $wl /v AutoLogonCount      /t REG_DWORD /d 2                       /f | Out-Null 2>$null
reg add $wl /v IgnoreShiftOverride /t REG_SZ    /d 0                       /f | Out-Null 2>$null
```

**Сброс «липкого» последнего пользователя в LogonUI:**

```powershell
$logonUI = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI'
reg delete $logonUI /v LastLoggedOnUser    /f | Out-Null 2>$null
reg delete $logonUI /v LastLoggedOnSAMUser /f | Out-Null 2>$null
```

**Регистрация мастера в RunOnce:**

```powershell
$ro = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
reg add $ro /v CreatePrimaryAdmin /t REG_SZ /d 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SystemRoot%\Setup\Scripts\CreatePrimaryAdmin.ps1"' /f | Out-Null 2>$null
```

**Ребут:**

```powershell
shutdown.exe /r /t 0
```

*(если нужно принудительно закрыть приложения: `shutdown.exe /r /t 0 /f`)*

### 6) Проверки (короткие)

```powershell
reg query 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
```

```powershell
reg query 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
```

```powershell
net user bootstrap
```

### 7) Отладочный режим

Убрать подавление и вывести код возврата:

```powershell
reg add $wl /v AutoAdminLogon /t REG_SZ /d 1 /f
"ExitCode: $LASTEXITCODE"
```

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

## Поток и архитектура установки

Кратко, как должно работать «в бою»:

1. На этапе `specialize/PreOOBE` под **SYSTEM** запускается `BootstrapLocalAdmin.ps1`.
2. Скрипт:
   - создаёт/активирует локальную учётку `bootstrap` и задаёт пароль;
   - снимает стопперы входа: `DisableCAD=1`, `DevicePasswordLessBuildVersion=0`, очищает `LegalNotice*`, ставит `DontDisplayLastUserName=0`, `IgnoreShiftOverride=0 (REG_SZ, без промежуточного "1")`;
   - настраивает **автологон (AutoAdminLogon)** ТОЛЬКО для **консоли**:
     `DefaultUserName=bootstrap`, `DefaultDomainName=<имя_ПК>`, `DefaultPassword=<тот же пароль>`,
     `AutoAdminLogon=1 (REG_SZ)`, `ForceAutoLogon=1 (REG_SZ)`, `AutoLogonCount≥1 (REG_DWORD)`;
   - регистрирует **RunOnce** на `CreatePrimaryAdmin.ps1`.
3. Ребут → **автовход в консоль** под `bootstrap` → автозапуск `CreatePrimaryAdmin.ps1` (мастер).
4. Мастер создаёт *основного локального администратора* (по умолчанию `primaryadmin`) и выполняет **откат**:
   - удаляет `DefaultPassword`/`AutoLogonCount`, ставит `AutoAdminLogon=0`, `ForceAutoLogon=0`, `IgnoreShiftOverride=0`;
   - возвращает политики (`DisableCAD=0`, `DevicePasswordLessBuildVersion=2`);
   - отключает `bootstrap` (`net user bootstrap /active:no`);
   - чистит `RunOnce`; пишет лог в `%WINDIR%\Panther\SetupComplete.log`.

## Hyper-V VMConnect: Basic vs Enhanced (как правильно читать поведение)

- **Basic/Console (обычный режим):** прямой доступ к *консоли* ВМ («как монитор, воткнутый в системный блок»).
  Именно сюда срабатывает `AutoAdminLogon`. В этом режиме **нет общего буфера обмена** (Ctrl+V не работает).
  Пункт меню VMConnect **Буфер обмена → Ввести текст из буфера обмена** просто «печатает» символы в активное окно.

- **Enhanced (расширённый сеанс):** отдельная **RDP-сессия**. Есть общий буфер (Ctrl+C/V), динамический размер и пр.
  Это **не консоль**. Экран входа в Enhanced — нормален, даже если в консоли уже прошёл автологон под `bootstrap`.

Практика теста:
- Хотите увидеть сам факт автолога → оставляйте **Basic** (без галочки «Расширённый сеанс»).
- Нужны Ctrl+C/V и перенос файлов → заходите в **Enhanced** и **входите** в RDP-сессию (например, под `bootstrap`).
- Одновременные сессии: у одного пользователя может существовать консольная и RDP-сессия. Для работы *под тем же пользователем* в Enhanced удобно либо
  1) **закрыть** консольный сеанс `bootstrap` (например, `logoff 1`) и войти им в RDP; либо
  2) **перехватить** открытую консоль в свой RDP: `tscon 1 /dest:RDP-Tcp#<номер_своего_сеанса>`.

## Быстрый старт (ручной прогон на установленной ВМ)

1. Скопируйте в `C:\Windows\Setup\Scripts\`:
   `BootstrapLocalAdmin.ps1`, `CreatePrimaryAdmin.ps1`.
2. Запустите `BootstrapLocalAdmin.ps1` под **SYSTEM** (эмуляция PreOOBE) через Планировщик:
```powershell
$a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File "C:\Windows\Setup\Scripts\BootstrapLocalAdmin.ps1"'
$p = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
Register-ScheduledTask -TaskName 'BootstrapLocalAdmin-Once' -Action $a -Principal $p -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries) | Out-Null
Start-ScheduledTask -TaskName 'BootstrapLocalAdmin-Once'
```

3. Проверьте настройки (срез):

```powershell
$wl='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Get-ItemProperty $wl | Select DefaultUserName,DefaultDomainName,DefaultPassword,AutoAdminLogon,ForceAutoLogon,AutoLogonCount,DontDisplayLastUserName,IgnoreShiftOverride | Format-List
reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\Ngc" /v DevicePasswordLessBuildVersion
reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v DisableCAD
reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce"
```
4. Ребут **из гостя** (Пуск → Перезагрузка).
   В **Basic** попадёте сразу на рабочий стол `bootstrap`; в **Enhanced** появится экран входа — это ожидаемо.
5. Дождитесь автозапуска `CreatePrimaryAdmin.ps1`. По завершении проверьте **откат** (см. чек-лист ниже).

## Чек-лист приёмки после первого входа

- *Основной админ* (по умолчанию `primaryadmin`) создан, активен, в **Administrators**; пароль соответствует политике.
- В реестре **нет** `DefaultPassword` и `AutoLogonCount`; `AutoAdminLogon=0 (REG_SZ)`, `ForceAutoLogon=0 (REG_SZ)`, `IgnoreShiftOverride=0`.
- Политики: `DisableCAD=0`; `DevicePasswordLessBuildVersion=2`.
- `bootstrap` отключён (`net user bootstrap /active:no`).
- В `RunOnce` нет ссылок на `CreatePrimaryAdmin.ps1`.
- Лог `%WINDIR%\Panther\SetupComplete.log` содержит «End A: success» и «End B: success».

## Диагностика (кратко)

**Автологон не сработал** — проверьте:
```powershell
$wl='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Get-ItemProperty $wl | Select DefaultUserName,DefaultDomainName,DefaultPassword,AutoAdminLogon,ForceAutoLogon,AutoLogonCount,DontDisplayLastUserName,IgnoreShiftOverride | Format-List
reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\Ngc" /v DevicePasswordLessBuildVersion
reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v DisableCAD
```

Частые причины:

* `DefaultPassword` пуст/не совпадает; `AutoAdminLogon`/`ForceAutoLogon` **не REG_SZ**;
* `DefaultDomainName` ≠ имя ПК; включены `LegalNotice*` или `DontDisplayLastUserName=1`;
* `DevicePasswordLessBuildVersion=2`, `DisableCAD=0`.

**Видно логон в Enhanced** — это нормально: автологон работает только в **консоль**. В Basic увидите сразу рабочий стол `bootstrap`.