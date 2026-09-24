
# ISO Builder

Create a ready-to-install Windows ISO with LTSC-clean automatically.

## Requirements

- Windows 11 Enterprise LTSC 2024 x64, with `install.wim` at index 1.
- Windows PowerShell 5.1 (64-bit), run as Administrator.
- A local NTFS drive with sufficient free space.
- [Microsoft LGPO.exe](https://www.microsoft.com/en-us/download/details.aspx?id=55319).
- [Windows ADK](https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install): Install only Deployment Tools (includes oscdimg.exe).

## Build Your ISO

1. Download and extract the original Windows ISO to a local folder.
2. Download or clone the LTSC-clean repository.
3. Open PowerShell as Administrator in the repository root.
4. Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Installation_ISO_builder.ps1
```

5. Follow the prompts to select your Windows files, LGPO.exe, output location, and administrator password.

The script prepares the image and creates your installation ISO automatically.

**Important:** Your ISO contains your administrator password. Keep it private and do not share it.
