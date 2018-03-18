Vagrant.configure('2') do |config|
  config.vm.box = 'opentable/win-2012r2-standard-amd64-nocm'
  config.vm.guest = :windows
  config.vm.communicator = 'winrm'

  config.vm.provider 'virtualbox' do |vb|
    vb.gui = true
    vb.customize ['modifyvm', :id, '--clipboard', 'bidirectional']
  end

  config.vm.provision 'shell' do |s|
    s.inline = "iex ((new-object net.webclient).DownloadString('https://chocolatey.org/install.ps1'));
                $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine')
                choco install NuGet.CommandLine -y
                choco install powershell-packagemanagement -y
                Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
                Install-Module AzureRM -Force"
  end
end

# now put a copy of the Fogg nupkg onto the VM and run (from the path you put the nupkg):
# > choco install fogg -fy -s .
