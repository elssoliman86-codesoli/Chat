/// Step-by-step guides for turning on and using SSH and FTP on the systems people actually have.
/// Pure data, so the screen stays simple and the content can be tested.

class GuideStep {
  const GuideStep(this.text, {this.command});

  /// What to do, in plain words.
  final String text;

  /// The exact thing to type, shown in a copyable box.
  final String? command;
}

class GuideSection {
  const GuideSection(this.title, this.steps);

  final String title;
  final List<GuideStep> steps;
}

class Guide {
  const Guide({required this.id, required this.title, required this.subtitle, required this.intro, required this.sections});

  final String id;
  final String title;
  final String subtitle;
  final String intro;
  final List<GuideSection> sections;
}

const GuideSection _connectFromApp = GuideSection('Use it from Omni Chat', [
  GuideStep('Make sure the phone and that computer are on the same Wi-Fi (or reach each other some other way, such as a VPN).'),
  GuideStep('In Omni Chat open Plugins, scroll to the SSH hosts and tap "Add SSH host". Type a name, the computer\'s IP address from the steps above, '
      'its port (22 unless you changed it) and the username.'),
  GuideStep('Choose Key or Password. With Key, the app makes a key on the phone and shows you the public key to copy to the computer; with Password, '
      'you type it when asked. Nothing connects on its own — only to hosts you added.'),
  GuideStep('Ask the assistant to run something on that host. The first connection asks you to trust the computer\'s fingerprint — that is expected.'),
]);

const GuideSection _appFtp = GuideSection('Reach this phone\'s FTP server from the computer', [
  GuideStep('In Omni Chat open Plugins, turn on "Run FTP server" and note the address it shows, like ftp://192.168.1.20:2121. '
      'Turn it off when you are done: it gives read/write access to your Projects folder to anything on the Wi-Fi.'),
]);

final List<Guide> sshGuides = <Guide>[
  Guide(
    id: 'powershell',
    title: 'Windows PowerShell',
    subtitle: 'SSH server, SFTP and FTP on Windows 10 / 11',
    intro: 'Open PowerShell as Administrator: press Start, type PowerShell, right-click it and choose "Run as administrator". '
        'Each box below is one command — copy it, paste it, press Enter.',
    sections: <GuideSection>[
      const GuideSection('1. Turn on the SSH server', [
        GuideStep('Check whether OpenSSH Server is already installed (look for State : Installed).',
            command: r"Get-WindowsCapability -Online | Where-Object Name -like 'OpenSSH.Server*'"),
        GuideStep('Install it if it says NotPresent.', command: r'Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0'),
        GuideStep('Start the service now.', command: r'Start-Service sshd'),
        GuideStep('Make it start by itself every time Windows boots.', command: r"Set-Service -Name sshd -StartupType 'Automatic'"),
        GuideStep('Open the firewall for port 22 (the installer usually does this; this makes sure).',
            command: r"if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) { New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 }"),
        GuideStep('Optional: make PowerShell (not Command Prompt) the shell people land in.',
            command: r'New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -PropertyType String -Force'),
      ]),
      const GuideSection('2. Find what to type on the phone', [
        GuideStep('Your username:', command: r'whoami'),
        GuideStep('Your IP address — use the IPv4 one of your Wi-Fi or Ethernet adapter (for example 192.168.1.15).',
            command: r"Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } | Select-Object InterfaceAlias, IPAddress"),
        GuideStep('Test from another device: ssh YOUR-USERNAME@YOUR-IP, then type your Windows password.', command: r'ssh YOUR-USERNAME@YOUR-IP'),
      ]),
      const GuideSection('3. Log in with a key instead of a password (recommended)', [
        GuideStep('Make a key on the device you connect FROM, if it has none (press Enter at every question).', command: r'ssh-keygen -t ed25519'),
        GuideStep('Normal account: append the public key (the .pub file) to this file on the Windows PC.',
            command: r'notepad $env:USERPROFILE\.ssh\authorized_keys'),
        GuideStep('Administrator account: Windows reads a different file, and it must have strict permissions.',
            command: r'notepad $env:ProgramData\ssh\administrators_authorized_keys'),
        GuideStep('Then lock that file down so sshd accepts it.',
            command: r'icacls.exe "$env:ProgramData\ssh\administrators_authorized_keys" /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F"'),
      ]),
      const GuideSection('4. FTP and file transfer', [
        GuideStep('Easiest and safest: SFTP comes with the SSH server you just turned on. From another device: sftp YOUR-USERNAME@YOUR-IP.',
            command: r'sftp YOUR-USERNAME@YOUR-IP'),
        GuideStep('If you really need plain FTP, install the IIS FTP server (Windows 10/11 Pro).',
            command: r'Enable-WindowsOptionalFeature -Online -FeatureName IIS-WebServerRole, IIS-FTPServer, IIS-ManagementConsole -All'),
        GuideStep('Then open "Internet Information Services (IIS) Manager", right-click Sites > Add FTP Site, pick a folder, port 21, and set the login. '
            'Allow it in the firewall:',
            command: r'New-NetFirewallRule -DisplayName "FTP 21" -Direction Inbound -Protocol TCP -LocalPort 21 -Action Allow'),
        GuideStep('To open the phone\'s FTP server from this PC (see the last section), paste its address into File Explorer, or use:',
            command: r'explorer ftp://PHONE-IP:2121'),
      ]),
      _appFtp,
      _connectFromApp,
      const GuideSection('If it does not work', [
        GuideStep('Is the service running? It should say Running.', command: r'Get-Service sshd'),
        GuideStep('Is something listening on port 22?', command: r'netstat -an | findstr :22'),
        GuideStep('Connection timed out usually means the firewall or a different network; "Permission denied" means the username, password or key is wrong.'),
      ]),
    ],
  ),
  Guide(
    id: 'cmd',
    title: 'Windows Command Prompt (CMD)',
    subtitle: 'The same, with classic commands',
    intro: 'Open Command Prompt as Administrator: press Start, type cmd, right-click "Command Prompt" and choose "Run as administrator".',
    sections: <GuideSection>[
      const GuideSection('1. Turn on the SSH server', [
        GuideStep('Install OpenSSH Server (needs Internet; takes a minute).',
            command: r'dism /Online /Add-Capability /CapabilityName:OpenSSH.Server~~~~0.0.1.0'),
        GuideStep('Start it by itself at every boot.', command: r'sc config sshd start= auto'),
        GuideStep('Start it now.', command: r'net start sshd'),
        GuideStep('Open port 22 in the firewall.',
            command: r'netsh advfirewall firewall add rule name="OpenSSH Server" dir=in action=allow protocol=TCP localport=22'),
      ]),
      const GuideSection('2. Find what to type on the phone', [
        GuideStep('Your username (it is the part after the backslash):', command: r'whoami'),
        GuideStep('Your IP address: look for "IPv4 Address" under your Wi-Fi or Ethernet adapter.', command: r'ipconfig'),
        GuideStep('Test from another device:', command: r'ssh YOUR-USERNAME@YOUR-IP'),
      ]),
      const GuideSection('3. Log in with a key', [
        GuideStep('On the device you connect FROM, make a key (press Enter at the questions) and show the public part.',
            command: r'ssh-keygen -t ed25519'),
        GuideStep('Show the public key so you can copy it:', command: r'type %USERPROFILE%\.ssh\id_ed25519.pub'),
        GuideStep('On the Windows PC (normal account) paste that line into this file; for an administrator account use '
            r'C:\ProgramData\ssh\administrators_authorized_keys instead.',
            command: r'notepad %USERPROFILE%\.ssh\authorized_keys'),
      ]),
      const GuideSection('4. FTP and file transfer', [
        GuideStep('Safest: SFTP works as soon as the SSH server runs.', command: r'sftp YOUR-USERNAME@YOUR-IP'),
        GuideStep('Use this phone\'s FTP server from CMD (its address and port are shown in Plugins):', command: r'ftp PHONE-IP 2121'),
        GuideStep('At the "User" prompt type the username (or "anonymous") and press Enter; useful commands afterwards: dir, cd, get FILE, put FILE, bye.'),
      ]),
      _appFtp,
      _connectFromApp,
      const GuideSection('If it does not work', [
        GuideStep('Is the service running?', command: r'sc query sshd'),
        GuideStep('Is something listening on port 22?', command: r'netstat -an | findstr :22'),
      ]),
    ],
  ),
  Guide(
    id: 'macos',
    title: 'macOS Terminal',
    subtitle: 'Remote Login (SSH + SFTP) on a Mac',
    intro: 'Open Terminal (Applications > Utilities > Terminal, or press Cmd+Space and type Terminal). macOS has no built-in FTP server, '
        'but SFTP comes with Remote Login and is better anyway.',
    sections: <GuideSection>[
      const GuideSection('1. Turn on the SSH server (Remote Login)', [
        GuideStep('With the mouse: System Settings > General > Sharing > turn on "Remote Login". Or from Terminal:',
            command: r'sudo systemsetup -setremotelogin on'),
        GuideStep('If that says it needs Full Disk Access, add Terminal in System Settings > Privacy & Security > Full Disk Access, restart Terminal and run it again.'),
        GuideStep('Check that it is on:', command: r'sudo systemsetup -getremotelogin'),
      ]),
      const GuideSection('2. Find what to type on the phone', [
        GuideStep('Your username:', command: r'whoami'),
        GuideStep('Your IP address on Wi-Fi (use en1 if en0 prints nothing):', command: r'ipconfig getifaddr en0'),
        GuideStep('Test from another device:', command: r'ssh YOUR-USERNAME@YOUR-IP'),
      ]),
      const GuideSection('3. Log in with a key', [
        GuideStep('On the device you connect FROM (press Enter at the questions):', command: r'ssh-keygen -t ed25519'),
        GuideStep('Copy it to the Mac (asks for the Mac password once):', command: r'ssh-copy-id YOUR-USERNAME@YOUR-IP'),
      ]),
      const GuideSection('4. FTP and file transfer', [
        GuideStep('Transfer files with SFTP:', command: r'sftp YOUR-USERNAME@YOUR-IP'),
        GuideStep('Download one file from this phone\'s FTP server (address and port are in Plugins):', command: r'curl -O ftp://PHONE-IP:2121/FILE.txt'),
        GuideStep('Upload a file to it:', command: r'curl -T FILE.txt ftp://PHONE-IP:2121/'),
      ]),
      _appFtp,
      _connectFromApp,
      const GuideSection('If it does not work', [
        GuideStep('Is port 22 open on the Mac?', command: r'sudo lsof -iTCP:22 -sTCP:LISTEN'),
        GuideStep('Check System Settings > Network > Firewall; if it is on, allow "sshd-keygen-wrapper" or turn the firewall off while testing.'),
      ]),
    ],
  ),
  Guide(
    id: 'linux',
    title: 'Linux Terminal',
    subtitle: 'Debian, Fedora, Arch and most others',
    intro: 'Open your terminal. The commands below use sudo, so your account needs administrator rights. '
        'Commands differ slightly between families, so each step gives the one for your system.',
    sections: <GuideSection>[
      const GuideSection('1. Install and start the SSH server', [
        GuideStep('Debian / Mint / Pop!_OS:', command: r'sudo apt update && sudo apt install -y openssh-server'),
        GuideStep('Fedora / RHEL / Rocky / Alma:', command: r'sudo dnf install -y openssh-server'),
        GuideStep('Arch / Manjaro:', command: r'sudo pacman -S openssh'),
        GuideStep('Start it now and at every boot (Debian-family calls the service "ssh", the others "sshd"):',
            command: r'sudo systemctl enable --now ssh || sudo systemctl enable --now sshd'),
        GuideStep('Check that it is running (look for "active (running)"):', command: r'systemctl status ssh --no-pager || systemctl status sshd --no-pager'),
        GuideStep('If a firewall is on, open the port. ufw: sudo ufw allow ssh. firewalld:', command: r'sudo firewall-cmd --permanent --add-service=ssh && sudo firewall-cmd --reload'),
      ]),
      const GuideSection('2. Find what to type on the phone', [
        GuideStep('Your username:', command: r'whoami'),
        GuideStep('Your IP address (the first one is usually right):', command: r'hostname -I'),
        GuideStep('Test from another device:', command: r'ssh YOUR-USERNAME@YOUR-IP'),
      ]),
      const GuideSection('3. Log in with a key', [
        GuideStep('On the device you connect FROM:', command: r'ssh-keygen -t ed25519'),
        GuideStep('Copy it over (asks for the password once):', command: r'ssh-copy-id YOUR-USERNAME@YOUR-IP'),
        GuideStep('Once the key works you can switch passwords off: set "PasswordAuthentication no" in /etc/ssh/sshd_config, then restart the service.',
            command: r'sudoedit /etc/ssh/sshd_config'),
      ]),
      const GuideSection('4. FTP and file transfer', [
        GuideStep('Safest: SFTP works as soon as SSH does.', command: r'sftp YOUR-USERNAME@YOUR-IP'),
        GuideStep('Copy a file without opening a session:', command: r'scp FILE.txt YOUR-USERNAME@YOUR-IP:~/'),
        GuideStep('A quick throw-away FTP server with Python (anyone on the network can write; press Ctrl+C to stop it):',
            command: r'python3 -m pyftpdlib -p 2121 -w'),
        GuideStep('If that says no module named pyftpdlib:', command: r'pip install --user pyftpdlib'),
      ]),
      _appFtp,
      _connectFromApp,
      const GuideSection('If it does not work', [
        GuideStep('Is anything listening on port 22?', command: r'sudo ss -tlnp | grep :22'),
        GuideStep('Read the server\'s own log:', command: r'sudo journalctl -u ssh -u sshd -n 30 --no-pager'),
      ]),
    ],
  ),
  Guide(
    id: 'ubuntu',
    title: 'Ubuntu',
    subtitle: 'OpenSSH, the ufw firewall and vsftpd',
    intro: 'Open a terminal (Ctrl+Alt+T). These steps work on Ubuntu Desktop and Server 20.04 and newer.',
    sections: <GuideSection>[
      const GuideSection('1. Install and start the SSH server', [
        GuideStep('Install it (Ubuntu Server usually has it already).', command: r'sudo apt update && sudo apt install -y openssh-server'),
        GuideStep('Start it now and at every boot.', command: r'sudo systemctl enable --now ssh'),
        GuideStep('Check that it is running (look for "active (running)"):', command: r'sudo systemctl status ssh --no-pager'),
        GuideStep('Allow it through the Ubuntu firewall, then check the firewall state.', command: r'sudo ufw allow ssh'),
        GuideStep('Only if ufw says "inactive" and you want it on (make sure SSH is allowed first, as above):', command: r'sudo ufw enable && sudo ufw status'),
      ]),
      const GuideSection('2. Find what to type on the phone', [
        GuideStep('Your username:', command: r'whoami'),
        GuideStep('Your IP address:', command: r'ip -4 addr show | grep inet'),
        GuideStep('Test from another device:', command: r'ssh YOUR-USERNAME@YOUR-IP'),
      ]),
      const GuideSection('3. Log in with a key', [
        GuideStep('On the device you connect FROM:', command: r'ssh-keygen -t ed25519'),
        GuideStep('Copy it to Ubuntu (asks for the password once):', command: r'ssh-copy-id YOUR-USERNAME@YOUR-IP'),
        GuideStep('Optional hardening: set "PasswordAuthentication no" in this file, then restart ssh.', command: r'sudo nano /etc/ssh/sshd_config'),
        GuideStep('Restart after editing:', command: r'sudo systemctl restart ssh'),
      ]),
      const GuideSection('4. FTP and file transfer', [
        GuideStep('Safest: SFTP works as soon as SSH does.', command: r'sftp YOUR-USERNAME@YOUR-IP'),
        GuideStep('For real FTP, install vsftpd.', command: r'sudo apt install -y vsftpd'),
        GuideStep('Open its config and make sure these two lines are not commented out: local_enable=YES and write_enable=YES.',
            command: r'sudo nano /etc/vsftpd.conf'),
        GuideStep('Restart it and start it at every boot.', command: r'sudo systemctl restart vsftpd && sudo systemctl enable vsftpd'),
        GuideStep('Open the FTP port in the firewall.', command: r'sudo ufw allow 21/tcp'),
        GuideStep('Test (log in with your Ubuntu username and password):', command: r'ftp YOUR-IP'),
      ]),
      _appFtp,
      _connectFromApp,
      const GuideSection('If it does not work', [
        GuideStep('Is anything listening on port 22?', command: r'sudo ss -tlnp | grep :22'),
        GuideStep('Read the log:', command: r'sudo journalctl -u ssh -n 30 --no-pager'),
      ]),
    ],
  ),
  Guide(
    id: 'kali',
    title: 'Kali Linux',
    subtitle: 'SSH is installed but off by default',
    intro: 'Open a terminal. Kali ships OpenSSH but does not start it. The default account is kali / kali — change that password before you '
        'turn SSH on, because anyone on the network could otherwise log in. Only use this on machines and networks that are yours.',
    sections: <GuideSection>[
      const GuideSection('1. Make the account safe first', [
        GuideStep('Change your password (it asks for the old one, then the new one twice).', command: r'passwd'),
      ]),
      const GuideSection('2. Start the SSH server', [
        GuideStep('Install it if it is missing.', command: r'sudo apt update && sudo apt install -y openssh-server'),
        GuideStep('Start it now.', command: r'sudo systemctl start ssh'),
        GuideStep('Start it at every boot (leave this out if you only need it today).', command: r'sudo systemctl enable ssh'),
        GuideStep('Check that it is running (look for "active (running)") and that port 22 is open.',
            command: r'sudo systemctl status ssh --no-pager && sudo ss -tlnp | grep :22'),
        GuideStep('Stop it when you are done:', command: r'sudo systemctl stop ssh'),
      ]),
      const GuideSection('3. Find what to type on the phone', [
        GuideStep('Your username (kali unless you changed it):', command: r'whoami'),
        GuideStep('Your IP address (on a virtual machine, set the network adapter to "Bridged" so the phone can reach it):', command: r'ip -4 addr show | grep inet'),
        GuideStep('Test from another device:', command: r'ssh YOUR-USERNAME@YOUR-IP'),
        GuideStep('Logging in as root over SSH is off by default — log in as your normal user and use sudo.'),
      ]),
      const GuideSection('4. Log in with a key', [
        GuideStep('On the device you connect FROM:', command: r'ssh-keygen -t ed25519'),
        GuideStep('Copy it to Kali:', command: r'ssh-copy-id YOUR-USERNAME@YOUR-IP'),
      ]),
      const GuideSection('5. FTP and file transfer', [
        GuideStep('Safest: SFTP works as soon as SSH does.', command: r'sftp YOUR-USERNAME@YOUR-IP'),
        GuideStep('A quick throw-away FTP server (anyone on the network can write; Ctrl+C stops it):', command: r'sudo apt install -y python3-pyftpdlib'),
        GuideStep('Run it in the folder you want to share:', command: r'python3 -m pyftpdlib -p 2121 -w'),
      ]),
      _appFtp,
      _connectFromApp,
      const GuideSection('If it does not work', [
        GuideStep('Read the server log:', command: r'sudo journalctl -u ssh -n 30 --no-pager'),
        GuideStep('"Connection refused" means the server is not running; "timed out" means a different network or a firewall.'),
      ]),
    ],
  ),
];
