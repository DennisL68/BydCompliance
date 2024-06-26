
<#PSScriptInfo

.VERSION 1.1.0

.GUID 767e666d-2edb-4f2d-83e1-c116be8d45e4

.AUTHOR DennisL68

.COMPANYNAME

.COPYRIGHT

.TAGS

.LICENSEURI

.PROJECTURI https://github.com/DennisL68/BydCompliance

.ICONURI

.RELEASENOTES


#>

#Requires -Module PSWindowsUpdate
#Requires -Module @{ModuleName = 'Pester'; ModuleVersion = '4.10.1'}
#Requires -Module PendingReboot
#Requires -Module SpeculationControl

<#

.DESCRIPTION
 A Pester v4 test for checking BYD corporate compliance that uses a config file for all parameters to check for.

#>

Param()


#TODO Add Power & Sleep detection
#TODO Add Privacy checks
#TODO WiFi Settings?
#TODO Check Tamper settings in 1903 and above
#TODO Smart Screen
#? Do we need to check Windows Defender preferences as well
#TODO Internet security settings

#region functions
function ConvertFrom-IniFile ($file) {

    $ini = @{}

    # Create a default section if none exist in the file.
    $section = "NO_SECTION"
    $ini[$section] = @{}

    switch -regex -file $file {
      "^\[(.+)\]$" {
        $section = $matches[1].Trim()
        $ini[$section] = @{}
      }

      "^\s*([^#].+?)\s*=\s*(.*)" {
        $name,$value = $matches[1..2]

        if (!($name.StartsWith(";"))) {#not a comment
          $ini[$section][$name] = $value.Trim()
        }

      }

    }#end switch

    return $ini

}# end function

function Get-UacLevel {
    $Uac = New-Object psobject |
        select EnableLUA, ConsentPromptBehaviorAdmin, PromptOnSecureDesktop, NotifyLevel, NotifyLevelVal

    $PolicyKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    $Uac.EnableLUA = (Get-ItemProperty $PolicyKey).EnableLUA
    $Uac.ConsentPromptBehaviorAdmin = (Get-ItemProperty $PolicyKey).ConsentPromptBehaviorAdmin
    $Uac.PromptOnSecureDesktop = (Get-ItemProperty $PolicyKey).PromptOnSecureDesktop

    switch -Wildcard ($Uac.psobject.Properties.Value -join ',') {# EnableLUA, ConsentPromptBehaviorAdmin, PromptOnSecureDesktop
        '1,0,0*' {
            $Uac.NotifyLevel = 'Never Notify'
            $Uac.NotifyLevelVal = 0
        }

        '1,5,0*' {
            $Uac.NotifyLevel = 'Notify when app changes computer (no dim)'
            $Uac.NotifyLevelVal = 1
        }

        '1,5,1*' {
            $Uac.NotifyLevel = 'Notify when app changes computer (default)'
            $Uac.NotifyLevelVal = 2
        }

        '1,2,1*' {
            $Uac.NotifyLevel = 'Always Notify'
            $Uac.NotifyLevelVal = 3
        }

        Default {
            $Uac.NotifyLevel = 'Unknown'
            $Uac.NotifyLevelVal = -1
        }

    }# end switch

    return $Uac
}

function Get-FireWallRuleProperty {

    [CmdletBinding()]
    param (
        [Parameter(ValueFromPipeline)]
        $FirewallRule
    )

    process {
        $FireWallPortFilter = $FirewallRule | Get-NetFirewallPortFilter
        $FirewallRule | Select *,
        @{ n = 'Protocol';  e = {$FireWallPortFilter.Protocol} },
        @{ n = 'LocalPort'; e = {$FireWallPortFilter.LocalPort} },
        @{ l = 'RemotePort';e = {$FireWallPortFilter.RemotePort} },
        @{ l = 'RemoteAddress';e = {$FireWallPortFilter.RemoteAddress} },
        @{ l = 'Program';   e = {$FireWallPortFilter.Program} }
    }

}

function Check {# configs of $true, $null, $false and value
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [Alias('If')]
        $Data,

        [Parameter(ParameterSetName = 'compare')]
        $IsCompliantWith,

        [Parameter(ParameterSetName = 'le')]
        $IsLessOrEqualTo,

        [Parameter(ParameterSetName = 'ge')]
        $IsGreaterOrEqualTo
    )

    $Arg2 = $IsCompliantWith + $IsLessOrEqualTo +$IsGreaterOrEqualTo

    if (# Not defined
        [string]::IsNullOrEmpty($Arg2)
    ) {
        Set-ItResult -Skipped -Because 'Test not enabled'
        return
    }

    if (# Not required
        !$Arg2 -and
        $Arg2 -is [bool]
    ) {
        Set-ItResult -Skipped -Because 'Test not required'
        return
    }

    if (# At least
        $PSCmdlet.ParameterSetName -eq 'le' -and
        -not ($ComplianceValue = $IsLessOrEqualTo) -is [bool]
    ) {
        $Data | Should -BeLessOrEqual $ComplianceValue
        return
    }

    if (# At most
        $PSCmdlet.ParameterSetName -eq 'ge' -and
        -not ($ComplianceValue = $IsGreaterOrEqualTo) -is [bool]
    ) {
        $Data | Should -BeGreaterOrEqual $ComplianceValue
        return
    }

    if (# The same
        $PSCmdlet.ParameterSetName -eq 'compare'
    ) {
        $Compliant = $IsCompliantWith

        $Data | Should -Be $Compliant
        return
    }

}
#endregion functions

$IsAdmin = [bool](([System.Security.Principal.WindowsIdentity]::GetCurrent()).groups -match 'S-1-5-32-544')

$Compliance = Get-Content $PSScriptRoot\compliance.json -ErrorAction SilentlyContinue | ConvertFrom-Json

if (Test-Path ~\compliance.json) {
    $Compliance = Get-Content ~\compliance.json | ConvertFrom-Json
}

if (!$Compliance) {
    Write-Error 'The settings file compliance.json is missing. See the GitHub project for more information.'
    return
}

$ComplianceTypes =  $Compliance |
    Get-Member -MemberType Property,NoteProperty |
        select -ExpandProperty Name | where {$_ -ne 'ProjectReference'}

foreach ($ComplianceType in $ComplianceTypes) {# State what compliance is not defined to be checked
    if ([string]::IsNullOrEmpty($Compliance.$ComplianceType.Active)) {

        It "Test of $ComplianceType" {
            Set-ItResult -Skipped -Because 'Test param Active not defined in JSON config'
        }
    }
}

Describe '- Check Windows environment Compliance'  -Tag Environment {

    if ($Compliance.WindowsEoL.Active) {
        Context '- Check Windows version' {

            It 'Should check End of Life' {

                    $WindowsInfo = Get-Item 'HKLM:SOFTWARE\Microsoft\Windows NT\CurrentVersion' | select @{
                            l = 'OsName'
                            e = {$_.GetValue("ProductName")}
                    },
                    @{
                        l = 'BuildNumber'
                        e = {$_.GetValue("CurrentBuildNumber")}
                    },
                    @{
                        l = 'Version'
                        e = {
                            if ( $_.GetValue('ReleaseId') -and !($_.GetValue('DisplayVersion')) ) {$_.GetValue('ReleaseID')}
                            if ( $_.GetValue('DisplayVersion') ) {$_.GetValue('DisplayVersion')}
                            if ( ! ($_.GetValue('ReleaseId') -or $_.GetValue('DisplayVersion')) ) {$_.GetValue('CurrentVersion')}
                        }
                    }

                    $Windows = ($WindowsInfo.OSName -replace "(\s\S+){1}$") + #Remove last word
                        ' ' +
                        $WindowsInfo.Version
                    write-host -ForegroundColor Yellow '      ' $Windows

                    $Today = Get-Date

                    if ($Compliance.WindowsEoL.Settings.Extended) {# Extended End date exists, use that
                        $EndDate = [datetime]($Compliance.WindowsEoL.EndDates.$Windows[1..2] | Measure-Object -Maximum).Maximum
                    } else {# Use normal End Date
                        $EndDate = [datetime]$Compliance.WindowsEoL.EndDates.$Windows[1]
                    }

                    Check -If ($Today -lt $EndDate) -IsCompliantWith $Compliance.WindowsEoL.Active
            }

        }
    }


    if ($Compliance.WindowsLicense.Active) {
        Context '- Check license information'{

            It 'Should check license status' {
                $License = Get-CimInstance SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL" |
                where Name -like 'Windows*' | select Description, LicenseStatus

                Check -If ($License.LicenseStatus -eq '1') -IsCompliantWith $Compliance.WindowsLicense.Settings
            }
        }
    }
}

Describe '- Check Security Compliance' -Tag Security {

    if ($Compliance.WindowsUpdate.Active) {
        Context '- Get Windows Update Status' {

            $WULastResults = Get-WULastResults 3>$null #Hide default warning message
            $Today = Get-Date

            It 'Should check for Windows update age' {
                Check -If (
                    [int]($Today - $WULastResults.LastInstallationSuccessDate).TotalDays
                ) -IsLessOrEqualTo $Compliance.WindowsUpdate.Settings.LastInstallMaxAge
            }

            It 'Should check for pending reboot' {
                if (($PSVersionTable.PSVersion | select Major,Minor) -like ([version]'5.1' | select Major,Minor)) {#only works with PoSH 5.1
                    Check -If (
                        (Test-PendingReboot -SkipConfigurationManagerClientCheck).IsRebootPending
                    ) -IsCompliantWith $Compliance.WindowsUpdate.Settings.HavePendingReboot
                }
                else {
                    Set-ItResult -Skipped -Because 'Test requires PoSH 5.1'
                }
            }
        }#end context Windows Update
    }

    if ($Compliance.UserAccount.Active) {

        Context '- Check local accounts' {

            #Get built in admin account
            $BuiltinAdmin = Get-LocalUser | where SID -like 'S-1-5-21-*-500'

            #Get current account
            $MyAccount = whoami /user /fo CSV | ConvertFrom-Csv

            #Get Local Security Policy
            if ($IsAdmin){
                $MyAppPath = [environment]::getfolderpath('ApplicationData')
                secedit /areas securitypolicy /export /cfg $MyAppPath\sec_cfg.ini
                $SecCfg = ConvertFrom-IniFile $MyAppPath\sec_cfg.ini
                remove-item $MyAppPath\sec_cfg.ini -Force
            }

            It ('Should check running as Builtin Admin') {
                Check -If (
                    $BuiltinAdmin.SID -ne $MyAccount.SID
                ) -IsCompliantWith $Compliance.UserAccount.Settings.IsNotBuiltInAdmin
            }

            It ('Should check Builtin Admin account being enabled') {
                Check -If (
                    -not $BuiltinAdmin.Enabled
                ) -IsCompliantWith $Compliance.UserAccount.Settings.BuiltInAdminDisabled
            }

            It ('Should check using blank passwords') {
                Add-Type -AssemblyName System.DirectoryServices.AccountManagement
                $PrincipalObj = New-Object System.DirectoryServices.AccountManagement.PrincipalContext('machine',$Env:COMPUTERNAME)

                Check -If (
                    -not $PrincipalObj.ValidateCredentials($MyAccount.'User Name','')
                ) -IsCompliantWith $Compliance.UserAccount.Settings.NotUsingBlankPassword
            }

            It ('Should check using Auto Logon') {
                $AutoLogon = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\').AutoAdminLogon

                Check -If (-not $AutoLogon -eq 1) -IsCompliantWith $Compliance.UserAccount.Settings.AutoLogonDisabled
            }

            It ('Should check storing AutoLogon password') {
                $AutoLogonPwd = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\').DefaultPassword

                Check -If (
                    [string]::IsNullOrEmpty($AutoLogonPwd)
                ) -IsCompliantWith $Compliance.UserAccount.Settings.AutoLogonDisabled
            }

            if ($IsAdmin){
                It ('Should check complex password requirement') {
                    Check -If (
                        $SecCfg.'System Access'.PasswordComplexity -eq 1
                    ) -IsCompliantWith $Compliance.UserAccount.Settings.RequireComplexPassword
                }
            } else {
                It 'Should check complex password requirement' {
                    $IsAdmin | Should -Be $true -Because 'Check requires admin privileges'
                }
            }


            if ($IsAdmin) {
                It "Should check password length policy setting" {
                    Check -If (
                        [int]($SecCfg.'System Access'.MinimumPasswordLength)
                    ) -IsGreaterOrEqualTo $Compliance.UserAccount.Settings.MinimumPasswordLength
                }
            }

            if (!$IsAdmin){# skip password check
                It 'Should check password length policy setting' {
                    $IsAdmin | Should -Be $true -Because 'Check requires admin privileges'
                }
            }

            It ('Should check lock out screen setting') {#! Add Power & Sleep detection
                [bool][int]$ScreenSaveActive = (Get-ItemProperty 'HKCU:\Control Panel\Desktop').ScreenSaveActive
                [bool][int]$ScreenSaverIsSecure = (Get-ItemProperty 'HKCU:\Control Panel\Desktop').ScreenSaverIsSecure

                if ($IsAdmin){
                    $InactivityLimit = $SecCfg.'Registry Values'.'MACHINE\Software\Microsoft\Windows\CurrentVersion\Policies\System\InactivityTimeoutSecs'
                    if ($InactivityLimit){#exists
                        $InactivityLimit = $InactivityLimit.split(',')[-1] #Only keep last part
                    }

                    Check -If (
                        $ScreenSaveActive -and $ScreenSaverIsSecure -or
                        $InactivityLimit -gt 0
                    ) -IsCompliantWith $Compliance.UserAccount.Settings.LockOutScreenOn
                }

                if (!$IsAdmin -and !($ScreenSaveActive -and $ScreenSaverIsSecure)) {
                    $IsAdmin | Should -Be $true -Because 'Check requires admin privileges'
                }
            }
        }#end context Accounts
    }

    if ($Compliance.Machine.Active) {
        Context '- Get machine settings'{

            $TpmDevice = Get-PnpDevice -Class SecurityDevices -ErrorAction SilentlyContinue | where Service -eq 'TPM'
            if ($TpmDevice){#make sure we have a TPM before getting version
                $TpmVersion = [version]$TpmDevice.FriendlyName.split(' ')[-1]
            }

            $BitLockerMod = Get-Module BitLocker -ListAvailable

            if ($IsAdmin -and $BitLockerMod) {
                $OsBitLockerVolume = Get-BitLockerVolume | where VolumeType -eq OperatingSystem
            }

            It ('Should check for an EFI partition') {
                if ($IsAdmin) {
                    #$EfiPart = Get-Disk | where IsBoot | Get-Partition | where GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
                    #! Get-Disk doesn't work with Dynamic disks

                    $EfiPart = bcdedit /enum BOOTMGR | select -Index 5 | where {$_ -like '*.efi'}

                    Check -If (
                        -not [string]::IsNullOrEmpty($EfiPart)
                    ) -IsCompliantWith $Compliance.Machine.Settings.EFIPartitionActive
                }
                if (!$IsAdmin) {
                    Set-ItResult -Skipped -Because 'Check requires admin privileges'
                }
            }

            It ('Should check for UEFI firmware Secure Boot') {
                If ($IsAdmin) {
                    Check -If Confirm-SecureBootUEFI -IsCompliantWith $Compliance.Machine.Settings.UEFISecureBoot
                }
                if (!$IsAdmin) {
                    Set-ItResult -Skipped -Because 'Check requires admin privileges'
                }
            }

            It 'Should check for TPM' {
                Check -If $TpmDevice.Present -IsCompliantWith $Compliance.Machine.Settings.HasTPM
            }

            It 'Should check TPM version' {
                if ($TpmDevice.Present) {
                    Check -If $TpmVersion -IsGreaterOrEqualTo ([version]$Compliance.Machine.Settings.LowestTPMVersion)
                }
                if (!$TpmDevice.Present) {
                    Set-ItResult -Skipped -Because 'Check requires TPM device'
                }
            }

            It 'Should check TPM status' {
                if ($TpmDevice.Present) {
                    Check -If ($TpmDevice.Status -eq 'OK') -IsCompliantWith $Compliance.Machine.Settings.TPMStatusIsOk
                }
                if (!$TpmDevice.Present) {
                    Set-ItResult -Skipped -Because 'Check requires TPM device'
                }
            }

            It 'Should check Bitlocker Feature installation status' {
                Check -If ($BitLockerMod.Name -eq 'BitLocker') -IsCompliantWith $Compliance.Machine.Settings.BitLockerInstalled
            }

            It 'Should check BitLocker activatation for OS Volume' {
                if ($IsAdmin) {
                    Check -If (
                        $OsBitLockerVolume.ProtectionStatus -eq 'On' -and
                      $OsBitLockerVolume.KeyProtector.KeyProtectorType -contains 'TPM'
                    ) -IsCompliantWith $Compliance.Machine.Settings.BitLockerOnOSVolume
                }
                if (!$IsAdmin) {
                    $BootDrive = (Get-CimInstance Win32_Volume | where BootVolume).DriveLetter
                    $OsBitLockerProtection = (New-Object -ComObject Shell.Application).NameSpace($BootDrive).Self.ExtendedProperty('System.Volume.BitLockerProtection')

                    Check -If (
                        @(1, 3, 5) -contains $OsBitLockerProtection
                    ) -IsCompliantWith $Compliance.Machine.Settings.BitLockerOnOSVolume
                }
            }

            It 'Should check BitLocker activatation for Data Volume' {
                Set-ItResult -Skipped -Because 'Test not implemented yet'
                # | Should -Be $Compliance.Machine.Settings.BitLockerOnDataVolumes
            }

            It 'Should check BitLocker PIN' {
                if (
                    $IsAdmin -and
                    $OsBitLockerVolume.ProtectionStatus -eq 'On'
                ) {
                    Check -If (
                        $OsBitLockerVolume.KeyProtector.KeyProtectorType -contains 'TpmPin'
                     ) -IsCompliantWith $Compliance.Machine.Settings.BitLockerPinEnabled
                }
            }

            It 'Should check UAC level' {
                $Uac = Get-UacLevel

                Check -If $Uac.NotifyLevelVal -IsCompliantWith $Compliance.Machine.Settings.LowestUACLevel
            }

            It 'Should check actions for Spectre/Meltdown (https://support.microsoft.com/help/4074629)' {
                $Speculation = Get-SpeculationControlSettings 6>&1 #Redirect info stream to Success stream
                $SpecMessage = $Speculation.MessageData.Message

                Check -If (
                    -not $SpecMessage -Contains 'Suggested actions'
                ) -IsCompliantWith $Compliance.Machine.Settings.SpectreMeltdownIsHandled
            }

            <#
            It 'Should have CPU features' { #* This might come in handy at some point
                & $Env:Temp\Coreinfo64.exe -accepteula -f
                Get-CimInstance CIM_Processor | Select -Property ProcessorId
            }
            #>

        }#end context Machine
    }

    if ($Compliance.ExploitProtection.Active) {
        Context '- Get Exploit Protection' {

            $ExploitProt = Get-ProcessMitigation -System

            It 'Should check Control Flow Guard (CFG)'{
                Check -If (
                    $ExploitProt.CFG.Enable -eq 'NOTSET' -or  $ExploitProt.CFG.Enable -eq 'Enable' -and
                    $ExploitProt.CFG.SuppressExports -eq 'NOTSET' -or  $ExploitProt.CFG.SuppressExports -eq 'Enable' -and
                    $ExploitProt.CFG.StrictControlFlowGuard -eq 'NOTSET' -or  $ExploitProt.CFG.StrictControlFlowGuard -eq 'Enable'
                ) -IsCompliantWith $Compliance.ExploitProtection.Settings.ControlFlowGuardIsActive
            }

            It 'Should check Data Excution Prevention (DEP)' {
                Check -If (
                    $ExploitProt.DEP.Enable -eq 'NOTSET' -or  $ExploitProt.DEP.Enable -eq 'Enable' -and
                    $ExploitProt.DEP.EmulateAtlThunks -eq 'NOTSET' -or  $ExploitProt.DEP.EmulateAtlThunks -eq 'Enable'
                ) -IsCompliantWith $Compliance.ExploitProtection.Settings.DataExcutionPreventionIsActive
            }

            It 'Should check Force Randomization for Images (Mandatory ASLR)' {
                Check -If (
                    $ExploitProt.ASLR.ForceRelocateImages -eq 'NOTSET' -or
                    $ExploitProt.ASLR.ForceRelocateImages -eq 'ON' -or
                    $ExploitProt.ASLR.ForceRelocateImages -eq 'OFF'
                ) -IsCompliantWith $Compliance.ExploitProtection.Settings.ForceImageRandomizationIsActive
            }

            It 'Should check Randomize memory allocations (Bottom-up ASLR)' {
                Check -If (
                    $ExploitProt.ASLR.BottomUp -eq 'NOTSET' -or
                    $ExploitProt.ASLR.BottomUp -eq 'Enable'
                ) -IsCompliantWith $Compliance.ExploitProtection.Settings.BottumUpASLRIsNotOff
            }

            It 'Should check High-Entropy ASLR' {
                Check -If (
                    $ExploitProt.ASLR.HighEntropy -eq 'NOTSET' -or
                    $ExploitProt.ASLR.HighEntropy -eq 'Enable'
                ) -IsCompliantWith $Compliance.ExploitProtection.Settings.HighEntropyASLRIsActive
            }

            It 'Should check Exception Chains (SEHOP)' {
                Check -If (
                    $ExploitProt.SEHOP.Enable -eq 'NOTSET' -or  $ExploitProt.SEHOP.Enable -eq 'Enable' -and
                    $ExploitProt.SEHOP.TelemetryOnly -eq 'NOTSET' -or  $ExploitProt.SEHOP.TelemetryOnly -eq 'Enable'
                ) -IsCompliantWith $Compliance.ExploitProtection.Settings.ExceptionChainsSEHOPIsActive
            }

            It 'Should check Validate Heap Integrity' {
                Check -If (
                    $ExploitProt.Heap.TerminateOnError -eq 'NOTSET' -or
                    $ExploitProt.Heap.TerminateOnError -eq 'Enable'
                ) -IsCompliantWith $Compliance.ExploitProtection.Settings.ValidateHeapIntegrityIsActive
            }
        }#end context exploit
    }

    if ($Compliance.WindowsDefender.Active) {
        Context '- Get Windows Defender status' {

            $AntiVirusProduct = Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntivirusProduct

            [boolean]$WindowsDefenderIsRunning = (Get-Service WinDefend).Status -eq 'Running'

            It 'Should have Windows Defender running' {# as built-in PowerShell only handles Windows Defender
                $WindowsDefenderIsRunning | Should -BeTrue # Should compare with ProductState but that lacks docs
            }

            if ($WindowsDefenderIsRunning) {
                $MpStatus = Get-MpComputerStatus
            }

            It 'Should check AntiMalware status' {
                if ($WindowsDefenderIsRunning) {
                    Check -If $MpStatus.AMServiceEnabled `
                        -IsCompliantWith $Compliance.WindowsDefender.Settings.AntiMalwareIsActive
                }
                if (!$WindowsDefenderIsRunning) {
                    Set-ItResult -Skipped -Because 'Windows Defender is not running'
                }
            }

            It 'Should check AntiSpyware status' {
                if ($WindowsDefenderIsRunning) {
                    Check -If $MpStatus.AntispywareEnabled `
                        -IsCompliantWith $Compliance.WindowsDefender.Settings.AntiSpywareIsActive
                }
                if (!$WindowsDefenderIsRunning) {
                    Set-ItResult -Skipped -Because 'Windows Defender is not running'
                }
            }

            It 'Should check current AntiSpyware signature age' {
                if ($WindowsDefenderIsRunning) {
                    Check -If $MpStatus.AntispywareSignatureAge `
                        -IsLessOrEqualTo $Compliance.WindowsDefender.Settings.AntiSpywareSignatureMaxAge
                }
                if (!$WindowsDefenderIsRunning) {
                    Set-ItResult -Skipped -Because 'Windows Defender is not running'
                }
            }

            It 'Should check AntiVirus status' {
                if ($WindowsDefenderIsRunning) {
                    Check -If $MpStatus.AntivirusEnabled `
                        -IsCompliantWith $Compliance.WindowsDefender.Settings.AntiVirusIsActive
                }
                if (!$WindowsDefenderIsRunning) {
                    Set-ItResult -Skipped -Because 'Windows Defender is not running'
                }
            }

            It 'Shoud check current AntiVirusSignature age' {
                if ($WindowsDefenderIsRunning) {
                    Check -If $MpStatus.AntivirusSignatureAge `
                        -IsLessOrEqualTo $Compliance.WindowsDefender.Settings.AntiVirusSignatureMaxAge
                }
                if (!$WindowsDefenderIsRunning) {
                    Set-ItResult -Skipped -Because 'Windows Defender is not running'
                }
            }

            It 'Should check Behavior monitoring status' {
                if ($WindowsDefenderIsRunning) {
                    Check -If $MpStatus.BehaviorMonitorEnabled `
                        -IsCompliantWith $Compliance.WindowsDefender.Settings.BehaviorMonitoringIsActive
                }
                if (!$WindowsDefenderIsRunning) {
                    Set-ItResult -Skipped -Because 'Windows Defender is not running'
                }
            }

            It 'Should check fully scanned timeframe' {
                if ($WindowsDefenderIsRunning) {
                    Check -If $MpStatus.FullScanAge `
                    -IsLessOrEqualTo $Compliance.WindowsDefender.Settings.LastFullScanMaxAge
                }
                if (!$WindowsDefenderIsRunning) {
                    Set-ItResult -Skipped -Because 'Windows Defender is not running'
                }
            }

            It 'Should check quicked scanned timeframe' {
                if ($WindowsDefenderIsRunning) {
                    Check -If $MpStatus.QuickScanAge `
                        -IsLessOrEqualTo $Compliance.WindowsDefender.Settings.LastQuickScanMaxAge
                }
                if (!$WindowsDefenderIsRunning) {
                    Set-ItResult -Skipped -Because 'Windows Defender is not running'
                }
            }

            It 'Should check Realtime Protection status' {
                if ($WindowsDefenderIsRunning) {
                    Check -If $MpStatus.RealTimeProtectionEnabled `
                        -IsCompliantWith $Compliance.WindowsDefender.Settings.RealTimeProtectionIsActive
                }
                if (!$WindowsDefenderIsRunning) {
                    Set-ItResult -Skipped -Because 'Windows Defender is not running'
                }
            }

            It 'Should check Tamper Protection status' {
                if ($WindowsDefenderIsRunning) {
                    Check -If $MpStatus.IsTamperProtected `
                        -IsCompliantWith $Compliance.WindowsDefender.Settings.TamperProtectionIsActive
                }
                if (!$WindowsDefenderIsRunning) {
                    Set-ItResult -Skipped -Because 'Windows Defender is not running'
                }
            }
        }# end context Windows Defender
    }

    if ($Compliance.Firewall.Active) {
        Context '- Get Firewall Status' {

            #TODO $Rules=(New-object -ComObject HNetCfg.FWPolicy2).rules to replace Get-NetFirewallRule

            $MpsSvc = Get-Service -Name MpsSvc
            $FirewallProfile = Get-NetFirewallProfile
            if ($IsAdmin){
                $FirewallRule = Get-NetFirewallRule | where {
                    $_.Enabled -eq $true -and
                    $_.Direction -eq 'Inbound'
                } | Get-FireWallRuleProperty
            }
            if (!$IsAdmin) {
                $FirewallRule = Get-NetFirewallRule | where {
                    $_.Enabled -eq $true -and
                    $_.Direction -eq 'Inbound'
                }
            }


            It 'Should check FireWall enabled status' {
                Check -If (
                    $MpsSvc.StartType -eq 'Automatic'
                ) -IsCompliantWith $Compliance.FireWall.Settings.FireWallIsEnabled
            }

            It 'Should check Firewall running status' {
                Check -If (
                    $MpsSvc.Status -eq 'Running'
                ) -IsCompliantWith $Compliance.FireWall.Settings.FireWallIsRunning
            }

            It 'Should check Firewall status for Private networks' {
                Check -If (
                    ($FirewallProfile | where Name -like 'Private').Enabled
                ) -IsCompliantWith $Compliance.FireWall.Settings.FireWallIsOnForPrivate
            }

            It 'Should check Firewall rule existence in Private networks' {
                Check -If (
                    ($FirewallRule | where Profile -like 'Private').Count -ge 1
                ) -IsCompliantWith $Compliance.FireWall.Settings.FireWallRulesExistsForPrivate

            }


            It 'Should check for "allow all" rules for Private networks' {
                if ($IsAdmin) {
                    Check -If ([bool](
                        ($FirewallRule | where {
                            $_.Profile -eq 'Private' -and
                            $_.Action -eq 'Allow' -and
                            (
                                $_.Program -eq 'Any' -or
                                $_.LocalPort -eq 'Any'
                            )
                        }) -eq $null)
                    ) -IsCompliantWith $Compliance.FireWall.Settings.NoAllowAllForPrivate
                }
                if (!$IsAdmin) {
                    Set-ItResult -Skipped -Because 'Check requires admin privileges'
                }
            }


            It 'Should check Firewall status for Public networks' {
                Check -If (
                    ($FirewallProfile | where Name -like 'Public').Enabled
                ) -IsCompliantWith $Compliance.FireWall.Settings.FireWallIsOnForPublic
            }

            It 'Should check Firewall rules existence in Public networks' {
                Check -If (
                    ($FirewallRule | where Profile -like 'Public').Count -ge 1
                ) -IsCompliantWith $Compliance.FireWall.Settings.FireWallRulesExistsForPublic

            }

            It 'Should check for "allow all" rules for Public networks' {
                if ($IsAdmin) {
                    Check -If (
                        [bool](($FirewallRule | where {
                            $_.Profile -eq 'Public' -and
                            $_.Action -eq 'Allow' -and
                            (
                                $_.Program -eq 'Any' -or
                                $_.LocalPort -eq 'Any'
                            )
                        }) -eq $null)
                    ) -IsCompliantWith $Compliance.FireWall.Settings.NoAllowAllForPublic
                }
                if (!$IsAdmin) {
                    Set-ItResult -Skipped -Because 'Check requires admin privileges'
                }
            }

            It 'Should check Firewall status for Domain networks' {
                Check -If (
                    ($FirewallProfile | where Name -like 'Domain').Enabled
                ) -IsCompliantWith $Compliance.FireWall.Settings.FireWallIsOnForDomain
            }

            It 'Should check Firewall rules existence in Domain networks' {
                Check -If (
                    ($FirewallRule | where Profile -like 'Domain').Count -ge 1
                ) -IsCompliantWith $Compliance.FireWall.Settings.FireWallRulesExistsForDomain

            }

            It 'Should check for "allow all rule" for Domain networks' {
                if ($IsAdmin) {
                    Check -If (
                        [bool](($FirewallRule | where {
                            $_.Profile -eq 'Domain' -and
                            $_.Action -eq 'Allow' -and
                            (
                                $_.Program -eq 'Any' -or
                                $_.LocalPort -eq 'Any'
                            )
                        }) -eq $null)
                    ) -IsCompliantWith $Compliance.FireWall.Settings.NoAllowAllForDomain
                }
                if (!$IsAdmin) {
                    Set-ItResult -Skipped -Because 'Check requires admin privileges'
                }
            }

        }#end context Firewall
    }

    if ($Compliance.InternetSecurity.Active) {}
<#
    Context '- Get Internet Security Settings' {
        It 'Should have Internet Security Settings' {
            Set-ItResult -Skipped -Because 'Test does not exist yet' #! Fix
        }
    }# end context Internet Security
 #>
}#end describe Security

Describe '- Check MS Telemetry Compliance' -Tag Telemetry {

    if ($Compliance.Telemetry.Active) {
        if (Test-Path $Env:ProgramFiles\PowerShell\7){

            Context '- Get PowerShell Telemetry' {

                It 'Should check for for PoSH 7.x Telemetry' {
                    Check -If (
                        [bool]$ENV:POWERSHELL_TELEMETRY_OPTOUT #| Should -Not -BeNullOrEmpty
                    ) -IsCompliantWith $Compliance.Telemetry.Settings.PowerShell7TelemetryIsDisabled
                }

            }#end context PoSH
        }# end if

        $MyLocalAppPath = [Environment]::GetFolderPath('LocalApplicationData')

        if (
            (Test-Path $Env:ProgramFiles\'Microsoft VS Code') -or
            (Test-Path $MyLocalAppPath\Programs\'Microsoft VS Code')
            ) {#VS Code is installed

            Context '- Get VS Code Telemetry' {

                $MyAppPath = [Environment]::GetFolderPath('ApplicationData')
                $CodeSettings = get-content $MyAppPath\code\user\settings.json -ErrorAction SilentlyContinue | ConvertFrom-Json

                It 'Should check for VS Code Usage data' {
                    Check -If (
                        -not $CodeSettings.'telemetry.enableTelemetry'
                    ) -IsCompliantWith $Compliance.Telemetry.Settings.VSCodeUsageDataIsNotEnabled #| Should -Be 'False'
                }

                It 'Should check for VS Code Crash reports' {
                    Check -If (
                        -not $CodeSettings.'telemetry.enableCrashReporter'
                    ) -IsCompliantWith $Compliance.Telemetry.Settings.VSCodeCrashReportsIsNotEnabled # | Should -Be 'False'
                }

                #! GitLens defaults to optout but uses different values
                #TODOD Verify GitLens exists before checking for OptOut
                <# It 'Should not send GitLens usage data'{
                    $CodeSettings.'gitlens.advanced.telemetry.enabled' | Should -Be 'False'
                } #>

            }#end context VS Code
        }#end if

        Context '- Get Windows and Office Telemetry' {

            It 'Should check for Windows Data collections Telemetry'{
                Check -If (
                    (Get-ItemProperty HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection).AllowTelemetry -eq 0
                ) -IsCompliantWith $Compliance.Telemetry.Settings.WindowsDataCollectionIsDisabled
                # if ((Get-ItemProperty HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection).AllowTelemetry -eq 0){
                #     Set-ItResult -Skipped -Because 'not required (COMPLIANT)'
                # }
                # else {
                #     Set-ItResult -Skipped -Because 'not required (NOT compliant)'
                # }
            }

            It 'Should check for MS Customer Experience Improvement Program Telemetry'{
                Check -If (
                    (Get-ItemProperty HKLM:Software\Policies\Microsoft\SQMClient\Windows -ErrorAction SilentlyContinue).CEIPEnable -eq 0
                ) -IsCompliantWith $Compliance.Telemetry.Settings.MSCustomerExperienceImprovementProgramIsDisabled

                # if ((Get-ItemProperty HKLM:Software\Policies\Microsoft\SQMClient\Windows -ErrorAction SilentlyContinue).CEIPEnable -eq 0){
                #     Set-ItResult -Skipped -Because 'not required (COMPLIANT)'
                # }
                # else {
                #     Set-ItResult -Skipped -Because 'not required (NOT compliant)'
                # }
            }

            It 'Should check for Connected User Experiences and Telemetry Startup' {
                Check -If (
                    (Get-Service DiagTrack).StartType -eq 'Disabled'
                ) -IsCompliantWith $Compliance.Telemetry.Settings.ConnectedUserExperiencesandTelemetryServiceIsDisabled

                # if ((Get-Service DiagTrack).Status -eq 'Stopped'){
                #     Set-ItResult -Skipped -Because 'not required (COMPLIANT)'
                # }
                # else {
                #     Set-ItResult -Skipped -Because 'not required (NOT compliant)'
                # }
            }

            It 'Should check for Connected User Experiences and Telemetry Status' {
                Check -If (
                    (Get-Service DiagTrack).Status -eq 'Stopped'
                ) -IsCompliantWith $Compliance.Telemetry.Settings.ConnectedUserExperiencesandTelemetryServiceIsNotRunning
            }

            if ($Compliance.Telemetry.Settings.BlockPrivacyBlackList) {

                $PrivacyBlackList = $Compliance.Telemetry.PrivacyBlackList

                $PrivacyBlackList += (
                    Invoke-RestMethod -Uri $Compliance.Telemetry.PrivacyBlackListLink.WinOffice
                ).split("`n") | where {$_ -notlike '#*'}

                foreach ($BlackSite in $PrivacyBlackList) {
                    It "Should not succesfully connect to $BlackSite at TCP 80" {
                        $socket = New-Object System.Net.Sockets.TcpClient

                        try {
                            $TcpConnect80 = $socket.ConnectAsync($BlackSite,80).Wait(800)
                        }
                        finally {
                            $socket.close > $null
                        }

                        $TcpConnect80 | Should -Be 'false'
                    }

                    It "Should not succesfully connect to $BlackSite at TCP 443" {
                        $socket = New-Object System.Net.Sockets.TcpClient

                        try {
                            $TcpConnect443 = $socket.ConnectAsync($BlackSite,443).Wait(800)
                        }
                        finally {
                            $socket.close > $null
                        }

                        $TcpConnect443 | Should -Be 'false'
                    }

                }# end foreach

            }

        }#end context Windows
    }

}#end describe Telemetry

<#
.SYNOPSIS
    Pester script for minimal security compliance test on external computers.

.DESCRIPTION
    Pester script for minimal windows security compliance test on external computers.

    The test requires the following modules from PSGallery to be installed:

    - PSWindowsUpdate
    - Pester 4.10.1
    - PendingReboot
    - SpeculationControl

    Pester needs to be installed using:

    PS:> Install-Module pester -RequiredVersion 4.10.1 -SkipPublisherCheck -Force

    The other modules can be installed as ordinary modules.

    Some tests require admin permissions to be perfomed.

    Make sure to configure the compliance.json file before running the test and store it in ~.

.EXAMPLE
    .\Get-MiniCompliance.Tests.ps1

.EXAMPLE
    Invoke-Pester .\Get-MiniComplance.Tests.ps1

.NOTES
#>
