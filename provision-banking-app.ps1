param(
    [string]$ResourceGroupName = "rg-banking-app",
    [string]$Location = "australiaeast",
    [string]$KeyVaultName = "kv-banking-app",
    [string]$VMName = "vm-banking-backend",
    [string]$VMAdminUsername = "bankadmin",
    [string]$StaticWebAppName = "swa-banking-app",
    [string]$SqlServerName = "sql-banking-server",
    [string]$SqlDatabaseName = "banking-db",
    [string]$ApimName = "apim-banking-app"
)

function Write-Step([string]$Message) {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host " $Message" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
}

function Write-Success([string]$Message) {
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-Info([string]$Message) {
    Write-Host "[..] $Message" -ForegroundColor Yellow
}

function Write-Fail([string]$Message) {
    Write-Host "[!!] $Message" -ForegroundColor Red
}

# STEP 0 - Connect to Azure
Write-Step "STEP 0 - Connecting to Azure"

$context = Get-AzContext -ErrorAction SilentlyContinue
if (-not $context) {
    Write-Info "No active session. Signing in..."
    Connect-AzAccount
} else {
    Write-Success "Already signed in as: $($context.Account)"
}

$TenantId = (Get-AzContext).Tenant.Id
$SubscriptionId = (Get-AzContext).Subscription.Id
Write-Success "Tenant ID: $TenantId"
Write-Success "Subscription ID: $SubscriptionId"

# STEP 1 - Resource Group
Write-Step "STEP 1 - Creating Resource Group"

$rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
if ($rg) {
    Write-Success "Resource group '$ResourceGroupName' already exists - skipping"
} else {
    Write-Info "Creating resource group '$ResourceGroupName'..."
    New-AzResourceGroup -Name $ResourceGroupName -Location $Location | Out-Null
    Write-Success "Resource group created"
}

# STEP 2 - Key Vault
Write-Step "STEP 2 - Creating Azure Key Vault"

$kv = Get-AzKeyVault -VaultName $KeyVaultName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
if ($kv) {
    Write-Success "Key Vault '$KeyVaultName' already exists - skipping"
} else {
    Write-Info "Creating Key Vault '$KeyVaultName'..."
    New-AzKeyVault -Name $KeyVaultName -ResourceGroupName $ResourceGroupName -Location $Location -EnableRbacAuthorization $true | Out-Null
    Write-Success "Key Vault created with RBAC permission model"
}

$currentUser = (Get-AzContext).Account.Id
$kvResourceId = (Get-AzKeyVault -VaultName $KeyVaultName -ResourceGroupName $ResourceGroupName).ResourceId

$existingRole = Get-AzRoleAssignment -SignInName $currentUser -RoleDefinitionName "Key Vault Administrator" -Scope $kvResourceId -ErrorAction SilentlyContinue
if (-not $existingRole) {
    Write-Info "Assigning Key Vault Administrator role..."
    New-AzRoleAssignment -SignInName $currentUser -RoleDefinitionName "Key Vault Administrator" -Scope $kvResourceId | Out-Null
    Write-Info "Waiting 15 seconds for role propagation..."
    Start-Sleep -Seconds 15
} else {
    Write-Success "Key Vault Administrator role already assigned"
}

# STEP 3 - Secrets
Write-Step "STEP 3 - Creating Key Vault Secrets"

$JwtSigningKey = [System.Convert]::ToBase64String((1..48 | ForEach-Object { [byte](Get-Random -Max 256) }))
$EncryptionKey = [System.Convert]::ToBase64String((1..32 | ForEach-Object { [byte](Get-Random -Max 256) }))

$secretNames = @("JwtSigningKey", "SqlConnectionString", "AadTenantId", "AadClientId", "AadClientSecret", "JwtExpiryHours", "AllowedOrigins", "EncryptionKey")
$secretValues = @(
    $JwtSigningKey,
    "Server=tcp:$SqlServerName.database.windows.net,1433;Initial Catalog=$SqlDatabaseName;User ID=$VMAdminUsername;Password=REPLACE_ME;Encrypt=True;Connection Timeout=30;",
    $TenantId,
    "placeholder-update-after-app-registration",
    "placeholder-update-after-app-registration",
    "24",
    "https://gentle-ground-064220600.7.azurestaticapps.net",
    $EncryptionKey
)

for ($i = 0; $i -lt $secretNames.Length; $i++) {
    $name = $secretNames[$i]
    $value = $secretValues[$i]
    try {
        $existing = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name $name -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Success "Secret '$name' already exists - skipping"
        } else {
            Write-Info "Creating secret '$name'..."
            $secureValue = ConvertTo-SecureString $value -AsPlainText -Force
            Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name $name -SecretValue $secureValue | Out-Null
            Write-Success "Secret '$name' created"
        }
    } catch {
        Write-Fail "Failed to create secret '$name': $_"
    }
}

# STEP 4 - Virtual Machine
Write-Step "STEP 4 - Checking Virtual Machine"

$existingVM = Get-AzVM -Name $VMName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
if ($existingVM) {
    Write-Success "VM '$VMName' already exists - skipping creation"
} else {
    Write-Info "VM not found. Creating VM '$VMName'..."
    $VMPassword = Read-Host -AsSecureString "Enter VM Admin Password"
    $VMCredential = New-Object System.Management.Automation.PSCredential($VMAdminUsername, $VMPassword)

    $subnet = New-AzVirtualNetworkSubnetConfig -Name "banking-subnet" -AddressPrefix "10.0.1.0/24"
    $vnet = New-AzVirtualNetwork -Name "vnet-banking" -ResourceGroupName $ResourceGroupName -Location $Location -AddressPrefix "10.0.0.0/16" -Subnet $subnet

    $pip = New-AzPublicIpAddress -Name "pip-banking-vm" -ResourceGroupName $ResourceGroupName -Location $Location -AllocationMethod Static -Sku Standard

    $rule1 = New-AzNetworkSecurityRuleConfig -Name "Allow-RDP" -Protocol Tcp -Direction Inbound -Priority 1000 -SourceAddressPrefix * -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 3389 -Access Allow
    $rule2 = New-AzNetworkSecurityRuleConfig -Name "Allow-HTTP" -Protocol Tcp -Direction Inbound -Priority 1010 -SourceAddressPrefix * -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 80 -Access Allow
    $rule3 = New-AzNetworkSecurityRuleConfig -Name "Allow-HTTPS" -Protocol Tcp -Direction Inbound -Priority 1020 -SourceAddressPrefix * -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 443 -Access Allow
    $rule4 = New-AzNetworkSecurityRuleConfig -Name "Allow-3000" -Protocol Tcp -Direction Inbound -Priority 1030 -SourceAddressPrefix * -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 3000 -Access Allow
    $nsg = New-AzNetworkSecurityGroup -Name "nsg-banking-vm" -ResourceGroupName $ResourceGroupName -Location $Location -SecurityRules $rule1,$rule2,$rule3,$rule4

    $nic = New-AzNetworkInterface -Name "nic-banking-vm" -ResourceGroupName $ResourceGroupName -Location $Location -SubnetId ($vnet.Subnets | Where-Object { $_.Name -eq "banking-subnet" }).Id -PublicIpAddressId $pip.Id -NetworkSecurityGroupId $nsg.Id

    $vmConfig = New-AzVMConfig -VMName $VMName -VMSize "Standard_B2s"
    $vmConfig = Set-AzVMOperatingSystem -VM $vmConfig -Windows -ComputerName $VMName -Credential $VMCredential -ProvisionVMAgent
    $vmConfig = Set-AzVMSourceImage -VM $vmConfig -PublisherName "MicrosoftWindowsServer" -Offer "WindowsServer" -Skus "2022-Datacenter" -Version "latest"
    $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $nic.Id
    $vmConfig = Set-AzVMOSDisk -VM $vmConfig -CreateOption FromImage -StorageAccountType StandardSSD_LRS
    $vmConfig = Set-AzVMIdentity -VM $vmConfig -IdentityType SystemAssigned

    New-AzVM -ResourceGroupName $ResourceGroupName -Location $Location -VM $vmConfig | Out-Null
    Write-Success "VM '$VMName' created"
}

# STEP 5 - Managed Identity
Write-Step "STEP 5 - Assigning Managed Identity to Key Vault"

$vm = Get-AzVM -Name $VMName -ResourceGroupName $ResourceGroupName
$identityId = $vm.Identity.PrincipalId
$kvScope = (Get-AzKeyVault -VaultName $KeyVaultName -ResourceGroupName $ResourceGroupName).ResourceId

if (-not $identityId) {
    Write-Fail "VM has no Managed Identity. Enable it in the Azure Portal first."
} else {
    Write-Success "Managed Identity Principal ID: $identityId"
    $roleExists = Get-AzRoleAssignment -ObjectId $identityId -RoleDefinitionName "Key Vault Secrets User" -Scope $kvScope -ErrorAction SilentlyContinue
    if ($roleExists) {
        Write-Success "Key Vault Secrets User role already assigned"
    } else {
        Write-Info "Assigning Key Vault Secrets User role..."
        New-AzRoleAssignment -ObjectId $identityId -RoleDefinitionName "Key Vault Secrets User" -Scope $kvScope | Out-Null
        Write-Success "Role assigned"
    }
}

# STEP 6 - Static Web App
Write-Step "STEP 6 - Checking Static Web App"

try {
    $swa = Get-AzStaticWebApp -Name $StaticWebAppName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if ($swa) {
        Write-Success "Static Web App '$StaticWebAppName' already exists"
    } else {
        Write-Info "Creating Static Web App '$StaticWebAppName'..."
        New-AzStaticWebApp -Name $StaticWebAppName -ResourceGroupName $ResourceGroupName -Location $Location -SkuName "Free" | Out-Null
        Write-Success "Static Web App created - link to GitHub repo in Azure Portal"
    }
} catch {
    Write-Info "Static Web App cmdlet not available - create manually in Azure Portal"
}

# STEP 7 - SQL Database
Write-Step "STEP 7 - Checking Azure SQL"

$sqlServer = Get-AzSqlServer -ResourceGroupName $ResourceGroupName -ServerName $SqlServerName -ErrorAction SilentlyContinue
if ($sqlServer) {
    Write-Success "SQL Server '$SqlServerName' exists"
} else {
    Write-Info "SQL Server not found - create it in Azure Portal then update SqlConnectionString secret"
}

# STEP 8 - API Management
Write-Step "STEP 8 - Checking API Management"

$apim = Get-AzApiManagement -ResourceGroupName $ResourceGroupName -Name $ApimName -ErrorAction SilentlyContinue
if ($apim) {
    Write-Success "API Management '$ApimName' exists"
    Write-Success "Gateway URL: https://$ApimName.azure-api.net"
} else {
    Write-Info "API Management not found - create it in Azure Portal"
}

# STEP 9 - Summary
Write-Step "PROVISIONING COMPLETE - Summary"

Write-Host ""
Write-Host "Resource Group  : $ResourceGroupName" -ForegroundColor White
Write-Host "Location        : $Location" -ForegroundColor White
Write-Host "Key Vault       : $KeyVaultName" -ForegroundColor White
Write-Host "VM Name         : $VMName" -ForegroundColor White
Write-Host "Static Web App  : $StaticWebAppName" -ForegroundColor White
Write-Host "SQL Server      : $SqlServerName" -ForegroundColor White
Write-Host "SQL Database    : $SqlDatabaseName" -ForegroundColor White
Write-Host "API Management  : $ApimName" -ForegroundColor White
Write-Host "Tenant ID       : $TenantId" -ForegroundColor White
Write-Host "Subscription ID : $SubscriptionId" -ForegroundColor White

$pip = Get-AzPublicIpAddress -Name "pip-banking-vm" -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
if ($pip) {
    Write-Host "VM Public IP    : $($pip.IpAddress)" -ForegroundColor White
}

Write-Host ""
Write-Host "Post-provisioning steps:" -ForegroundColor Yellow
Write-Host "  1. RDP into VM and install Node.js, PM2, IIS ARR" -ForegroundColor Gray
Write-Host "  2. Deploy API to C:\banking-api\server.js" -ForegroundColor Gray
Write-Host "  3. Link Static Web App to GitHub repo in Azure Portal" -ForegroundColor Gray
Write-Host "  4. Update SqlConnectionString secret with real password" -ForegroundColor Gray
Write-Host "  5. Update AllowedOrigins secret with Static Web App URL" -ForegroundColor Gray
Write-Host "  6. Configure APIM with banking API operations" -ForegroundColor Gray
Write-Host "  7. Run: pm2 start server.js --name banking-api" -ForegroundColor Gray
Write-Host "  8. Run: pm2 save" -ForegroundColor Gray
Write-Host ""
Write-Success "Script completed successfully"