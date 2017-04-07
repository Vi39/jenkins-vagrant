param(
    [Parameter(Mandatory=$true)]
    [string]$config_jenkins_master_fqdn = 'jenkins.example.com',

    [Parameter(Mandatory=$true)]
    [string]$config_fqdn = 'windows.jenkins.example.com'
)

# install git and related applications.
choco install -y git --params '/GitOnlyOnPath /NoAutoCrlf'
choco install -y gitextensions
choco install -y meld

# update $env:PATH with the recently installed Chocolatey packages.
Import-Module C:\ProgramData\chocolatey\helpers\chocolateyInstaller.psm1
Update-SessionEnvironment

# configure git.
# see http://stackoverflow.com/a/12492094/477532
git config --global user.name 'Rui Lopes'
git config --global user.email 'rgl@ruilopes.com'
git config --global push.default simple
git config --global diff.guitool meld
git config --global difftool.meld.path 'C:/Program Files (x86)/Meld/Meld.exe'
git config --global difftool.meld.cmd '\"C:/Program Files (x86)/Meld/Meld.exe\" \"$LOCAL\" \"$REMOTE\"'
git config --global merge.tool meld
git config --global mergetool.meld.path 'C:/Program Files (x86)/Meld/Meld.exe'
git config --global mergetool.meld.cmd '\"C:/Program Files (x86)/Meld/Meld.exe\" --diff \"$LOCAL\" \"$BASE\" \"$REMOTE\" --output \"$MERGED\"'
#git config --list --show-origin

# install visual studio 2017.
choco install -y visualstudio2017community
choco install -y visualstudio2017-workload-netcoretools

# add support for .net 4.6.2.
choco install -y netfx-4.6.2-devpack

# import the Jenkins master site https certificate into the local machine trust store.
Import-Certificate `
    -FilePath C:/vagrant/tmp/$config_jenkins_master_fqdn-crt.der `
    -CertStoreLocation Cert:/LocalMachine/Root

# install the JRE.
choco install -y jre8 -PackageParameters '/exclude:32'

# create the jenkins user account and home directory.
[Reflection.Assembly]::LoadWithPartialName('System.Web') | Out-Null
$jenkinsAccountName = 'jenkins'
$jenkinsAccountPassword = [Web.Security.Membership]::GeneratePassword(32, 8)
$jenkinsAccountCredential = New-Object `
    Management.Automation.PSCredential `
    -ArgumentList `
        $jenkinsAccountName,
        (ConvertTo-SecureString $jenkinsAccountPassword -AsPlainText -Force)
net user $jenkinsAccountName $jenkinsAccountPassword /add /y /fullname:"Jenkins Slave" | Out-Null
wmic useraccount where "name='$jenkinsAccountName'" set PasswordExpires=FALSE | Out-Null
# login to force the system to create the home directory.
# NB the home directory will have the correct permissions, only the
#    SYSTEM, Administrators and the jenkins account are granted full
#    permissions to it.
Start-Process cmd /c -WindowStyle Hidden -Credential $jenkinsAccountCredential
mkdir C:\Users\$jenkinsAccountName\.ssh | Out-Null
copy C:\vagrant\tmp\$config_jenkins_master_fqdn-ssh-rsa.pub C:\Users\$jenkinsAccountName\.ssh\authorized_keys

# create the storage directory hierarchy.
# grant the SYSTEM, Administrators and $jenkinsAccountName accounts
# Full Permissions to the C:\jenkins directory and children.
$jenkinsDirectory = mkdir C:\jenkins
$acl = New-Object Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true, $false)
@(
    'SYSTEM'
    'Administrators'
    $jenkinsAccountName
) | ForEach-Object {
    $acl.AddAccessRule((
        New-Object `
            Security.AccessControl.FileSystemAccessRule(
                $_,
                'FullControl',
                'ContainerInherit,ObjectInherit',
                'None',
                'Allow')))
}
$jenkinsDirectory.SetAccessControl($acl)

# download the slave jar and install it.
mkdir C:\jenkins\lib | Out-Null
Invoke-WebRequest "https://$config_jenkins_master_fqdn/jnlpJars/slave.jar" -OutFile C:\jenkins\lib\slave.jar
mkdir C:\jenkins\bin | Out-Null
[IO.File]::WriteAllText(
    'C:\jenkins\bin\jenkins-slave',
    "#!/bin/sh`nexec c:/ProgramData/Oracle/Java/javapath/java -jar c:/jenkins/lib/slave.jar`n"
)

# create artifacts that need to be shared with the other nodes.
mkdir -Force C:\vagrant\tmp | Out-Null
[IO.File]::WriteAllText(
    "C:\vagrant\tmp\$config_fqdn.ssh_known_hosts",
    (dir 'C:\Program Files\OpenSSH\etc\ssh_host_*_key.pub' | %{ "$config_fqdn $(Get-Content $_)`n" }) -join ''
)
