# LumeBank - Node.js Server Automation Script
# BN304 Cloud Computing Project

$serviceName = "LumeBankServer"
$nodeExePath = "C:\Program Files\nodejs\node.exe"
$scriptPath = "C:\Users\User\Documents\BN304 Project\Scripts\server.js"
$workingDir = "C:\Users\User\Documents\BN304 Project\Scripts"
$logPath = "C:\Logs\lumebank.log"

# Create log directory if it doesn't exist
if (!(Test-Path "C:\Logs")) {
    New-Item -ItemType Directory -Path "C:\Logs"
    Write-Host "Log directory created"
}

# Check if service already exists and remove it
if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
    Write-Host "Service already exists, removing old one..."
    Stop-Service -Name $serviceName -Force
    sc.exe delete $serviceName
    Start-Sleep -Seconds 2
}

# Register Node.js as a Windows service using sc.exe
Write-Host "Registering LumeBank as a Windows service..."
$binPath = "cmd /c `"cd /d `"$workingDir`" && `"$nodeExePath`" `"$scriptPath`"`""
sc.exe create $serviceName binPath= $binPath start= auto obj= "LocalSystem" DisplayName= "LumeBank Node.js Server"
sc.exe description $serviceName "LumeBank banking backend - BN304 Project"

Start-Sleep -Seconds 2

# Start the service
Write-Host "Starting LumeBank service..."
Start-Service -Name $serviceName

# Wait and verify
Start-Sleep -Seconds 3
$status = Get-Service -Name $serviceName

if ($status.Status -eq "Running") {
    Write-Host "SUCCESS - LumeBank server is running!"
    Write-Host "API available at: https://lumebank-project.australiaeast.cloudapp.azure.com/api/health"
} else {
    Write-Host "FAILED - Service failed to start"
    Write-Host "Checking event log..."
    Get-EventLog -LogName System -Source "Service Control Manager" -Newest 3 | 
    Select-Object TimeGenerated, Message | Format-List
}

# Display service status
Get-Service -Name $serviceName | Select-Object Name, Status, StartType