import 'dart:convert';

/// The "Full Windows scan": a library of READ-ONLY PowerShell checks that are run on a Windows PC over SSH
/// (through Termux), in parallel, and a few pure helpers around them (finding the SSH connection, encoding the
/// commands, cleaning the output, guarding anything that would change the PC). Nothing in here changes the PC.

enum ScanCategory { system, malware, persistence, network, files, accounts, ram }

String scanCategoryLabel(ScanCategory c) => switch (c) {
      ScanCategory.system => 'System',
      ScanCategory.malware => 'Processes & malware',
      ScanCategory.persistence => 'Persistence (start-up, tasks, services)',
      ScanCategory.network => 'Network',
      ScanCategory.files => 'Files',
      ScanCategory.accounts => 'Accounts & logs',
      ScanCategory.ram => 'Memory (RAM)',
    };

class ScanCheck {
  const ScanCheck(this.id, this.title, this.category, this.script, {this.timeoutSec = 90, this.slow = false});

  final String id;
  final String title;
  final ScanCategory category;

  /// PowerShell, read-only.
  final String script;
  final int timeoutSec;

  /// Takes a while: started first so the whole scan finishes sooner.
  final bool slow;
}

/// Put in front of every script: quiet errors, no progress output, UTF-8 so Arabic and other text survives.
const String kPsPrelude = r"$ErrorActionPreference='SilentlyContinue';$ProgressPreference='SilentlyContinue';"
    r"try{[Console]::OutputEncoding=[Text.Encoding]::UTF8}catch{};";

/// The Base64 of the UTF-16LE text, which is what powershell -EncodedCommand expects. Encoding the script
/// means no quoting problem can come from the shells on the way (Termux's, ssh's, the PC's).
String psEncode(String script) {
  final bytes = <int>[];
  for (final u in (kPsPrelude + script).codeUnits) {
    bytes
      ..add(u & 0xff)
      ..add((u >> 8) & 0xff);
  }
  return base64Encode(bytes);
}

/// The text of a -EncodedCommand argument, decoded.
String psDecode(String b64) {
  try {
    final bytes = base64Decode(b64);
    final units = <int>[];
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      units.add(bytes[i] | (bytes[i + 1] << 8));
    }
    return String.fromCharCodes(units);
  } catch (_) {
    return '';
  }
}

// ───────────────────────────── the checks ─────────────────────────────

const List<ScanCheck> kScanChecks = <ScanCheck>[
  // ── system ──
  ScanCheck('sysinfo', 'System, patches and disks', ScanCategory.system, r'''
$o=Get-CimInstance Win32_OperatingSystem;$c=Get-CimInstance Win32_ComputerSystem
$adm=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
"Host=$env:COMPUTERNAME User=$env:USERDOMAIN\$env:USERNAME Admin=$adm PS=$($PSVersionTable.PSVersion)"
"OS=$($o.Caption) v$($o.Version) build $($o.BuildNumber) installed=$($o.InstallDate) lastboot=$($o.LastBootUpTime)"
"CPU cores=$($c.NumberOfLogicalProcessors) RAM_GB=$([math]::Round($c.TotalPhysicalMemory/1GB,1)) Domain=$($c.Domain)"
Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3'|%{"Disk $($_.DeviceID) free $([math]::Round($_.FreeSpace/1GB,1)) of $([math]::Round($_.Size/1GB,1)) GB"}
Get-HotFix|Sort-Object InstalledOn -Descending|Select-Object -First 5|%{"Patch $($_.HotFixID) installed $($_.InstalledOn)"}
'Secure Boot: '+(Confirm-SecureBootUEFI)
'BitLocker: '+((Get-BitLockerVolume|%{"$($_.MountPoint)=$($_.ProtectionStatus)"}) -join ' ')
'''),
  ScanCheck('defender', 'Antivirus (Defender) status, exclusions and detections', ScanCategory.malware, r'''
$s=Get-MpComputerStatus
if($s){"Defender: AV=$($s.AntivirusEnabled) RealTime=$($s.RealTimeProtectionEnabled) Tamper=$($s.IsTamperProtected) SigAgeDays=$($s.AntivirusSignatureAge) SigUpdated=$($s.AntivirusSignatureLastUpdated) LastQuick=$($s.QuickScanEndTime) LastFull=$($s.FullScanEndTime)"}else{'Defender status unavailable (another antivirus, or no rights)'}
$p=Get-MpPreference
"Exclusion paths: $($p.ExclusionPath -join '; ')"
"Exclusion processes: $($p.ExclusionProcess -join '; ')"
"Exclusion extensions: $($p.ExclusionExtension -join '; ')"
'--- Threat detections (newest first) ---'
Get-MpThreatDetection|Sort-Object InitialDetectionTime -Descending|Select-Object -First 15|%{"$($_.InitialDetectionTime) threat=$($_.ThreatID) removed=$($_.ActionSuccess) $($_.Resources -join ',')"}
'--- Known threats ---'
Get-MpThreat|Select-Object -First 15|%{"$($_.ThreatName) severity=$($_.SeverityID) active=$($_.IsActive)"}
'--- Firewall profiles ---'
Get-NetFirewallProfile|%{"$($_.Name) enabled=$($_.Enabled)"}
'--- Installed AV products ---'
Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct|%{"$($_.displayName) state=$($_.productState)"}
'''),

  // ── processes ──
  ScanCheck('procs_paths', 'Processes running from risky folders or without a path', ScanCategory.malware, r'''
$pr=Get-CimInstance Win32_Process
$par=@{};$pr|%{$par[[int]$_.ProcessId]=$_.Name}
"Total processes: $($pr.Count)"
'--- Running from Temp / AppData / Downloads / Public / ProgramData / Recycle Bin ---'
$pr|?{$_.ExecutablePath -match '\\(Temp|AppData|Downloads|Users\\Public|ProgramData|\$Recycle\.Bin|Windows\\Tasks|PerfLogs)\\'}|Select-Object -First 80|%{"{0,6} {1,-24} parent={2,-14} {3}" -f $_.ProcessId,$_.Name,$par[[int]$_.ParentProcessId],$_.ExecutablePath}
'--- No readable path (protected, or hiding) ---'
$pr|?{-not $_.ExecutablePath -and $_.Name -notin 'System','Registry','Idle','System Idle Process','Memory Compression','MemCompression','Secure System','vmmem','vmmemWSL'}|Select-Object -First 40|%{"{0,6} {1} parent={2}" -f $_.ProcessId,$_.Name,$par[[int]$_.ParentProcessId]}
'''),
  ScanCheck('procs_unsigned', 'Signature of every program outside Windows', ScanCategory.malware, r'''
$paths=Get-CimInstance Win32_Process|?{$_.ExecutablePath -and $_.ExecutablePath -notmatch '^C:\\Windows\\'}|Select-Object -ExpandProperty ExecutablePath -Unique
$rows=foreach($f in $paths){$s=Get-AuthenticodeSignature -FilePath $f;$sub=if($s.SignerCertificate){($s.SignerCertificate.Subject -split ',')[0]}else{''};[pscustomobject]@{Status=[string]$s.Status;Path=$f;Signer=$sub}}
"Programs checked: $(@($rows).Count)"
'--- NOT validly signed ---'
$rows|?{$_.Status -ne 'Valid'}|%{"{0,-12} {1}" -f $_.Status,$_.Path}
'--- Validly signed (signer) ---'
$rows|?{$_.Status -eq 'Valid'}|Sort-Object Signer|Select-Object -First 70|%{"{0,-40} {1}" -f $_.Signer,$_.Path}
''', timeoutSec: 150, slow: true),
  ScanCheck('cmdlines', 'Suspicious command lines (encoded, hidden, downloaders, miners)', ScanCategory.malware, r'''
$rx='(?i)-enc(odedcommand)?\s|-w(indowstyle)?\s+hidden|downloadstring|downloadfile|invoke-expression|\biex\b|frombase64string|mshta|regsvr32.*(/i:|scrobj)|rundll32.*(javascript|http)|certutil.*(urlcache|decode)|bitsadmin.*transfer|wmic.*process.*call|wscript|cscript.*\.(vbs|js)|-nop\b|bypass|stratum\+tcp|--donate|curl.*http|wget.*http|\bnc(at)?(\.exe)?\s+-'
$own='^"?powershell(\.exe)?"? -NoProfile -NonInteractive -EncodedCommand [A-Za-z0-9+/=]+$'
Get-CimInstance Win32_Process|?{$_.CommandLine -match $rx -and $_.CommandLine -notmatch $own -and $_.ProcessId -ne $PID}|%{"{0,6} {1} parent={2}`n      {3}" -f $_.ProcessId,$_.Name,$_.ParentProcessId,$_.CommandLine}
'(end of list; nothing above means no process matched)'
'''),
  ScanCheck('masquerade', 'Fake system processes (wrong folder, wrong parent, look-alike names)', ScanCategory.malware, r'''
$sys='svchost','lsass','csrss','winlogon','services','smss','wininit','spoolsv','taskhostw','dwm','conhost','sihost','fontdrvhost','lsaiso','WmiPrvSE','SearchIndexer','dllhost','RuntimeBroker'
$w=[regex]::Escape($env:windir)
$pr=Get-CimInstance Win32_Process
$par=@{};$pr|%{$par[[int]$_.ProcessId]=$_}
foreach($p in $pr){$n=$p.Name -replace '\.exe$',''
 if($sys -contains $n -and $p.ExecutablePath -and $p.ExecutablePath -notmatch "^$w\\(System32|SysWOW64)\\"){"WRONG PATH: $($p.ProcessId) $($p.Name) -> $($p.ExecutablePath)"}
 if($p.Name -match '^svchost' -and $p.CommandLine -and $p.CommandLine -notmatch '-k '){"svchost without -k: $($p.ProcessId) $($p.CommandLine)"}
 $pp=$par[[int]$p.ParentProcessId]
 if($n -match '^(lsass|services)$' -and $pp -and $pp.Name -notmatch '^wininit'){"ODD PARENT: $($p.Name) pid $($p.ProcessId) parent $($pp.Name)"}
 if($n -match '^(svch0st|scvhost|svhost|svchosts|lsas|csrs|expl0rer|winlog0n|svchost32|systern)'){"LOOKALIKE NAME: $($p.Name) $($p.ExecutablePath)"}}
'(done)'
'''),
  ScanCheck('known_bad', 'Known miner / RAT / hacking-tool names (processes, services, tasks, files)', ScanCategory.malware, r'''
$rx='(?i)xmrig|xmr-stak|nicehash|minerd|cpuminer|nbminer|lolminer|phoenixminer|njrat|quasar|asyncrat|remcos|darkcomet|nanocore|warzone|netwire|orcus|blackshades|mimikatz|lazagne|procdump|psexec|ncat|plink|chisel|frpc|cobaltstrike|meterpreter|sliver'
'Processes:';Get-Process|?{$_.Name -match $rx}|%{"$($_.Name) pid=$($_.Id) $($_.Path)"}
'Services:';Get-CimInstance Win32_Service|?{$_.Name -match $rx -or $_.PathName -match $rx}|%{"$($_.Name) $($_.PathName)"}
'Tasks:';Get-ScheduledTask|?{$_.TaskName -match $rx}|%{$_.TaskName}
'Files:';foreach($d in $env:USERPROFILE,'C:\ProgramData','C:\Windows\Temp'){Get-ChildItem $d -Recurse -Depth 3 -File -Force|?{$_.Name -match $rx}|Select-Object -First 20|%{$_.FullName}}
'(done)'
''', timeoutSec: 170, slow: true),

  // ── persistence ──
  ScanCheck('run_keys', 'Start-up registry keys, Winlogon, IFEO, AppInit, LSA', ScanCategory.persistence, r'''
$keys='HKLM:\Software\Microsoft\Windows\CurrentVersion\Run','HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run','HKCU:\Software\Microsoft\Windows\CurrentVersion\Run','HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce','HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer\Run','HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer\Run'
foreach($k in $keys){$i=Get-ItemProperty $k;if($i){$i.PSObject.Properties|?{$_.Name -notmatch '^PS'}|%{"[$k] $($_.Name) = $($_.Value)"}}}
'--- Winlogon / AppInit / IFEO / LSA / BootExecute ---'
$w=Get-ItemProperty 'HKLM:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon';"Shell=$($w.Shell) Userinit=$($w.Userinit) Taskman=$($w.Taskman)"
$a=Get-ItemProperty 'HKLM:\Software\Microsoft\Windows NT\CurrentVersion\Windows';"AppInit_DLLs=$($a.AppInit_DLLs) LoadAppInit=$($a.LoadAppInit_DLLs) Load=$($a.Load)"
Get-ChildItem 'HKLM:\Software\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'|?{(Get-ItemProperty $_.PSPath).Debugger}|%{"IFEO Debugger: $($_.PSChildName) -> $((Get-ItemProperty $_.PSPath).Debugger)"}
Get-ChildItem 'HKLM:\Software\Microsoft\Windows NT\CurrentVersion\SilentProcessExit'|%{"SilentProcessExit: $($_.PSChildName)"}
"BootExecute=$((Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Session Manager').BootExecute -join ',')"
$l=Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Lsa';"LSA SecurityPackages=$($l.'Security Packages' -join ',') NotificationPackages=$($l.'Notification Packages' -join ',') RunAsPPL=$($l.RunAsPPL)"
'''),
  ScanCheck('startup_folders', 'Start-up folders and shortcut targets', ScanCategory.persistence, r'''
$d="$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Startup","$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
foreach($x in $d){"[$x]";Get-ChildItem $x -Force|%{"{0:yyyy-MM-dd HH:mm} {1} {2}" -f $_.LastWriteTime,$_.Attributes,$_.FullName}}
'--- Shortcut targets ---'
$sh=New-Object -ComObject WScript.Shell
foreach($x in $d){Get-ChildItem $x -Filter *.lnk -Force|%{$l=$sh.CreateShortcut($_.FullName);"$($_.Name) -> $($l.TargetPath) $($l.Arguments)"}}
'''),
  ScanCheck('sched_tasks', 'Scheduled tasks (non-Microsoft and unusual)', ScanCategory.persistence, r'''
Get-ScheduledTask|?{$_.TaskPath -notmatch '^\\Microsoft\\' -and $_.State -ne 'Disabled'}|%{$a=($_.Actions|%{"$($_.Execute) $($_.Arguments)"}) -join ' | ';"{0}{1} [{2}] user={3}`n      {4}" -f $_.TaskPath,$_.TaskName,$_.State,$_.Principal.UserId,$a}
'--- Microsoft-path tasks that launch shells or run from user folders ---'
Get-ScheduledTask|?{$_.TaskPath -match '^\\Microsoft\\'}|%{foreach($ac in $_.Actions){if($ac.Execute -and ("$($ac.Execute) $($ac.Arguments)") -match '(?i)(powershell|cmd\.exe|wscript|cscript|mshta|rundll32|regsvr32|\\Temp\\|AppData)'){"$($_.TaskPath)$($_.TaskName): $($ac.Execute) $($ac.Arguments)"}}}
'(done)'
'''),
  ScanCheck('services', 'Third-party services, unquoted paths, newly installed services', ScanCategory.persistence, r'''
$all=Get-CimInstance Win32_Service
'--- Services outside Windows folders ---'
$all|?{$_.PathName -and $_.PathName -notmatch '(?i)^"?C:\\Windows\\(System32|SysWOW64)\\' -and $_.PathName -notmatch '(?i)Windows Defender|\\Microsoft\\'}|%{"{0,-28} {1,-8} {2,-8} {3}`n      user={4}" -f $_.Name,$_.State,$_.StartMode,$_.PathName,$_.StartName}
'--- Unquoted paths with spaces ---'
$all|?{$_.PathName -and $_.PathName -notmatch '^"' -and $_.PathName -match '^[A-Za-z]:\\.* .*\.exe' -and $_.PathName -notmatch '(?i)^C:\\Windows\\'}|%{"$($_.Name): $($_.PathName)"}
'--- Services installed in the last 60 days (event 7045) ---'
Get-WinEvent -FilterHashtable @{LogName='System';Id=7045;StartTime=(Get-Date).AddDays(-60)} -MaxEvents 25|%{"$($_.TimeCreated) $($_.Properties[0].Value) -> $($_.Properties[1].Value)"}
'(done)'
'''),
  ScanCheck('wmi_persist', 'WMI event subscriptions (hidden persistence)', ScanCategory.persistence, r'''
'Filters:';Get-CimInstance -Namespace root\subscription -ClassName __EventFilter|%{"$($_.Name): $($_.Query)"}
'Consumers:';Get-CimInstance -Namespace root\subscription -ClassName __EventConsumer|%{"$($_.CimClass.CimClassName) $($_.Name): $($_.CommandLineTemplate)$($_.ScriptText)"}
'Bindings:';Get-CimInstance -Namespace root\subscription -ClassName __FilterToConsumerBinding|%{"$($_.Filter) => $($_.Consumer)"}
'(Only the default "SCM Event Log" filter/consumer is normal)'
'''),
  ScanCheck('drivers', 'Drivers outside System32 and unsigned drivers', ScanCategory.persistence, r'''
'--- Running drivers outside System32\drivers ---'
Get-CimInstance Win32_SystemDriver|?{$_.State -eq 'Running' -and $_.PathName -and $_.PathName -notmatch '(?i)\\System32\\drivers\\|\\SystemRoot\\System32\\'}|%{"{0,-24} {1}" -f $_.Name,$_.PathName}
'--- Unsigned drivers ---'
Get-CimInstance Win32_PnPSignedDriver|?{$_.IsSigned -eq $false}|Select-Object -First 20|%{"$($_.DeviceName) $($_.DriverProviderName) $($_.DriverVersion)"}
'--- Newest third-party drivers ---'
Get-CimInstance Win32_PnPSignedDriver|?{$_.DriverProviderName -and $_.DriverProviderName -notmatch 'Microsoft|Intel|AMD|NVIDIA|Realtek|Qualcomm'}|Sort-Object DriverDate -Descending|Select-Object -First 20|%{"$($_.DriverDate) $($_.DeviceName) [$($_.DriverProviderName)] $($_.DriverVersion)"}
'''),

  // ── network ──
  ScanCheck('net_conns', 'Open ports and outgoing connections, with the program behind each', ScanCategory.network, r'''
$pr=@{};Get-CimInstance Win32_Process|%{$pr[[int]$_.ProcessId]=$_}
'--- Listening TCP ports ---'
Get-NetTCPConnection -State Listen|Sort-Object LocalPort|Select-Object -First 80|%{$p=$pr[[int]$_.OwningProcess];"{0,-24} pid={1,-6} {2,-20} {3}" -f ("$($_.LocalAddress):$($_.LocalPort)"),$_.OwningProcess,$p.Name,$p.ExecutablePath}
'--- Established to public addresses ---'
Get-NetTCPConnection -State Established|?{$_.RemoteAddress -notmatch '^(127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|::1|fe80)'}|Select-Object -First 80|%{$p=$pr[[int]$_.OwningProcess];"{0,-36} pid={1,-6} {2,-20} {3}" -f ("$($_.RemoteAddress):$($_.RemotePort)"),$_.OwningProcess,$p.Name,$p.ExecutablePath}
'--- UDP endpoints per program ---'
Get-NetUDPEndpoint|?{$_.LocalAddress -notmatch '^(127|::1|fe80)'}|Group-Object OwningProcess|Select-Object -First 25|%{$p=$pr[[int]$_.Name];"$($p.Name) pid=$($_.Name) endpoints=$($_.Count)"}
'(done)'
'''),
  ScanCheck('net_misc', 'hosts file, DNS, proxy, shares, remote access, firewall rules', ScanCategory.network, r'''
'--- hosts file (non-comment lines) ---';Get-Content "$env:windir\System32\drivers\etc\hosts"|?{$_ -notmatch '^\s*(#|$)'}
'--- DNS servers ---';Get-DnsClientServerAddress -AddressFamily IPv4|?{$_.ServerAddresses}|%{"$($_.InterfaceAlias): $($_.ServerAddresses -join ', ')"}
'--- Proxy ---';$i=Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings';"ProxyEnable=$($i.ProxyEnable) ProxyServer=$($i.ProxyServer) AutoConfigURL=$($i.AutoConfigURL)"
'--- SMB shares ---';Get-SmbShare|%{"$($_.Name) $($_.Path)"}
'--- Remote access ---'
"RDP fDenyTSConnections=$((Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server').fDenyTSConnections) (0 means Remote Desktop is ON)"
"Services: WinRM=$((Get-Service WinRM).Status) sshd=$((Get-Service sshd).Status) TermService=$((Get-Service TermService).Status) RemoteRegistry=$((Get-Service RemoteRegistry).Status)"
'--- Enabled inbound allow rules that are not part of a Windows group ---'
Get-NetFirewallRule -Enabled True -Direction Inbound -Action Allow|?{-not $_.DisplayGroup}|Select-Object -First 30|%{"$($_.DisplayName) [$($_.Profile)]"}
'--- Port proxies ---';netsh interface portproxy show all
'(done)'
'''),

  // ── files ──
  ScanCheck('recent_user', 'Recent programs and scripts in Temp, Downloads, Desktop, Public', ScanCategory.files, r'''
$since=(Get-Date).AddDays(-21)
$dirs=$env:TEMP,'C:\Windows\Temp','C:\Windows\Tasks','C:\Users\Public',"$env:USERPROFILE\Downloads","$env:USERPROFILE\Desktop"
foreach($d in $dirs){"[$d]";Get-ChildItem $d -Recurse -File -Force -Depth 3 -Include *.exe,*.dll,*.scr,*.ps1,*.bat,*.cmd,*.vbs,*.js,*.jse,*.hta,*.wsf,*.jar,*.msi,*.lnk|?{$_.LastWriteTime -gt $since}|Sort-Object LastWriteTime -Descending|Select-Object -First 40|%{"{0:yyyy-MM-dd HH:mm} {1,10} {2}" -f $_.LastWriteTime,$_.Length,$_.FullName}}
''', timeoutSec: 170, slow: true),
  ScanCheck('recent_appdata', 'Recent programs and scripts in AppData and ProgramData', ScanCategory.files, r'''
$since=(Get-Date).AddDays(-21)
$dirs=$env:APPDATA,$env:LOCALAPPDATA,'C:\ProgramData'
foreach($d in $dirs){"[$d]";Get-ChildItem $d -Recurse -File -Force -Depth 3 -Include *.exe,*.dll,*.scr,*.ps1,*.bat,*.cmd,*.vbs,*.js,*.jse,*.hta,*.wsf,*.jar,*.msi|?{$_.LastWriteTime -gt $since -and $_.FullName -notmatch '(?i)\\(Google\\Chrome|Microsoft\\Edge|Packages|Temp|Code|Discord|Slack|Teams)\\'}|Sort-Object LastWriteTime -Descending|Select-Object -First 40|%{"{0:yyyy-MM-dd HH:mm} {1,10} {2}" -f $_.LastWriteTime,$_.Length,$_.FullName}}
''', timeoutSec: 170, slow: true),
  ScanCheck('hidden_files', 'Hidden executables, alternate data streams, disguised file names', ScanCategory.files, r'''
'--- Hidden programs and scripts (user profile, C:\ root, ProgramData, Public) ---'
foreach($d in $env:USERPROFILE,'C:\','C:\ProgramData','C:\Users\Public'){Get-ChildItem $d -Force -Recurse -Depth 2 -File -Include *.exe,*.dll,*.ps1,*.bat,*.cmd,*.vbs,*.js,*.scr,*.hta|?{$_.Attributes -band [IO.FileAttributes]::Hidden}|Select-Object -First 25|%{"$($_.Attributes) $($_.FullName)"}}
'--- Alternate data streams (Downloads, Desktop, Temp, Public) ---'
foreach($d in "$env:USERPROFILE\Downloads","$env:USERPROFILE\Desktop",$env:TEMP,'C:\Users\Public'){Get-ChildItem $d -Recurse -Depth 2 -File -Force|%{Get-Item $_.FullName -Stream * -Force}|?{$_.Stream -ne ':$DATA' -and $_.Stream -ne 'Zone.Identifier'}|Select-Object -First 20|%{"$($_.FileName):$($_.Stream) ($($_.Length) bytes)"}}
'--- Double extensions or reversed names (Downloads, Desktop, Temp) ---'
foreach($d in "$env:USERPROFILE\Downloads","$env:USERPROFILE\Desktop",$env:TEMP){Get-ChildItem $d -Recurse -Depth 2 -File -Force|?{$_.Name -match '\.(pdf|docx?|xlsx?|jpe?g|png|txt|mp4)\.(exe|scr|bat|cmd|js|vbs|ps1|com)$' -or $_.Name.Contains([string][char]0x202E)}|%{$_.FullName}}
'(done)'
''', timeoutSec: 150, slow: true),

  // ── accounts, logs, software ──
  ScanCheck('accounts', 'Local accounts, administrators, sessions, auto-logon', ScanCategory.accounts, r'''
Get-LocalUser|%{"{0,-20} enabled={1} lastLogon={2} pwdLastSet={3} pwdRequired={4}" -f $_.Name,$_.Enabled,$_.LastLogon,$_.PasswordLastSet,$_.PasswordRequired}
'--- Administrators ---';Get-LocalGroupMember Administrators|%{"$($_.Name) [$($_.ObjectClass)] $($_.PrincipalSource)"}
'--- Remote Desktop Users ---';Get-LocalGroupMember 'Remote Desktop Users'|%{$_.Name}
'--- Signed-in sessions ---';query user 2>&1
'--- Auto-logon ---';$w=Get-ItemProperty 'HKLM:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon';"AutoAdminLogon=$($w.AutoAdminLogon) DefaultUser=$($w.DefaultUserName) PasswordStoredInRegistry=$([bool]$w.DefaultPassword)"
'''),
  ScanCheck('events', 'Event logs: failed sign-ins, cleared logs, new accounts, Defender, PowerShell', ScanCategory.accounts, r'''
$s=(Get-Date).AddDays(-14)
$f=@(Get-WinEvent -FilterHashtable @{LogName='Security';Id=4625;StartTime=$s} -MaxEvents 2000)
"Failed sign-ins in 14 days: $($f.Count) (reading the Security log needs administrator rights; 0 may mean no access)"
$f|Group-Object {$_.Properties[19].Value}|Sort-Object Count -Descending|Select-Object -First 8|%{"  from $($_.Name): $($_.Count)"}
"Security log cleared (1102): $(@(Get-WinEvent -FilterHashtable @{LogName='Security';Id=1102} -MaxEvents 5).Count)  System log cleared (104): $(@(Get-WinEvent -FilterHashtable @{LogName='System';Id=104} -MaxEvents 5).Count)"
'--- New accounts / group changes (4720, 4732) ---';Get-WinEvent -FilterHashtable @{LogName='Security';Id=4720,4732;StartTime=$s} -MaxEvents 10|%{"$($_.TimeCreated) id=$($_.Id) $(($_.Message -split "`n")[0])"}
'--- Defender detections (30 days) ---';Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-Windows Defender/Operational';Id=1116,1117,5007;StartTime=(Get-Date).AddDays(-30)} -MaxEvents 15|%{"$($_.TimeCreated) id=$($_.Id) $((($_.Message -split "`n")[0..2]) -join ' ')"}
'--- Suspicious PowerShell script blocks (4104, 14 days) ---';Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-PowerShell/Operational';Id=4104;StartTime=$s} -MaxEvents 300|?{$_.Message -match '(?i)downloadstring|frombase64|invoke-mimikatz|\biex\b'}|Select-Object -First 5|%{"$($_.TimeCreated) "+$_.Message.Substring(0,[Math]::Min(200,$_.Message.Length))}
'(done)'
''', timeoutSec: 120),
  ScanCheck('software', 'Installed software, newest first, remote-access and mining tools', ScanCategory.accounts, r'''
$k='HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
$a=@(Get-ItemProperty $k|?{$_.DisplayName}|Sort-Object InstallDate -Descending)
"Installed programs: $($a.Count) (newest first)"
$a|Select-Object -First 60|%{"{0,-9} {1} {2} [{3}]" -f $_.InstallDate,$_.DisplayName,$_.DisplayVersion,$_.Publisher}
'--- Remote-access, hacking or mining tools by name ---'
$a|?{$_.DisplayName -match '(?i)anydesk|teamviewer|ultravnc|tightvnc|realvnc|rustdesk|ngrok|chrome remote|logmein|splashtop|radmin|ammyy|supremo|netcat|nmap|wireshark|xmrig|miner|nicehash|cheat engine|keylog|crack|keygen|activator|hamachi|zerotier|tailscale|psexec'}|%{"FOUND: $($_.DisplayName) $($_.DisplayVersion) [$($_.Publisher)]"}
'(done)'
'''),
  ScanCheck('browser_ext', 'Browser extensions', ScanCategory.accounts, r'''
$roots=@{Chrome="$env:LOCALAPPDATA\Google\Chrome\User Data";Edge="$env:LOCALAPPDATA\Microsoft\Edge\User Data";Brave="$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data"}
foreach($b in $roots.Keys){Get-ChildItem "$($roots[$b])\*\Extensions\*\*\manifest.json" -Force|%{$m=Get-Content $_.FullName -Raw|ConvertFrom-Json;$perm=($m.permissions|Select-Object -First 8) -join ',';"{0} | {1} v{2} | id={3} | perms={4}" -f $b,$m.name,$m.version,$_.Directory.Parent.Name,$perm}}
'--- Firefox ---'
Get-ChildItem "$env:APPDATA\Mozilla\Firefox\Profiles\*\extensions" -Force|%{$_.FullName}
'(done)'
'''),

  // ── memory ──
  ScanCheck('ram_overview', 'RAM: totals, commit, pools, pagefile, modules, hardware errors', ScanCategory.ram, r'''
$o=Get-CimInstance Win32_OperatingSystem
$tot=$o.TotalVisibleMemorySize/1MB;$free=$o.FreePhysicalMemory/1MB
"Physical: total={0:N2} GB free={1:N2} GB used={2:N0}%" -f $tot,$free,(100*(1-$free/$tot))
"Virtual (commit): total={0:N2} GB free={1:N2} GB used={2:N0}%" -f ($o.TotalVirtualMemorySize/1MB),($o.FreeVirtualMemory/1MB),(100*(1-$o.FreeVirtualMemory/$o.TotalVirtualMemorySize))
$m=Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
"AvailableMB=$($m.AvailableMBytes) PagesPerSec=$($m.PagesPersec)"
"CommittedGB={0:N2} CommitLimitGB={1:N2} CacheGB={2:N2} PoolPagedMB={3:N0} PoolNonpagedMB={4:N0} ModifiedMB={5:N0}" -f ($m.CommittedBytes/1GB),($m.CommitLimit/1GB),($m.CacheBytes/1GB),($m.PoolPagedBytes/1MB),($m.PoolNonpagedBytes/1MB),($m.ModifiedPageListBytes/1MB)
Get-CimInstance Win32_PageFileUsage|%{"Pagefile $($_.Name): size=$($_.AllocatedBaseSize)MB used=$($_.CurrentUsage)MB peak=$($_.PeakUsage)MB"}
'--- RAM modules ---'
Get-CimInstance Win32_PhysicalMemory|%{"{0} {1:N0} GB {2} MHz (configured {3}) {4} {5}" -f $_.DeviceLocator,($_.Capacity/1GB),$_.Speed,$_.ConfiguredClockSpeed,$_.Manufacturer,$_.PartNumber}
'--- Memory hardware / crash events (90 days) ---'
Get-WinEvent -FilterHashtable @{LogName='System';ProviderName='Microsoft-Windows-WHEA-Logger';StartTime=(Get-Date).AddDays(-90)} -MaxEvents 10|%{"WHEA $($_.TimeCreated) id=$($_.Id) $(($_.Message -split "`n")[0])"}
Get-WinEvent -FilterHashtable @{LogName='System';ProviderName='Microsoft-Windows-MemoryDiagnostics-Results'} -MaxEvents 5|%{"MemoryDiagnostic $($_.TimeCreated) $($_.Message)"}
Get-WinEvent -FilterHashtable @{LogName='System';Id=41,1001;StartTime=(Get-Date).AddDays(-60)} -MaxEvents 10|%{"$($_.TimeCreated) id=$($_.Id) $($_.ProviderName)"}
'(done)'
'''),
  ScanCheck('ram_top', 'RAM: the programs using the most memory', ScanCategory.ram, r'''
$ps=Get-Process
'--- Top 25 processes by working set ---'
$ps|Sort-Object WorkingSet64 -Descending|Select-Object -First 25|%{"{0,6} {1,-24} WS={2,6} MB  Private={3,6} MB  Handles={4,6} Threads={5,4} Started={6}" -f $_.Id,$_.ProcessName,[int]($_.WorkingSet64/1MB),[int]($_.PrivateMemorySize64/1MB),$_.Handles,$_.Threads.Count,$_.StartTime}
'--- Total per program name (all copies together) ---'
$ps|Group-Object ProcessName|%{[pscustomobject]@{Name=$_.Name;Count=$_.Count;WS_MB=[int](($_.Group|Measure-Object WorkingSet64 -Sum).Sum/1MB);Private_MB=[int](($_.Group|Measure-Object PrivateMemorySize64 -Sum).Sum/1MB)}}|Sort-Object WS_MB -Descending|Select-Object -First 15|%{"{0,-24} copies={1,3} WS={2,6} MB Private={3,6} MB" -f $_.Name,$_.Count,$_.WS_MB,$_.Private_MB}
"Sum of all working sets: $([int](($ps|Measure-Object WorkingSet64 -Sum).Sum/1MB)) MB"
'--- Most handles ---'
$ps|Sort-Object Handles -Descending|Select-Object -First 8|%{"{0,6} {1,-24} handles={2}" -f $_.Id,$_.ProcessName,$_.Handles}
'''),
  ScanCheck('ram_growth', 'RAM: which program is growing right now (24 s window)', ScanCategory.ram, r'''
function S{$h=@{};Get-Process|%{$h[$_.Id]=[pscustomobject]@{N=$_.ProcessName;P=$_.PrivateMemorySize64;H=$_.Handles}};$h}
$a=S;Start-Sleep 12;$b=S;Start-Sleep 12;$c=S
'Sampled at 0 s, 12 s and 24 s (private memory)'
$rows=foreach($id in $c.Keys){if($a[$id] -and $b[$id]){[pscustomobject]@{Id=$id;Name=$c[$id].N;Now=[math]::Round($c[$id].P/1MB);Step1=[math]::Round(($b[$id].P-$a[$id].P)/1MB,1);Step2=[math]::Round(($c[$id].P-$b[$id].P)/1MB,1);Total=[math]::Round(($c[$id].P-$a[$id].P)/1MB,1);HandlesDelta=($c[$id].H-$a[$id].H)}}}
'--- Fastest growth (MB) ---'
$rows|Sort-Object Total -Descending|Select-Object -First 12|%{"{0,6} {1,-24} now={2,6} MB  +{3} MB (0-12s) +{4} MB (12-24s)  total +{5} MB  handles {6:+#;-#;0}" -f $_.Id,$_.Name,$_.Now,$_.Step1,$_.Step2,$_.Total,$_.HandlesDelta}
'--- Biggest handle growth ---'
$rows|Sort-Object HandlesDelta -Descending|Select-Object -First 6|%{"{0,6} {1,-24} handles {2:+#;-#;0}" -f $_.Id,$_.Name,$_.HandlesDelta}
'--- Programs that started during the window ---'
foreach($id in $c.Keys){if(-not $a[$id]){"new: $id $($c[$id].N) $([math]::Round($c[$id].P/1MB)) MB"}}
'(done)'
''', timeoutSec: 100),
  ScanCheck('ram_growth_long', 'RAM: slow leaks (3 minute window)', ScanCategory.ram, r'''
function S{$h=@{};Get-Process|%{$h[$_.Id]=[pscustomobject]@{N=$_.ProcessName;P=$_.PrivateMemorySize64;H=$_.Handles}};$h}
$a=S;Start-Sleep 90;$b=S;Start-Sleep 90;$c=S
'Sampled at 0, 90 and 180 s (private memory)'
$rows=foreach($id in $c.Keys){if($a[$id] -and $b[$id]){[pscustomobject]@{Id=$id;Name=$c[$id].N;Now=[math]::Round($c[$id].P/1MB);Step1=[math]::Round(($b[$id].P-$a[$id].P)/1MB,1);Step2=[math]::Round(($c[$id].P-$b[$id].P)/1MB,1);Total=[math]::Round(($c[$id].P-$a[$id].P)/1MB,1);HandlesDelta=($c[$id].H-$a[$id].H)}}}
'--- Growth over 3 minutes (steady growth in both steps points to a leak) ---'
$rows|Sort-Object Total -Descending|Select-Object -First 12|%{"{0,6} {1,-24} now={2,6} MB  +{3} (0-90s) +{4} (90-180s)  total +{5} MB  handles {6:+#;-#;0}" -f $_.Id,$_.Name,$_.Now,$_.Step1,$_.Step2,$_.Total,$_.HandlesDelta}
'(done)'
''', timeoutSec: 240, slow: true),
  ScanCheck('ram_history', 'RAM: what Windows recorded about earlier memory spikes and crashes', ScanCategory.ram, r'''
'--- Windows low-memory diagnoses (Resource-Exhaustion-Detector 2004, 60 days) — lists the programs using most at that moment ---'
Get-WinEvent -FilterHashtable @{LogName='System';ProviderName='Microsoft-Windows-Resource-Exhaustion-Detector';Id=2004;StartTime=(Get-Date).AddDays(-60)} -MaxEvents 6|%{"$($_.TimeCreated)`n$($_.Message)"}
'--- Applications that crashed most (Application 1000, 14 days) ---'
Get-WinEvent -FilterHashtable @{LogName='Application';Id=1000;StartTime=(Get-Date).AddDays(-14)} -MaxEvents 400|Group-Object {$_.Properties[0].Value}|Sort-Object Count -Descending|Select-Object -First 10|%{"$($_.Count) x $($_.Name)"}
'--- Programs started in the last 2 hours (largest first) ---'
Get-Process|?{$_.StartTime -gt (Get-Date).AddHours(-2)}|Sort-Object PrivateMemorySize64 -Descending|Select-Object -First 15|%{"{0:HH:mm} {1,6} {2,-24} Private={3} MB" -f $_.StartTime,$_.Id,$_.ProcessName,[int]($_.PrivateMemorySize64/1MB)}
'--- Uptime ---'
$b=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime;"Last boot: $b  up for $([int]((Get-Date)-$b).TotalHours) hours (a PC left on for days collects leaks)"
'(done)'
'''),
  ScanCheck('ram_pool', 'RAM: kernel pool and memory no program owns (drivers, VMs, RAM disks)', ScanCategory.ram, r'''
$o=Get-CimInstance Win32_OperatingSystem;$used=($o.TotalVisibleMemorySize-$o.FreePhysicalMemory)/1MB
$ws=(Get-Process|Measure-Object WorkingSet64 -Sum).Sum/1GB
$m=Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
"In use={0:N2} GB; all program working sets={1:N2} GB; not owned by a program (kernel, drivers, cache)={2:N2} GB" -f $used,$ws,($used-$ws)
"Kernel pools: nonpaged={0:N0} MB paged={1:N0} MB (nonpaged over ~1000 MB, or growing, suggests a leaking driver)" -f ($m.PoolNonpagedBytes/1MB),($m.PoolPagedBytes/1MB)
$pp=Get-CimInstance Win32_PerfFormattedData_PerfProc_Process|?{$_.Name -ne '_Total' -and $_.Name -ne 'Idle'}
'--- Top programs by nonpaged pool ---'
$pp|Sort-Object PoolNonpagedBytes -Descending|Select-Object -First 8|%{"{0,-26} pid={1,-6} nonpaged={2} MB paged={3} MB handles={4}" -f $_.Name,$_.IDProcess,[math]::Round($_.PoolNonpagedBytes/1MB,2),[math]::Round($_.PoolPagedBytes/1MB,2),$_.HandleCount}
'--- Virtual machines, WSL, memory-compression and known big consumers ---'
Get-Process vmmem*,Memory*,MsMpEng,SearchIndexer,vmcompute,vmwp -ErrorAction SilentlyContinue|%{"{0,-20} {1} MB" -f $_.ProcessName,[int]($_.WorkingSet64/1MB)}
'(done)'
'''),
  ScanCheck('ram_services', 'RAM: which services sit inside the biggest svchost processes', ScanCategory.ram, r'''
$sv=Get-CimInstance Win32_Service|?{$_.ProcessId -gt 0}|Group-Object ProcessId
foreach($p in (Get-Process|Sort-Object WorkingSet64 -Descending|Select-Object -First 12)){$g=$sv|?{$_.Name -eq "$($p.Id)"};$names=if($g){($g.Group.Name) -join ','}else{''};"{0,6} {1,-22} {2,6} MB  services: {3}" -f $p.Id,$p.ProcessName,[int]($p.WorkingSet64/1MB),$names}
'--- Store (UWP) apps using memory ---'
Get-Process|?{$_.Path -match 'WindowsApps'}|Sort-Object WorkingSet64 -Descending|Select-Object -First 8|%{"$($_.ProcessName) $([int]($_.WorkingSet64/1MB)) MB"}
'(done)'
'''),
];

ScanCheck? scanCheckById(String id) {
  for (final c in kScanChecks) {
    if (c.id == id) return c;
  }
  return null;
}

// ───────────────────────────── the connection ─────────────────────────────

/// How to reach the PC: everything after `ssh`, split into the options and the destination.
class SshTarget {
  const SshTarget({required this.destination, this.port = 22, this.identity = '', this.password = '', this.source = ''});

  /// `user@host`, or a Host alias from ~/.ssh/config.
  final String destination;
  final int port;

  /// Path of a private key (in Termux), when one is named.
  final String identity;

  /// Only for a host the person saved in the app with a password.
  final String password;

  /// Where it was found (for the report): a running session, ssh config, history, saved host…
  final String source;

  String get key => '$destination:$port';

  String get label => port == 22 ? destination : '$destination:$port';

  /// Options that make the connection safe to run unattended and cheap to repeat (one connection is shared by
  /// the parallel commands, so ten workers do not mean ten logins).
  String get options {
    final b = StringBuffer('-o BatchMode=${password.isEmpty ? 'yes' : 'no'} -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 '
        '-o StrictHostKeyChecking=accept-new -o ControlMaster=auto -o ControlPersist=300 -o ControlPath=~/.ssh/omni-scan-%C');
    if (port != 22) b.write(' -p $port');
    if (identity.isNotEmpty) b.write(' -i ${shellPath(identity)}');
    return b.toString();
  }

  /// `ssh …` (or `sshpass … ssh …`) up to and including the destination.
  String get prefix {
    final ssh = 'ssh $options ${shellQuote(destination)}';
    return password.isEmpty ? ssh : 'sshpass -p ${shellQuote(password)} $ssh';
  }

  Map<String, dynamic> toJson() => <String, dynamic>{'d': destination, 'p': port, 'i': identity, 's': source};

  static SshTarget? fromSetting(String s) {
    final t = s.trim();
    if (t.isEmpty) return null;
    final parts = t.split('|');
    final d = parts[0].trim();
    if (d.isEmpty) return null;
    return SshTarget(
      destination: d,
      port: parts.length > 1 ? (int.tryParse(parts[1]) ?? 22) : 22,
      identity: parts.length > 2 ? parts[2] : '',
      source: 'remembered',
    );
  }

  String toSetting() => '$destination|$port|$identity';
}

/// Quotes a path but leaves a leading ~/ to the shell so it still means the home folder.
String shellPath(String v) => v.startsWith('~/') ? '~/${shellQuote(v.substring(2))}' : shellQuote(v);

String shellQuote(String v) => "'${v.replaceAll("'", "'\\''")}'";

/// The command that sends [script] to the PC.
String remoteCommand(SshTarget t, String script) =>
    '${t.prefix} powershell -NoProfile -NonInteractive -EncodedCommand ${psEncode(script)}';

/// Looks for the SSH connection the person already has, in everything Termux knows: running ssh processes,
/// ~/.ssh/config, the history, known_hosts.
const String kDiscoveryCommand = r'''
echo "@@SSH_BIN"; command -v ssh || echo missing
echo "@@PROCS"; (ps -A -o ARGS 2>/dev/null || ps -ef 2>/dev/null) | grep -E '(^|[ /])ssh( |$)' | grep -v grep | grep -v omni-scan | head -20
echo "@@CONFIG"; grep -hE '^[[:space:]]*(Host|HostName|User|Port|IdentityFile)[[:space:]]' ~/.ssh/config 2>/dev/null | head -80
echo "@@HISTORY"; grep -hE '(^|[;& ])ssh[[:space:]]' ~/.bash_history ~/.zsh_history 2>/dev/null | tail -30
echo "@@KNOWN"; cut -d' ' -f1 ~/.ssh/known_hosts 2>/dev/null | head -20
echo "@@KEYS"; ls ~/.ssh 2>/dev/null | head -30
echo "@@END"
''';

const Set<String> _sshArgOptions = <String>{'-p', '-i', '-l', '-o', '-F', '-J', '-L', '-R', '-D', '-b', '-c', '-m', '-S', '-W', '-w', '-E', '-I', '-B', '-O', '-Q', '-e'};

/// A target from one `ssh …` command line, or null when it has none.
SshTarget? parseSshCommandLine(String line, {String source = ''}) {
  final at = RegExp(r'(^|[\s/;&|])ssh\s+(.*)$').firstMatch(line.trim());
  if (at == null) return null;
  final tokens = at.group(2)!.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
  var port = 22;
  var identity = '';
  var user = '';
  String? dest;
  for (var i = 0; i < tokens.length; i++) {
    final t = tokens[i];
    if (t.startsWith('-')) {
      if (t == '-p' && i + 1 < tokens.length) {
        port = int.tryParse(tokens[++i]) ?? 22;
      } else if (t.startsWith('-p') && t.length > 2 && int.tryParse(t.substring(2)) != null) {
        port = int.parse(t.substring(2));
      } else if (t == '-i' && i + 1 < tokens.length) {
        identity = tokens[++i].replaceAll(RegExp('^[\'"]|[\'"]\$'), '');
      } else if (t == '-l' && i + 1 < tokens.length) {
        user = tokens[++i];
      } else if (_sshArgOptions.contains(t)) {
        i++;
      }
      continue;
    }
    dest = t.replaceAll(RegExp('^[\'"]|[\'"]\$'), '');
    break;
  }
  if (dest == null || dest.isEmpty || dest.contains('*') || dest.startsWith('~') || dest.contains('/') || dest.contains('=')) return null;
  if (!dest.contains('@') && user.isNotEmpty) dest = '$user@$dest';
  return SshTarget(destination: dest, port: port, identity: identity, source: source);
}

/// The candidates in a discovery output, best first, without duplicates.
List<SshTarget> parseDiscovery(String output) {
  final sections = <String, List<String>>{};
  String? cur;
  for (final raw in output.split('\n')) {
    final line = raw.trimRight();
    if (line.startsWith('@@')) {
      cur = line.substring(2);
      sections[cur] = <String>[];
    } else if (cur != null) {
      sections[cur]!.add(line);
    }
  }
  final out = <SshTarget>[];
  final seen = <String>{};
  void add(SshTarget? t) {
    if (t == null || !seen.add(t.key)) return;
    out.add(t);
  }

  for (final l in sections['PROCS'] ?? const <String>[]) {
    add(parseSshCommandLine(l, source: 'a running ssh session'));
  }
  // ~/.ssh/config: a block per Host.
  String? alias;
  var host = '';
  var user = '';
  var port = 22;
  void flush() {
    final dest = alias;
    if (dest == null || dest.contains('*') || dest.contains('?')) return;
    add(SshTarget(destination: dest, port: 22, identity: '', source: 'ssh config (Host $alias${host.isEmpty ? '' : ' → $host'}${user.isEmpty ? '' : ', user $user'}${port == 22 ? '' : ', port $port'})'));
  }

  for (final l in sections['CONFIG'] ?? const <String>[]) {
    final m = RegExp(r'^\s*(\w+)\s+(.+?)\s*$').firstMatch(l);
    if (m == null) continue;
    final k = m.group(1)!.toLowerCase();
    final v = m.group(2)!;
    if (k == 'host') {
      flush();
      alias = v.split(RegExp(r'\s+')).first;
      host = '';
      user = '';
      port = 22;
    } else if (k == 'hostname') {
      host = v;
    } else if (k == 'user') {
      user = v;
    } else if (k == 'port') {
      port = int.tryParse(v) ?? 22;
    }
  }
  flush();
  for (final l in (sections['HISTORY'] ?? const <String>[]).reversed) {
    add(parseSshCommandLine(l, source: 'your command history'));
  }
  for (final l in sections['KNOWN'] ?? const <String>[]) {
    final first = l.trim().split(RegExp(r'\s+')).first.split(',').first.trim();
    if (first.isEmpty || first.startsWith('|')) continue;
    final m = RegExp(r'^\[(.+)\]:(\d+)$').firstMatch(first);
    if (m != null) {
      add(SshTarget(destination: m.group(1)!, port: int.tryParse(m.group(2)!) ?? 22, source: 'known_hosts'));
    } else if (!first.contains('*')) {
      add(SshTarget(destination: first, source: 'known_hosts'));
    }
  }
  return out;
}

bool sshMissing(String discoveryOutput) {
  final m = RegExp(r'@@SSH_BIN\s*\n([^\n]*)').firstMatch(discoveryOutput);
  return m == null ? false : m.group(1)!.trim() == 'missing';
}

/// A short, plain reason from ssh's own error text.
String explainSshFailure(String text) {
  final t = text.toLowerCase();
  if (t.contains('permission denied') || t.contains('authentication failed')) {
    return 'The PC refused the login: ssh needs a key (or saved password) that works without typing anything. A session where you typed the password cannot be reused.';
  }
  if (t.contains('connection refused')) return 'The PC refused the connection: the OpenSSH Server service may be stopped, or the port is different.';
  if (t.contains('timed out') || t.contains('timeout')) return 'The PC did not answer in time: it may be asleep, off the network, or behind a firewall.';
  if (t.contains('could not resolve') || t.contains('name or service not known')) return 'The address could not be found: check the host name or IP.';
  if (t.contains('no route to host') || t.contains('network is unreachable')) return 'There is no route to the PC from this phone (different network or VPN?).';
  if (t.contains('host key verification failed') || t.contains('remote host identification has changed')) {
    return 'The PC\'s stored host key no longer matches (it was reinstalled, or this is a different machine).';
  }
  if (t.contains('connection closed') || t.contains('connection reset')) return 'The PC closed the connection (a limit on simultaneous sessions, or the service restarted).';
  if (t.contains('is not recognized') || t.contains('powershell')) return 'The PC answered but PowerShell did not run (is it a Windows PC?).';
  return '';
}

/// The command that proves a target is a Windows PC the scan can use.
const String kProbeScript = r"Write-Output ('OMNI_WIN '+$env:COMPUTERNAME+' PS'+$PSVersionTable.PSVersion)";

/// The computer name and PowerShell version from a probe answer, or null when it did not come from Windows.
({String name, String ps})? parseProbe(String output) {
  final m = RegExp(r'OMNI_WIN\s+(\S+)\s+PS(\S+)').firstMatch(output);
  return m == null ? null : (name: m.group(1)!, ps: m.group(2)!);
}

// ───────────────────────────── output handling ─────────────────────────────

/// Removes the progress/CLIXML noise PowerShell prints to stderr when it runs without a console.
String cleanPowerShellOutput(String s) {
  var t = s.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final i = t.indexOf('#< CLIXML');
  if (i >= 0) t = t.substring(0, i);
  t = t.replaceAll(RegExp(r'Warning: Permanently added[^\n]*\n?'), '');
  return t.trim();
}

class ScanResult {
  ScanResult(this.check, {this.output = '', this.error = '', this.seconds = 0, this.attempts = 1});

  final ScanCheck check;
  final String output;
  final String error;
  final int seconds;
  final int attempts;

  bool get ok => error.isEmpty;
}

/// Lines the scripts print when something specific was spotted; counted up front so the report starts from
/// what is most likely to matter.
const List<(String, String)> kScanMarkers = <(String, String)>[
  ('WRONG PATH:', 'A system-named process runs from the wrong folder'),
  ('ODD PARENT:', 'A core Windows process has an unexpected parent'),
  ('LOOKALIKE NAME:', 'A process has a name made to look like a system one'),
  ('svchost without -k', 'svchost started without its service group'),
  ('FOUND:', 'Remote-access, hacking or mining software is installed'),
  ('IFEO Debugger:', 'Image File Execution Options debugger hijack'),
  ('SilentProcessExit:', 'SilentProcessExit entries'),
  ('NotSigned', 'Running programs with no signature'),
  ('HashMismatch', 'Running programs whose signature does not match the file'),
  ('UnknownError', 'Signature check errors'),
];

String triage(List<ScanResult> results) {
  final b = StringBuffer();
  for (final (marker, why) in kScanMarkers) {
    var n = 0;
    final where = <String>{};
    for (final r in results) {
      final c = marker.allMatches(r.output).length;
      if (c > 0) {
        n += c;
        where.add(r.check.id);
      }
    }
    if (n > 0) b.writeln('- $why: $n line${n == 1 ? '' : 's'} (in ${where.join(', ')})');
  }
  return b.isEmpty ? '(the scripts raised no specific markers; judge from the raw output)' : b.toString().trim();
}

/// All evidence as one text within [budget] characters: each check keeps its start, and the biggest ones are
/// shortened first so that no single check crowds out the rest.
String buildEvidence(List<ScanResult> results, {int budget = 90000}) {
  final texts = <ScanResult, String>{};
  for (final r in results) {
    texts[r] = r.ok ? (r.output.trim().isEmpty ? '(no output: nothing found)' : r.output.trim()) : 'FAILED: ${r.error}${r.output.trim().isEmpty ? '' : '\n${r.output.trim()}'}';
  }
  final total = texts.values.fold<int>(0, (a, t) => a + t.length + 80);
  if (total > budget) {
    final per = (budget / results.length).floor() - 80;
    for (final r in results) {
      final t = texts[r]!;
      final cap = per < 1500 ? 1500 : per;
      if (t.length > cap) texts[r] = '${t.substring(0, cap)}\n…(cut: ${t.length - cap} more characters)';
    }
  }
  final b = StringBuffer();
  ScanCategory? last;
  for (final r in results) {
    if (r.check.category != last) {
      last = r.check.category;
      b
        ..writeln()
        ..writeln('######## ${scanCategoryLabel(last).toUpperCase()} ########');
    }
    b
      ..writeln()
      ..writeln('=== ${r.check.title} [${r.check.id}] ${r.ok ? '' : '— FAILED '}(${r.seconds}s) ===')
      ..writeln(texts[r]);
  }
  return b.toString().trim();
}

// ───────────────────────────── the approval guard ─────────────────────────────

final RegExp _remoteChange = RegExp(
  r'\b(Remove-Item|Remove-ItemProperty|Set-ItemProperty|New-ItemProperty|Move-Item|Rename-Item|Stop-Process|Stop-Service|Start-Service|Restart-Service|Set-Service|Remove-Service|'
  r'Disable-ScheduledTask|Unregister-ScheduledTask|Register-ScheduledTask|Set-MpPreference|Add-MpPreference|Remove-MpPreference|Remove-MpThreat|Start-MpScan|'
  r'Remove-LocalUser|Disable-LocalUser|Set-LocalUser|Remove-LocalGroupMember|Add-LocalGroupMember|Clear-EventLog|Limit-EventLog|Restart-Computer|Stop-Computer|Format-Volume|Clear-RecycleBin|'
  r'Set-NetFirewallRule|New-NetFirewallRule|Disable-NetFirewallRule|Remove-NetFirewallRule|Disable-WindowsOptionalFeature|Uninstall-Package|Uninstall-Module|Set-ExecutionPolicy|'
  r'wevtutil\s+cl|del|erase|rmdir|rd|taskkill|shutdown|sc\s+(delete|stop|config|start)|schtasks\s+/(delete|change|end|create)|reg\s+(delete|add|import)|'
  r'netsh\s+[^|;]*\b(delete|add|set)\b|wmic\s+[^|;]*\b(delete|call)\b|net\s+user\s+\S+\s+/(delete|active:no)|net\s+localgroup|cipher\s+/w|attrib\s+[^|;]*[+-][hrs])\b',
  caseSensitive: false,
);

/// Every PowerShell script sent with -EncodedCommand in [command], decoded.
List<String> decodedScripts(String command) {
  final out = <String>[];
  for (final m in RegExp(r'-(?:e|ec|enc|encodedcommand)\s+([A-Za-z0-9+/=]{8,})', caseSensitive: false).allMatches(command)) {
    final d = psDecode(m.group(1)!);
    if (d.isNotEmpty) out.add(d);
  }
  return out;
}

/// True when [command] sends something over ssh/scp that would CHANGE a PC (delete, stop, disable, edit the
/// registry, move files…). The scan itself never does. A command like that always waits for the person.
bool isRemoteChange(String command) {
  if (!RegExp(r'(^|[\s;&|(])(ssh|sshpass|scp|sftp|plink)\b').hasMatch(command)) return false;
  final texts = <String>[command, ...decodedScripts(command)];
  for (final t in texts) {
    // The scan's own scripts are all read-only; a Get-… script never trips this because it names no changing verb.
    if (_remoteChange.hasMatch(t)) return true;
  }
  return false;
}

/// The text shown to the person when a change waits for approval: what will run, decoded.
String describeRemoteChange(String command) {
  final scripts = decodedScripts(command);
  var body = scripts.isNotEmpty ? scripts.map((s) => s.replaceFirst(kPsPrelude, '')).join('\n---\n') : command;
  body = body.trim();
  if (body.length > 1400) body = '${body.substring(0, 1400)}…';
  return body;
}

/// Seconds as 1m 05s.
String clockLabel(int seconds) => seconds >= 60 ? '${seconds ~/ 60}m ${(seconds % 60).toString().padLeft(2, '0')}s' : '${seconds}s';

// ───────────────────────────── the report request ─────────────────────────────

/// What the main assistant is told to do with the evidence. The app has already done the scanning; the model
/// reads and judges, and may run extra READ-ONLY checks, but changes nothing without the person's approval.
String buildReportRequest({required String evidence, required String triageText, required SshTarget target, required String machine, required int workers, required int seconds, required int failed}) {
  return '''[Full Windows scan — the app has already run it. Do not run it again.]
The app connected to the person's Windows PC "$machine" over SSH (${target.label}) and ran ${kScanChecks.length} read-only PowerShell checks with $workers parallel workers in ${clockLabel(seconds)}${failed > 0 ? ' ($failed of them failed — say so in the report)' : ''}. Nothing on the PC was changed. The raw output follows.

YOUR JOB
1. Write ONE comprehensive, well-organized report from this evidence, in the person's language (Arabic) keeping command, file and program names in English. Do not repeat the raw output; interpret it.
2. Start with a verdict in 2–3 lines (clean / needs attention / likely compromised) and a risk table: finding, severity (Critical / High / Medium / Low / Info), evidence (the exact process, path, key or line), and why it matters. Rank by severity. Say plainly what looks NORMAL so the person is not scared by common software.
3. Cover every area: processes and signatures, persistence (Run keys, tasks, services, WMI, drivers), network (listening ports, outgoing connections and the program behind each), files, accounts and logs, installed software, antivirus status and exclusions.
4. RAM section: current use and health (commit, pools, pagefile, modules, hardware-error events); the programs using the most; which program is GROWING or leaking (use the 24-second and 3-minute growth tables, handle growth, kernel pool, memory not owned by any program, and the Windows low-memory events); name the most likely culprit with numbers and what to do about it. If the evidence does not show a leak, say so instead of guessing.
5. Be honest about limits: these are read-only checks from a remote session. A scan like this cannot prove a PC is clean, and a hidden rootkit may not show in it; if a check failed or needed administrator rights (the sysinfo check says whether the session is admin), say which findings that affects. Do not call something malware without evidence; call it "suspicious" and say what would confirm it. Recommend a Microsoft Defender Offline scan for anything serious.
6. You may run extra READ-ONLY checks to look closer at something suspicious (for example a file hash or signature) with termux_run through ssh and the same powershell -EncodedCommand method, but only reading.
7. End with "Proposed cleanup": a numbered list of exact actions (what, where, how to undo it) ordered by importance, each tied to a finding. Do NOT carry out any of them. Then ask the person which numbers to approve and STOP. Make no change to the PC — no deleting, stopping, disabling, editing, moving, killing, uninstalling — until the person replies approving specific numbers. When they do, do those only, one at a time, and the app will also ask them to confirm each change. If a file is to be removed, prefer moving it to a quarantine folder first.

WHAT THE SCRIPTS SPOTTED (counts of marker lines)
$triageText

EVIDENCE
$evidence''';
}

