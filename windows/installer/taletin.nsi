Unicode true
SetCompressor lzma
RequestExecutionLevel admin
ManifestDPIAware true
AllowSkipFiles off

!include "x64.nsh"
!include "Sections.nsh"
!define UninstallKey "Software\Microsoft\Windows\CurrentVersion\Uninstall\{F4DFDF39-39BC-4765-8C22-54256919B96C}_is1"
!define Uninstaller "Uninstall TaleTin.exe"
!define DesktopIcon "TaleTin-desktop.ico"

Var Upgrade
Var UpgradeUserInstall

Name "TaleTin"
OutFile "${OutputFile}"
Icon "${AppIcon}"
UninstallIcon "${AppIcon}"
VIProductVersion "${FileVersion}"
VIAddVersionKey /LANG=2052 "ProductName" "TaleTin"
VIAddVersionKey /LANG=2052 "FileDescription" "TaleTin 安装程序"
VIAddVersionKey /LANG=2052 "CompanyName" "TaleTin"
VIAddVersionKey /LANG=2052 "LegalCopyright" "TaleTin"
VIAddVersionKey /LANG=2052 "ProductVersion" "${AppVersion}"
VIAddVersionKey /LANG=2052 "FileVersion" "${FileVersion}"

; Use built-in pages for the installation directory and optional shortcut.
Page directory DirectoryPre
Page components
Page instfiles
UninstPage uninstConfirm
UninstPage instfiles
LoadLanguageFile "${NSISDIR}\Contrib\Language files\SimpChinese.nlf"

!ifdef SignHook
!include "${SignHook}"
!endif

Function un.onInit
    SetRegView 64
    SetShellVarContext all
FunctionEnd

!macro CheckExistingFile RelativePath
    StrCpy $0 "$INSTDIR\${RelativePath}"
    ${If} ${FileExists} "$0"
        ; Test the write access used by File, but never truncate an existing file.
        System::Call 'kernel32::CreateFileW(w r0, i 0x40000000, i 1, p 0, i 3, i 0x80, p 0) p .r1 ?e'
        Pop $2
        IntCmp $1 -1 preflightBlocked
        System::Call 'kernel32::CloseHandle(p r1)'
    ${EndIf}
!macroend

Section "安装 TaleTin"
    SectionIn RO
    preflight:
    !include "${PreflightFiles}"
    !insertmacro CheckExistingFile "${DesktopIcon}"
    !insertmacro CheckExistingFile "${Uninstaller}"
    Goto copyFiles

    preflightBlocked:
    MessageBox MB_RETRYCANCEL|MB_ICONEXCLAMATION "安装尚未开始，以下文件无法写入：$\r$\n$0$\r$\n$\r$\n请完全退出 TaleTin，关闭占用该文件的程序，再点「重试」。如果仍无法写入，请检查安装目录的权限。$\r$\nWindows 错误代码：$2" /SD IDCANCEL IDRETRY preflight
    SetErrorLevel 1
    Abort

    copyFiles:
    ClearErrors
    SetOutPath "$INSTDIR"
    File /r "${StageDir}\*"
    SetOutPath "$INSTDIR"
    File /oname=${DesktopIcon} "${AppIcon}"
    WriteUninstaller "$INSTDIR\${Uninstaller}"
    IfErrors filesFailed

    ${If} $UpgradeUserInstall == 1
        ReadRegStr $0 HKCU "${UninstallKey}" "UninstallString"
    ${Else}
        ReadRegStr $0 HKLM "${UninstallKey}" "UninstallString"
    ${EndIf}
    ClearErrors
    WriteRegStr HKLM "${UninstallKey}" "DisplayName" "TaleTin"
    WriteRegStr HKLM "${UninstallKey}" "DisplayVersion" "${AppVersion}"
    WriteRegStr HKLM "${UninstallKey}" "Publisher" "TaleTin"
    WriteRegStr HKLM "${UninstallKey}" "InstallLocation" "$INSTDIR"
    WriteRegStr HKLM "${UninstallKey}" "DisplayIcon" "$INSTDIR\taletin.exe,0"
    WriteRegStr HKLM "${UninstallKey}" "UninstallString" '$\"$INSTDIR\${Uninstaller}$\"'
    WriteRegStr HKLM "${UninstallKey}" "QuietUninstallString" '$\"$INSTDIR\${Uninstaller}$\" /S'
    WriteRegDWORD HKLM "${UninstallKey}" "NoModify" 1
    WriteRegDWORD HKLM "${UninstallKey}" "NoRepair" 1
    IfErrors registrationFailed

    ; Remove the old uninstaller after registering the new one in its place.
    StrCmp $0 '$\"$INSTDIR\unins000.exe$\"' 0 createShortcut
    Delete "$INSTDIR\unins000.exe"
    Delete "$INSTDIR\unins000.dat"

    createShortcut:
    ClearErrors
    SetOutPath "$INSTDIR"
    CreateShortcut "$SMPROGRAMS\TaleTin.lnk" "$INSTDIR\taletin.exe"
    IfErrors shortcutFailed
    ${If} $UpgradeUserInstall == 1
        DeleteRegKey HKCU "${UninstallKey}"
    ${EndIf}
    Goto done

    filesFailed:
    MessageBox MB_OK|MB_ICONSTOP "无法写入安装目录。请关闭正在运行的 TaleTin，并确认有权限写入此目录后重试。" /SD IDOK
    SetErrorLevel 1
    Abort
    registrationFailed:
    MessageBox MB_OK|MB_ICONSTOP "程序文件已复制，但 Windows 拒绝登记卸载记录。" /SD IDOK
    SetErrorLevel 1
    Abort
    shortcutFailed:
    MessageBox MB_OK|MB_ICONSTOP "程序文件已复制，但 Windows 拒绝创建开始菜单快捷方式。" /SD IDOK
    SetErrorLevel 1
    Abort
    done:
SectionEnd

Section /o "创建桌面快捷方式" DesktopShortcutSection
    ClearErrors
    SetOutPath "$INSTDIR"
    CreateShortcut "$COMMONDESKTOP\TaleTin.lnk" "$INSTDIR\taletin.exe" "" "$INSTDIR\${DesktopIcon}" 0
    IfErrors shortcutFailed
    WriteRegDWORD HKLM "${UninstallKey}" "DesktopShortcut" 1
    IfErrors shortcutFailed
    Goto done

    shortcutFailed:
    MessageBox MB_OK|MB_ICONEXCLAMATION "TaleTin 已安装，但未能完成桌面快捷方式设置。" /SD IDOK
    ClearErrors
    done:
SectionEnd

Function .onInit
    ${IfNot} ${RunningX64}
        MessageBox MB_OK|MB_ICONSTOP "此安装包需要能够运行 x64 应用的 Windows。" /SD IDOK
        SetErrorLevel 1
        Abort
    ${EndIf}
    SetRegView 64
    SetShellVarContext all
    StrCpy $Upgrade 0
    StrCpy $UpgradeUserInstall 0

    ; Treat only a registered location that still contains TaleTin as installed.
    ReadRegStr $0 HKLM "${UninstallKey}" "InstallLocation"
    ${If} $0 != ""
    ${AndIf} ${FileExists} "$0\taletin.exe"
        StrCpy $Upgrade 1
    ${Else}
        ReadRegStr $0 HKCU "${UninstallKey}" "InstallLocation"
        ${If} $0 != ""
        ${AndIf} ${FileExists} "$0\taletin.exe"
            StrCpy $Upgrade 1
            StrCpy $UpgradeUserInstall 1
        ${EndIf}
    ${EndIf}

    ${If} $Upgrade == 1
        GetFullPathName $INSTDIR "$0"
        MessageBox MB_OKCANCEL|MB_ICONQUESTION "已检测到 TaleTin 安装在：$\r$\n$INSTDIR$\r$\n$\r$\n点击「确定」覆盖安装。" /SD IDOK IDOK upgradeConfirmed
        SetErrorLevel 2
        Abort
        upgradeConfirmed:
        ${If} $UpgradeUserInstall == 1
            ReadRegDWORD $0 HKCU "${UninstallKey}" "DesktopShortcut"
        ${Else}
            ReadRegDWORD $0 HKLM "${UninstallKey}" "DesktopShortcut"
        ${EndIf}
        ${If} $0 == 1
        ${AndIf} ${FileExists} "$COMMONDESKTOP\TaleTin.lnk"
            !insertmacro SelectSection ${DesktopShortcutSection}
        ${EndIf}
    ${ElseIf} $INSTDIR == ""
        StrCpy $INSTDIR "$PROGRAMFILES64\TaleTin"
    ${EndIf}
FunctionEnd

Function DirectoryPre
    ${If} $Upgrade == 1
        Abort
    ${EndIf}
FunctionEnd

Section "Uninstall"
    ; Remove just the shipped files, leaving any books or other user files.
    !include "${UninstallFiles}"
    Delete "$INSTDIR\${DesktopIcon}"
    Delete "$INSTDIR\${Uninstaller}"
    RMDir "$INSTDIR"
    ReadRegStr $0 HKLM "${UninstallKey}" "InstallLocation"
    StrCmp $0 $INSTDIR 0 done
    Delete "$SMPROGRAMS\TaleTin.lnk"
    ReadRegDWORD $0 HKLM "${UninstallKey}" "DesktopShortcut"
    StrCmp $0 1 0 +2
    Delete "$COMMONDESKTOP\TaleTin.lnk"
    DeleteRegKey HKLM "${UninstallKey}"
    done:
SectionEnd
