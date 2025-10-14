# Security notes for the Clean & Quiet Baseline

## Purpose

This baseline favors a quiet, predictable workstation with minimal background network activity and telemetry, using only supported Microsoft mechanisms.

## Scope

* Target: Windows 10 Enterprise LTSC 2021 workstations (21H2, EnterpriseS, build 19044+).
* Environment: standalone or simple networks without corporate integration or automatic proxy discovery requirements.
* Philosophy: official tools only (Policies/Registry, DISM Features & Capabilities, Scheduled Tasks, RunOnce), deterministic and idempotent behavior, no reboots inside SetupComplete.

## Intentional trade-offs

* SmartScreen is disabled for Explorer and Edge.
* Windows Defender is minimized using supported preferences. Cloud protection and sample submissions are off.
* Delivery Optimization is set to mode 0 (HTTP-only, no peer-to-peer).
* Windows Update runs in notify-only mode. No drivers, no preview builds, no other Microsoft products, no OS upgrade offers.
* WPAD is disabled via policies on WinINET and WinHTTP. The WinHTTP Auto-Proxy service is not forcibly disabled.
* Component cleanup uses `/ResetBase` to seal the image, which removes rollback for the currently installed updates.

## Not a fit if you require

* SmartScreen prompts or Defender cloud protection by policy.
* Peer-to-peer Delivery Optimization or Connected Cache scenarios.
* Automatic proxy discovery (WPAD) for WinHTTP clients.
* Guaranteed rollback of currently installed updates.
* Enterprise hardening stacks enabled by default (for example, MDE onboarding, WDAC, AppLocker, BitLocker enforcement, LAPS, or domain-based baselines).

## Recommendations and compensating controls

* Use least-privilege accounts for daily work; avoid local admin where possible.
* Patch cadence: manually apply quality updates on a predictable schedule after validating on a test VM or sacrificial machine.
* If a proxy is introduced later, configure it explicitly: `netsh winhttp set proxy` or a supported policy. With WPAD disabled, auto-discovery will not occur.
* Consider periodic offline AV scans or a trusted third-party endpoint if organizational policy requires it.
* If you later re-enable Defender’s real-time features, consider testing Attack Surface Reduction (ASR) rules on a VM first.
* Monitor the post-install verification checklist in **README.md → Post-install quick check**, and keep it up to date for reproducibility.

## Operational notes

* The baseline is designed to be idempotent. Re-running the post-install script should not introduce drift.
* Stage B rollback (Winlogon cleanup, RunOnce removal, bootstrap disable) runs only after Stage A succeeds, reducing lockout risk if account provisioning fails.
* The script returns a non-zero code if steps failed; always review `%WINDIR%\Panther\SetupComplete.log`.
* Any deviation from the principles above may affect predictability. Document exceptions in your fork and update `DECISIONS.md`.

## Reporting and contributions

* For questions or improvements, open a GitHub issue or pull request in the repository.
* Do not post sensitive information or logs containing personal data in public issues.
* Keep contributions aligned with the project principles: official tools only, deterministic and idempotent behavior, and no reboots inside SetupComplete.

## License notice

* This project is provided under the MIT License, without warranty. Review and adapt the baseline to your risk profile before production use.

### Дополнительные уточнения

* UAC остаётся включён (не понижается).
* Никаких перезагрузок из SetupComplete; ребут планируется через RunOnce при RC 3010/1641 или флаге `ALWAYS_REBOOT_AFTER_FIRST_LOGON=1`.

## Compatibility controls & safety

**По умолчанию:** используется `STRICT_DISPLAYVERSION=0` (best‑effort). Для продакшн‑окружений рекомендуем `STRICT_DISPLAYVERSION=1`.

`STRICT_DISPLAYVERSION=0` позволяет продолжить выполнение на близких версиях Windows.
Это сознательный компромисс переносимости. Риски: часть шагов может не примениться или примениться иначе
из‑за изменений в компонентной базе. Для продакшн‑сценариев в неконтролируемых окружениях рекомендуем
включать `STRICT_DISPLAYVERSION=1` и фиксировать `REQUIRED_*` под целевой выпуск.

## Logs

Скрипт пишет техжурнал в `%WINDIR%\Panther\SetupComplete.log`. Записи содержат только технические сообщения
и метки времени. Персональные данные не логируются умышленно. Срок хранения определяйте политикой окружения;
при необходимости удаляйте журнал после успешной валидации установки.

**Timestamping & DISM logs.** Timestamps are **ISO-8601**, generated via **PowerShell** (`Get-Date -Format o`). All DISM calls write to a centralized log: `%WINDIR%\Logs\DISM\SetupComplete-DISM.log` with `/LogLevel:4`. Return codes are handled uniformly: `0` = success; `3010/1641` = success, reboot required.

Installer reboot suppression is enforced: **MSI** use `REBOOT=ReallySuppress /norestart`, **EXE** are invoked with `/norestart` to avoid any reboot inside SetupComplete.

**Unattend hygiene.** After SetupComplete finishes, remove `%WINDIR%\Panther\Unattend.xml` and `%WINDIR%\Panther\UnattendGC\*.xml`.

## Update (2025-09-19) — Privacy & Account Hardening
- **Deployment precondition:** `PreOOBE.cmd` is **embedded** into `install.wim` at `Windows\Setup\Scripts\`; unattend calls it in `specialize`.

Applied at **specialize** (SYSTEM) using `Microsoft-Windows-Deployment/RunSynchronous`:

- `HKLM\SOFTWARE\Policies\Microsoft\Windows\System\NoLocalPasswordResetQuestions=1`
- `HKLM\SOFTWARE\Policies\Microsoft\Windows\OOBE\DisablePrivacyExperience=1`
- `HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection\AllowTelemetry=0`
- `HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent\DisableTailoredExperiencesWithDiagnosticData=1`
- `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo\Enabled=0`
- `HKLM\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo\DisabledByGroupPolicy=1`
- `HKLM\SOFTWARE\Policies\Microsoft\InputPersonalization\AllowInputPersonalization=0`
- `HKLM\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors\DisableWindowsLocationProvider=1`
- `HKLM\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors\DisableLocation=1`
- `HKLM\SOFTWARE\Policies\Microsoft\FindMyDevice\AllowFindMyDevice=0`

Effect: Privacy wizard suppressed; six corresponding toggles enforced to OFF; local-account security questions disabled.

- Applied at specialize via external `PreOOBE.cmd` (invoked from unattend).

## Временное хранение пароля в Winlogon при автологоне

Для `AutoAdminLogon` требуется `HKLM\...\Winlogon\DefaultPassword (REG_SZ)`.
Это пароль в открытом виде и он хранится **временно** — ровно на фазу «взвод → первый вход под bootstrap».

Меры снижения риска:
- Пароль `bootstrap` — временный; после первого входа `CreatePrimaryAdmin.ps1` удаляет `DefaultPassword` и отключает автологон (`AutoAdminLogon=0`, `ForceAutoLogon=0`).
- Логи не содержат паролей (логируются только факты и длина/классы при генерации).
- Длительность хранения — только до первого входа `bootstrap`.

## Политики входа: временное ослабление и возврат

На фазе взвода:
- `DisableCAD=1`, `DevicePasswordLessBuildVersion=0`, очистка `LegalNotice*`, `DontDisplayLastUserName=0`, `IgnoreShiftOverride=0 (REG_SZ, без промежуточного "1")`.

На откате:
- `DisableCAD=0`, `DevicePasswordLessBuildVersion=2`, `IgnoreShiftOverride=0 (REG_SZ)`.

Гарантия возврата обеспечивается идемпотентной логикой `CreatePrimaryAdmin.ps1`.