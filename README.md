# BydCompliance

## 1. Description

[BydCompliance](https://github.com/DennisL68/BydCompliance) is a Pester v4 test that will show if your development rig is compliant with the 
corporation policies where you are working.

Simply enter the values provided by the IT Security department (if they let you know) in the configuration file and run the test.

## 2. Requirements

The prerequisites for using the artifact of this repo is

* A Windows Computer
* Windows PowerShell
* Pester 4.10.1
* Module PSWindowsUpdate
* Module PendingReboot 
* Module SpeculationControl

## 3. Limitations

The script can only test what the Pester script is handling. Feel free to add additional tests.

## 4. How do I use this repo?

* `Install-Module BydCompliance` (not released to PS Gallery yet)
* Install the prerequisites.
* Copy the settings json file `compliance.json` from the GitHub project to your `~`-folder and choose what test you 
  would liking using `true` or `false`.
* `Invoke-Pester .\Get-MiniCompliance.Tests.ps1` as administrator.

## 5. References and links

* [Introduction to Pester][1]
* [Pester v4 Docs][1]

## 6. Contacts

Please contact the author for any questions or if you'd like to help out.

[1]:https://www.dbi-services.com/blog/an-introduction-to-pester-unit-testing-and-infrastructure-checks-in-powershell/
[2]:https://pester.dev/docs/v4/quick-start
