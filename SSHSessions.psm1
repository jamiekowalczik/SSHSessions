﻿#requires -version 3


<#
.SYNOPSIS
    A set of functions for dealing with SSH connections from PowerShell, using the SSH.NET
    library found here on CodePlex: http://sshnet.codeplex.com/

    See further documentation at:
    http://www.powershelladmin.com/wiki/SSH_from_PowerShell_using_the_SSH.NET_library

    Copyright (c) 2012-2017, Joakim Borger Svendsen.
    All rights reserved.
    Svendsen Tech.
    Author: Joakim Borger Svendsen.

    MIT license.

.DESCRIPTION
    See:
    Get-Help New-SshSession
    Get-Help Get-SshSession
    Get-Help Invoke-SshCommand
    Get-Help Enter-SshSession
    Get-Help Remove-SshSession
	Get-Help Get-SSHOutput

    http://www.powershelladmin.com/wiki/SSH_from_PowerShell_using_the_SSH.NET_library

2017-01-26: Rewriting a bit (about damn time). Not fixing completely.
            No concurrency for now either. Preparing to publish to PS gallery.

#>


# Function to convert a secure string to a plain text password.
# See http://www.powershelladmin.com/wiki/Powershell_prompt_for_password_convert_securestring_to_plain_text
function ConvertFrom-SecureToPlain {
    param(
        [Parameter(Mandatory=$true)][System.Security.SecureString] $SecurePassword)
    # Create a "password pointer"
    $PasswordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
    # Get the plain text version of the password
    $Private:PlainTextPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto($PasswordPointer)
    # Free the pointer
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($PasswordPointer)
    # Return the plain text password
    $Private:PlainTextPassword
}

function New-SshSession {
    <#
    .SYNOPSIS
        Creates SSH sessions to remote SSH-compatible hosts, such as Linux
        or Unix computers or network equipment. You can later issue commands
        to be executed on one or more of these hosts.

    .DESCRIPTION
        Once you've created a session, you can use Invoke-SshCommand or Enter-SshSession
        to send commands to the remote host or hosts.

        The authentication is done here. If you specify -KeyFile, that will be used.
        If you specify a password and no key, that will be used. If you do not specify
        a key nor a password, you will be prompted for a password, and you can enter
        it securely with asterisks displayed in place of the characters you type in.

    .PARAMETER ComputerName
        Required. DNS names or IP addresses for target hosts to establish
        a connection to using the provided username and key/password.
    .PARAMETER Username
        Required. The username used for connecting. See also -Credential.
    .PARAMETER KeyFile
        Optional. Specify the path to a private key file for authenticating.
        Overrides a specified password.
    .PARAMETER KeyPass
        Optional plain text password for the SSH key you use.
    .PARAMETER KeyCredential
        Optional PSCredentials object (help Get-Credential) with the key file password
        in the password field.
    .PARAMETER Credential
        Cannot be used with -Username and -Password. PSCredentials object containing a username
        and an encrypted password.
    .PARAMETER Password
        Optional. You can specify a key (and key password), or leave out the password(s)
        to be prompted for a password which is typed in interactively (will not be displayed).
    .PARAMETER Port
        Optional. Default 22. Target port the SSH server uses.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true,
                   ValueFromPipeline = $true,
                   ValueFromPipelineByPropertyName = $true)]
            [Alias('Cn', 'IPAddress', 'Hostname', 'Name', 'PSComputerName')]
            [String[]] $ComputerName,
        [String] $Username = '',
        [String] $KeyFile = '',
        [String] $KeyPass = 'SvendsenTechDefault', # allow for blank password
        
        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $KeyCredential = [System.Management.Automation.PSCredential]::Empty,
        
        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential = [System.Management.Automation.PSCredential]::Empty,
        
        [String] $Password = 'SvendsenTechDefault', # I guess allowing for a blank password is "wise"...
        [Int32] $Port = 22,
        [Switch] $Reconnect)
    begin {
        if ($KeyFile -ne '') {
            Write-Verbose -Message "Key file specified. Will override password. Trying to read key file..."
            if ($KeyPass -cne 'SvendsenTechDefault' -and $KeyCredential.Password -match '\S') {
                Write-Error -Message "You can't use both -KeyPass and -KeyCredential (which one do I use?). Leave one out."
                break
            }
            if (Test-Path -PathType Leaf -Path $Keyfile) {
                if ($KeyPass -cne "SvendsenTechDefault") {
                    $Key = New-Object Renci.SshNet.PrivateKeyFile -ErrorAction Stop -ArgumentList $KeyFile, $KeyPass -ErrorAction Stop
                }
                elseif ($KeyCredential.Password -notmatch '\S') {
                    $Key = New-Object -TypeName Renci.SshNet.PrivateKeyFile -ArgumentList $Keyfile -ErrorAction Stop
                }
                else {
                    $Key = New-Object -TypeName Renci.SshNet.PrivateKeyFile -ArgumentList $Keyfile,
                        $KeyCredential.GetNetworkCredential().Password -ErrorAction Stop
                }
            }
            else {
                Write-Error -Message "Specified keyfile does not exist: '$KeyFile'." -ErrorAction Stop
                break
            }
        }
        else {
            $Key = $false
        }
        # We're going to build a complete credentials object regardless of how credentials are supplied, and
        # keep the prompting feature some people might have grown to like. I could have used parameter sets here, I guess.
        if ($Credential.Username -and ($Username -or $Password -cne 'SvendsenTechDefault')) {
            Write-Error -Message "You specified both a credentials object and a username and/or password. I don't know which set to use. Leave one of them out." -ErrorAction Stop
            break
        }
        if ($Username -ne '') {
            #-and )) {
            # We know we can't have both a username and a "$Credential.Username", but we want a $Credential object.
            if (-not $Key) {
                if ($Password -ceq 'SvendsenTechDefault') {
                    $SecurePassword = Read-Host -AsSecureString -Prompt "No key or password provided. Enter SSH password for $Username (press enter for blank)"
                }
                else {
                    $SecurePassword = ConvertTo-SecureString -String $Password -AsPlainText -Force
                }
            }
            if ($Key -and $KeyPass -ceq 'SvendsenTechDefault') {
                $SecurePassword = ConvertTo-SecureString -String "doh" -AsPlainText -Force # for keys with no password
            }
            $Credential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $Username, $SecurePassword
        }
    }
    process {
        # Let's start creating sessions and storing them in $Global:SshSessions
        foreach ($Computer in $ComputerName) {
            if ($Global:SshSessions.ContainsKey($Computer) -and $Reconnect) {
                Write-Verbose -Message "[$Computer] Reconnecting."
                try {
                    $Null = Remove-SshSession -ComputerName $Computer -ErrorAction Stop
                }
                catch {
                    Write-Warning -Message "[$Computer] Unable to disconnect SSH session. Skipping connect attempt."
                    continue
                }
            }
            elseif ($Global:SshSessions.ContainsKey($Computer) -and $Global:SshSessions.$Computer.IsConnected) {
                Write-Verbose -Message "[$Computer] You are already connected." -Verbose
                continue
            }
            try {
                if ($Key) {
                    $SshClient = New-Object -TypeName Renci.SshNet.SshClient -ArgumentList $Computer, $Port, $Credential.Username, $Key
                }
                else {
                    $SshClient = New-Object -TypeName Renci.SshNet.SshClient -ArgumentList $Computer, $Port, $Credential.Username, $Credential.GetNetworkCredential().Password
                }
            }
            catch {
                Write-Warning -Message "[$Computer] Unable to create SSH client object: $_"
                continue
            }
            try {
                $SshClient.Connect()
            }
            catch {
                Write-Warning -Message "[$Computer] Unable to connect: $_"
                continue
            }
            if ($SshClient -and $SshClient.IsConnected) {
                Write-Verbose -Message "[$Computer] Successfully connected."
                $Global:SshSessions.$Computer = $SshClient
            }
            else {
                Write-Warning -Message "[$Computer] Unable to connect."
                continue
            }
        } # end of foreach
    }
    end {
        # Shrug... Can't hurt although I guess they should go out of scope here anyway.
        $KeyPass, $SecurePassword, $Password = $null, $null, $null
        [System.GC]::Collect()
    }
}

function Invoke-SshCommand {
    <#
    .SYNOPSIS
        Invoke/run commands via SSH on target hosts to which you have already opened
        connections using New-SshSession. See Get-Help New-SshSession.

    .DESCRIPTION
        Execute/run/invoke commands via SSH.

        You are already authenticated and simply specify the target(s) and the command.

        Output is emitted to the pipeline, so you collect results by using:
        $Result = Invoke-SshCommand [...]

        $Result there would be either a System.String if you target a single host or a
        System.Array containing strings if you target multiple hosts.

        If you do not specify -Quiet, you will also get colored Write-Host output - mostly
        for the sake of displaying progress.

        Use -InvokeOnAll to invoke on all hosts to which you have opened connections.
        The hosts will be processed in alphabetically sorted order.

    .PARAMETER ComputerName
        Target hosts to invoke command on.
    .PARAMETER Command
        Required unless you use -ScriptBlock. The Linux command to run on specified target computers.
    .PARAMETER ScriptBlock
        Required unless you use -Command. The Linux command to run on specified target computers.
        More convenient than a string for complex nested quotes, etc.
    .PARAMETER Quiet
        Causes no colored output to be written by Write-Host. If you assign results to a
        variable, no progress indication will be shown.
    .PARAMETER InvokeOnAll
        Invoke the specified command on all computers for which you have an open connection.
        Overrides -ComputerName, but you will be asked politely if you want to continue,
        if you specify both parameters.
    #>
    [CmdletBinding(
        DefaultParameterSetName = "Command"
    )]
    param(
        [Parameter(ValueFromPipeline = $true,
            ValueFromPipelineByPropertyName = $true,
            Position = 0
        )]
        [Alias('Cn', 'IPAddress', 'Hostname', 'Name', 'PSComputerName')]
        [String[]] $ComputerName, # can't have it mandatory due to -InvokeOnAll...
    
        [Parameter(Mandatory = $true,
            ParameterSetName="String",
            Position = 1)]
        [String] $Command,

        [Parameter(Mandatory = $true,
            ParameterSetName="ScriptBlock",
            Position = 1)]
        [ScriptBlock] $ScriptBlock,

        [Switch] $Quiet,
        [Switch] $InvokeOnAll)
    begin {
        if ($InvokeOnAll) {
            if ($ComputerName) {
                $Answer = Read-Host -Prompt "You specified both -InvokeOnAll and -ComputerName. -InvokeOnAll overrides and targets all hosts.`nAre you sure you want to continue? (y/n) [yes]"
                if ($Answer -imatch '^n') {
                    Write-Warning -Message "Aborting." -ErrorAction Stop
                    break
                }
            }
            if ($Global:SshSessions.Keys.Count -eq 0) {
                Write-Warning -Message "-InvokeOnAll specified, but no hosts found. See Get-Help New-SshSession."
                break
            }
            # Get all computer names from the global SshSessions hashtable.
            $ComputerName = $Global:SshSessions.Keys | Sort-Object -Property @{ Expression = {
                # Intent: Sort IP addresses correctly.
                [Regex]::Replace($_, '(\d+)', { '{0:D16}' -f [int] $args[0].Value }) }
            }, @{ Expression = { $_ } }
        }
        # Better pipeline support requires this to be removed / commented out.
        #if (-not $ComputerName) {
        #    "No computer names specified and -InvokeOnAll not specified. Can not continue."
        #    break
        #}
    }
    process {
        , @(foreach ($Computer in $ComputerName) {
            if (-not $Global:SshSessions.ContainsKey($Computer)) {
                #Write-Verbose -Message "No SSH session found for $Computer. See Get-Help New-SshSession. Skipping."
                Write-Warning -Message "[$Computer] No SSH session found. See Get-Help New-SshSession. Skipping."
                continue
            }
            if (-not $Global:SshSessions.$Computer.IsConnected) {
                #Write-Verbose -Message "You are no longer connected to $Computer. Skipping."
                Write-Warning -Message "[$Computer] You are no longer connected. Skipping."
                continue
            }
            if ($PSCmdlet.ParameterSetName -eq "ScriptBlock") {
                $Command = $ScriptBlock.ToString()
            }
            $CommandObject = $Global:SshSessions.$Computer.RunCommand($Command)
            # Write "pretty", colored results with Write-Host unless the quiet switch is provided.
            if (-not $Quiet) {
                if ($CommandObject.ExitStatus -eq 0) {
                    Write-Host -Fore Green -NoNewline "[${Computer}] "
                    Write-Host -Fore Cyan ($CommandObject.Result -replace '[\r\n]+\z', '')
                }
                else {
                    Write-Host -Fore Green -NoNewline "[${Computer}] "
                    Write-Host -Fore Yellow 'had an error:' ($CommandObject.Error -replace '[\r\n]+', ' ')
                }
            }
            # Now emit to the pipeline
            # 2018-01-01: Super breaking change! Emit the entire $CommandObject for easier ways to play with the
            # properties. ... Changed my mind, but will return objects, which is equally breaking.
            #$CommandObject
            
            if ($CommandObject.ExitStatus -eq 0) {
                # Emit results to the pipeline. Twice the fun unless you're assigning the results to a variable.
                # Changed from .Trim(). Remove the trailing carriage returns and newlines that might be there,
                # in case leading whitespace matters in later processing. Not sure I should even be doing this.
                [PSCustomObject] @{
                    ComputerName = $Computer
                    Result = $CommandObject.Result -replace '[\r\n]+\z'
                    Error = $False
                }
            }
            else {
                # Same comment as above applies ...
                #$CommandObject.Error -replace '[\r\n]+\z', ''
                #New-Object -TypeName PSObject -Property @{
                [PSCustomObject] @{
                    ComputerName = $Computer
                    Result = $CommandObject.Error -replace '[\r\n]+\z'
                    Error = $True
                } # | Select-Object -Property ComputerName, Result, Error
            }
            #>
            $CommandObject.Dispose()
            $CommandObject = $Null
        })
    }
    end {
        [System.GC]::Collect()
    }
}

function Enter-SshSession {
    <#
    .SYNOPSIS
        Enter a primitive interactive SSH session against a target host.
        Commands are executed on the remote host as you type them and you are
        presented with a Linux-like prompt.

    .DESCRIPTION
        Enter commands that will be executed by the host you specify and have already
        opened a connection to with New-SshSession.

        You can not permanently change the current working directory on the remote host.

    .PARAMETER ComputerName
        Required. Target host to connect with.
    .PARAMETER NoPwd
        Optional. Do not try to include the default remote working directory in the prompt.
    #>
    param([Parameter(Mandatory=$true)] [Alias('Name', 'IPAddress', 'Cn', 'PSComputerName')] [string] $ComputerName,
            [switch] $NoPwd)
    if (-not $Global:SshSessions.ContainsKey($ComputerName)) {
        Write-Error -Message "[$Computer] No SSH session found. See Get-Help New-SshSession. Skipping." `
            -ErrorAction Stop
        return
    }
    if (-not $Global:SshSessions.$ComputerName.IsConnected) {
        Write-Error -Message "[$Computer] The connection has been lost. See Get-Help New-SshSession and notice the -Reconnect parameter." `
            -ErrorAction Stop
        return
    }
    $SshPwd = ''
    # Get the default working dir of the user (won't be updated...)
    if (-not $NoPwd) {
        $SshPwdResult = $Global:SshSessions.$ComputerName.RunCommand('pwd')
        if ($SshPwdResult.ExitStatus -eq 0) {
            $SshPwd = $SshPwdResult.Result.TrimEnd()
        }
        else {
            $SshPwd = '(pwd failed)'
        }
    }
    $Command = ''
    while (1) {
        if (-not $Global:SshSessions.$ComputerName.IsConnected) {
            Write-Error -Message "[$Computer] Connection lost." -ErrorAction Stop
            return
        }
        $Command = Read-Host -Prompt "[$ComputerName]: $SshPwd # "
        # Break out of the infinite loop if they type "exit" or "quit"
        if ($Command -ieq 'exit' -or $Command -ieq 'quit') {
            break
        }
        $Result = $Global:SshSessions.$ComputerName.RunCommand($Command)
        if ($Result.ExitStatus -eq 0) {
            $Result.Result -replace '[\r\n]+\z', ''
        }
        else {
            $Result.Error -replace '[\r\n]+\z', ''
        }
    } # end of while
}

function Remove-SshSession {
    <#
    .SYNOPSIS
        Removes opened SSH connections. Use the parameter -RemoveAll to remove all connections.

    .DESCRIPTION
        Performs disconnect (if connected) and dispose on the SSH client object, then
        sets the $global:SshSessions hashtable value to $null and then removes it from
        the hashtable.

    .PARAMETER ComputerName
        The names of the hosts for which you want to remove connections/sessions.
    .PARAMETER RemoveAll
        Removes all open connections and effectively empties the hash table.
        Overrides -ComputerName, but you will be asked politely if you are sure,
        if you specify both.
    #>
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
              [Alias('Cn', 'IPAddress', 'Hostname', 'Name', 'PSComputerName')]
              [String[]] $ComputerName, # can't have it mandatory due to -RemoveAll
          [Switch]   $RemoveAll)
    begin {
        if ($RemoveAll) {
            if ($ComputerName) {
                $Answer = Read-Host -Prompt "You specified both -RemoveAll and -ComputerName. -RemoveAll overrides and removes all connections.`nAre you sure you want to continue? (y/n) [yes]"
                if ($Answer -imatch 'n') {
                    break
                }
            }
            if ($Global:SshSessions.Keys.Count -eq 0) {
                Write-Warning -Message "Parameter -RemoveAll specified, but no hosts found."
                # This terminates the calling script (I had noe clue it behaved like that, honestly, was surprised).
                # My workaround is relying on that the above check for both -ComputerName and -RemoveAll
                # makes the process block moot unless someone is piping in, in which case Get-SshSession will halt before
                # this advanced function is called. Based on feedback.
                #break
            }
            # Get all computer names from the global SshSessions hashtable.
            $ComputerName = $Global:SshSessions.Keys | Sort-Object
        }
        <# The logic breaks with pipeline input from Get-SshSession
        if (-not $ComputerName) {
            "No computer names specified and -RemoveAll not specified. Can not continue."
            break
        }#>
    }
    process {
        foreach ($Computer in $ComputerName) {
            if (-not $Global:SshSessions.ContainsKey($Computer)) {
                Write-Warning -Message "[$Computer] The SSH client pool does not contain a session for this computer. Skipping."
                continue
            }
            $ErrorActionPreference = 'Continue'
            if ($Global:SshSessions.$Computer.IsConnected) { $Global:SshSessions.$Computer.Disconnect() }
            $Global:SshSessions.$Computer.Dispose()
            $Global:SshSessions.$Computer = $null
            $Global:SshSessions.Remove($Computer)
            $ErrorActionPreferene = $MyEAP
            Write-Verbose -Message "[$Computer] Now disconnected and disposed."
        }
    }
}

function Get-SshSession {
    <#
    .SYNOPSIS
        Shows all, or the specified, SSH sessions in the global $SshSessions variable,
        along with the connection status.

    .DESCRIPTION
        It checks if they're still reported as connected and reports that too. However,
        they can have a status of "connected" even if the remote computer has rebooted.
        Seems like an issue with the SSH.NET library and how it maintains this status.

        If you specify hosts with -ComputerName, which don't exist in the $SshSessions
        variable, the "Connected" value will be "NULL" for these hosts.

        Also be aware that with the version of the SSH.NET library at the time of writing,
        the host will be reported as connected even if you use the .Disconnect() method
        on it. When you invoke the .Dispose() method, it does report the connection status
        as false.

    .PARAMETER ComputerName
        Optional. The default behavior is to list all hosts alphabetically, but this
        lets you specify hosts to target specifically. NULL is returned as the connection
        status if a non-existing host name/IP is passed in.
    #>
    
    [CmdletBinding()]
    param([Alias('Cn', 'IPAddress', 'Hostname', 'Name', 'PSComputerName')] [string[]] $ComputerName)
    
    begin {
        # Just exit with a message if there aren't any connections.
        if ($Global:SshSessions.Count -eq 0) {
            Write-Warning -Message "No connections found."
            # This terminates the calling script too (so I learned today, at least in v5.1). Removing.
            #break
        }
    }
    process {
        if (-not $ComputerName) { $ComputerName = $Global:SshSessions.Keys | Sort-Object -Property @{
            Expression = {
                # Intent: Sort IP addresses correctly.
                [Regex]::Replace($_, '(\d+)', { '{0:D16}' -f [int] $args[0].Value }) }
            }, @{ Expression = { $_ } }
        }
        foreach ($Computer in $ComputerName) {        
            # Unless $ComputerName is specified, use all hosts in the global variable, sorted alphabetically.
            $Properties =
                @{n='ComputerName';e={$_}},
                @{n='Connected';e={
                    # Ok, this isn't too pretty... Populate non-existing objects'
                    # "connected" value with $null
                    if ($Global:SshSessions.ContainsKey($_)) {
                        $Global:SshSessions.$_.IsConnected
                    }
                    else {
                        $Null
                    }
                }}
            # Process the hosts and emit output to the pipeline.
            $Computer | Select-Object -Property $Properties
        }
    }
}

Function Get-SSHOutput{
   <#
   .SYNOPSIS
      This will execute a command through an SSH session and optionally write the output to a file.

   .DESCRIPTION
      This will execute a command through an SSH session and optionally write the output to a file.

   .EXAMPLE
      Get-SSHOutput -Username "auser" -Password "apassword" -Hostname "switch1" -Command "more system:running-config" 

   .EXAMPLE
      Get-SSHOutput -Username "auser" -Password "apassword" -Hostname "switch1" -Command "more system:running-config" -CreateOutputFile $true -OutputFilename "maintenace.log" -OutputCommand $true

   .NOTES
      For this function to work you must reference the Renci.SshNet Library.

   .LINK
      https://www.powershelladmin.com/w/images/a/a5/SSH-SessionsPSv3.zip
   #>
   Param(
         # The username to login to the remote device with
         [Parameter(Mandatory=$true)][String]$Username = "",
         # The password to login to the remote device with
         [Parameter(Mandatory=$true)][String]$Password = "",
         # The remote device's IP address or FQDN
         [Parameter(Mandatory=$true)] [String]$Hostname = "",
         # The command to run on the remote device
         [Parameter(Mandatory=$true)][String]$Command = "",
         # This will create an output file with the results of the command
         [Bool]$CreateOutputFile = $false,
         # This determine's the output filename.  If Output is being generated
         # and this isn't set the filename will be the device's <hostname>.txt
         [String]$OutputFilename = "",
         # This will append the output file if it exists
         [Bool]$AppendOutputFile = $false,
         # This will include the command in the output file
         [Bool]$OutputCommand = $false,
         # If set to True then debugging information will be displayed to the user
         [Bool]$DebugFunction = $false
   )
   
   If($DebugFunction){
      $CommandName = $PSCmdlet.MyInvocation.InvocationName;
      # Get the list of parameters for the command
      $ParameterList = (Get-Command -Name $CommandName).Parameters;
      $now = Get-Date; Write-Host "`n$($MyInvocation.MyCommand.Name):: started $now"
      # Grab each parameter value, using Get-Variable
      $FunctionVariables = ""
      foreach ($Parameter in $ParameterList) {
         $FunctionVariables = Get-Variable -Name $Parameter.Values.Name -ErrorAction SilentlyContinue | Out-String
      }
      Write-Host "$FunctionVariables"
   }

   Try{
      $sess = New-SshSession -ComputerName $Hostname -Username $Username -Password $Password 
      $output = Invoke-SshCommand -ComputerName $Hostname -Command $Command -Quiet
      If($CreateOutputFile){
         If($OutputFilename -eq ""){
            If($AppendOutputFile){ 
               If($OutputCommand){ "$($Command)`n$($output).Result" | Out-File "$($Hostname).txt" -Append }Else{ $($output).Result | Out-File "$($Hostname).txt" -Append }
            }Else{ 
               If($OutputCommand){ "$($Command)`n$($output).Result" | Out-File "$($Hostname).txt" }Else{ $($output).Result | Out-File "$($Hostname).txt" }
            }
         }Else{
            If($AppendOutputFile){ 
               If($OutputCommand){ "$($Command)`n$($output).Result" | Out-File $OutputFilename -Append }Else{ $($output).Result | Out-File $OutputFilename -Append }
            }Else{ 
               If($OutputCommand){ "$($Command)`n$($output).Result" | Out-File $OutputFilename }Else{ $($output).Result | Out-File $OutputFilename }
            }
         }
      }
      Return $($output)
   }Catch{
      Write-Host $_.Exception.Message
   }
}
######## END OF FUNCTIONS ########
Set-StrictMode -Version Latest
$MyEAP = 'Stop'
$ErrorActionPreference = $MyEAP
$Global:SshSessions = @{}
#Export-ModuleMember New-SshSession, Invoke-SshCommand, Enter-SshSession, `
#                    Remove-SshSession, Get-SshSession, ConvertFrom-SecureToPlain, Get-SSHOutput
