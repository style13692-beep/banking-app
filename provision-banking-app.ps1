# ============================================================
# LumeBank Azure Provisioning Script
# BN304 — University Project
# Automates full Azure infrastructure setup using AZ PowerShell
# ============================================================

param(
    [string]$ResourceGroupName   = "rg-banking-app",
    [string]$Location            = "australiaeast",
    [string]$KeyVaultName        = "kv-banking-app",
    [string]$VMName              = "vm-banking-backend",
    [string]$VMAdminUsername     = "bankadmin",
    [string]$StaticWebAppName    = "swa-banking-app",
    [string]$AppRegistrationName = "BankingApp",
    [string]$SqlServerName       = "sql-banking-server",
    [string]$SqlDatabaseName     = "banking-db",
    [string]$ApimName            = "apim-banking-app"
)

# ============================================================
# HELPER FUNCTIONS
# ============================================================

function Write-Step {
    param([string]$Message)
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host " $Message" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-Info {
    param([string]$Message)
    Write-Host "[..] $Message" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Message)
    Write-Host "[!!] $Message" -ForegroundColor Red
}

# ============================================================
# STEP 0 — Connect to Azure
# ============================================================

Write-Step "STEP 0 — Connecting to Azure"

try {
    $context = Get-AzContext
    if (-not $context) {
        Write-Info "No active session found. Signing in..."
        Connect-AzAccount
    } else {
        Write-Success "Already signed in as: $($context.Account)"
    }
} catch {
    Write-Fail "Failed to connect to Azure: $_"
    exit 1
}

$TenantId       = (Get-AzContext).Tenant.Id
$SubscriptionId = (Get-AzContext).Subscription.Id
Write-Success "Tenant ID:       $TenantId"
Write-Success "Subscription ID: $SubscriptionId"

# ============================================================
# STEP 1 — Resource Group
# ============================================================

Write-Step "STEP 1 — Creating Resource Group"

$rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
if ($rg) {
    Write-Success "Resource group '$ResourceGroupName' already exists — skipping"
} else {
    Write-Info "Creating resource group '$ResourceGroupName' in '$Location'..."
    New-AzResourceGroup -Name $ResourceGroupName -Location $Location | Out-Null
    Write-Success "Resource group created"
}

# ============================================================
# STEP 2 — Azure Key Vault
# ============================================================

Write-Step "STEP 2 — Creating Azure Key Vault"

$kv = Get-AzKeyVault -VaultName $KeyVaultName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
if ($kv) {
    Write-Success "Key Vault '$KeyVaultName' already exists — skipping"
} else {
    Write-Info "Creating Key Vault '$KeyVaultName'..."
    New-AzKeyVault `
        -Name $KeyVaultName `
        -ResourceGroupName $ResourceGroupName `
        -Location $Location `
        -EnableRbacAuthorization $true | Out-Null
    Write-Success "Key Vault created with RBAC permission model"
}

# Grant current user Key Vault Administrator role
Write-Info "Checking Key Vault Administrator role assignment..."
$currentUser  = (Get-AzContext).Account.Id
$kvResourceId = (Get-AzKeyVault -VaultName $KeyVaultName -ResourceGroupName $ResourceGroupName).ResourceId

$existingRole = Get-AzRoleAssignment `
    -SignInName $currentUser `
    -RoleDefinitionName "Key Vault Administrator" `
    -Scope $kvResourceId `
    -ErrorAction SilentlyContinue

if (-not $existingRole) {
    New-AzRoleAssignment `
        -SignInName $currentUser `
        -RoleDefinitionName "Key Vault Administrator" `
        -Scope $kvResourceId | Out-Null
    Write-Info "Role assigned — waiting 15 seconds for propagation..."
    Start-Sleep -Seconds 15
} else {
    Write-Success "Key Vault Administrator role already assigned"
}

# ============================================================
# STEP 3 — Key Vault Secrets
# ============================================================

Write-Step "STEP 3 — Creating Key Vault Secrets"

# Generate secure random values
$JwtSigningKey = [System.Convert]::ToBase64String(
    (1..48 | ForEach-Object { [byte](Get-Random -Max 256) })
)
$EncryptionKey = [System.Convert]::ToBase64String(
    (1..32 | ForEach-Object { [byte](Get-Random -Max 256) })
)

$secrets = @{
    "JwtSigningKey"       = $JwtSigningKey
    "SqlConnectionString" = "Server=tcp:$SqlServerName.database.windows.net,1433;Initial Catalog=$SqlDatabaseName;Persist Security Info=False;User ID=$VMAdminUsername;Password=REPLACE_WITH_YOUR_PASSWORD;MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"
    "AadTenantId"         = $TenantId
    "AadClientId"         = "placeholder-update-after-app-registration"
    "AadClientSecret"     = "placeholder-update-after-app-registration"
    "JwtExpiryHours"      = "24"
    "AllowedOrigins"      = "https://gentle-ground-064220600.7.azurestaticapps.net"
    "EncryptionKey"       = $EncryptionKey
}

foreach ($secret in $secrets.GetEnumerator()) {
    try {
        $existing = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name $secret.Key -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Success "Secret '$($secret.Key)' already exists — skipping"
        } else {
            Write-Info "Creating secret '$($secret.Key)'..."
            $secureValue = ConvertTo-SecureString $secret.Value -AsPlainText -Force
            Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name $secret.Key -SecretValue $secureValue | Out-Null
            Write-Success "Secret '$($secret.Key)' created"
        }
    } catch {
        Write-Fail "Failed to create secret '$($secret.Key)': $_"
    }
}

# ============================================================
# STEP 4 — Virtual Machine
# ============================================================

Write-Step "STEP 4 — Creating Windows Server VM"

$existingVM = Get-AzVM -Name $VMName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
if ($existingVM) {
    Write-Success "VM '$VMName' already exists — skipping creation"
} else {
    Write-Info "Enter a password for the VM admin account '$VMAdminUsername':"
    $VMPassword   = Read-Host -AsSecureString "VM Admin Password"
    $VMCredential = New-Object System.Management.Automation.PSCredential($VMAdminUsername, $VMPassword)

    Write-Info "Creating virtual network and subnet..."
    $subnet = New-AzVirtualNetworkSubnetConfig -Name "banking-subnet" -AddressPrefix "10.0.1.0/24"
    $vnet   = New-AzVirtualNetwork `
        -Name "vnet-banking" `
        -ResourceGroupName $ResourceGroupName `
        -Location $Location `
        -AddressPrefix "10.0.0.0/16" `
        -Subnet $subnet

    Write-Info "Creating public IP address..."
    $pip = New-AzPublicIpAddress `
        -Name "pip-banking-vm" `
        -ResourceGroupName $ResourceGroupName `
        -Location $Location `
        -AllocationMethod Static `
        -Sku Standard

    Write-Info "Creating Network Security Group with inbound rules..."
    $nsgRules = @(
        New-AzNetworkSecurityRuleConfig -Name "Allow-RDP"   -Protocol Tcp -Direction Inbound -Priority 1000 -SourceAddressPrefix * -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 3389 -Access Allow,
        New-AzNetworkSecurityRuleConfig -Name "Allow-HTTP"  -Protocol Tcp -Direction Inbound -Priority 1010 -SourceAddressPrefix * -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 80   -Access Allow,
        New-AzNetworkSecurityRuleConfig -Name "Allow-HTTPS" -Protocol Tcp -Direction Inbound -Priority 1020 -SourceAddressPrefix * -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 443  -Access Allow,
        New-AzNetworkSecurityRuleConfig -Name "Allow-3000"  -Protocol Tcp -Direction Inbound -Priority 1030 -SourceAddressPrefix * -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 3000 -Access Allow
    )
    $nsg = New-AzNetworkSecurityGroup `
        -Name "nsg-banking-vm" `
        -ResourceGroupName $ResourceGroupName `
        -Location $Location `
        -SecurityRules $nsgRules

    $nic = New-AzNetworkInterface `
        -Name "nic-banking-vm" `
        -ResourceGroupName $ResourceGroupName `
        -Location $Location `
        -SubnetId ($vnet.Subnets | Where-Object { $_.Name -eq "banking-subnet" }).Id `
        -PublicIpAddressId $pip.Id `
        -NetworkSecurityGroupId $nsg.Id

    Write-Info "Creating VM — this may take 3-5 minutes..."
    $vmConfig = New-AzVMConfig -VMName $VMName -VMSize "Standard_B2s" |
        Set-AzVMOperatingSystem -Windows -ComputerName $VMName -Credential $VMCredential -ProvisionVMAgent |
        Set-AzVMSourceImage -PublisherName "MicrosoftWindowsServer" -Offer "WindowsServer" -Skus "2022-Datacenter" -Version "latest" |
        Add-AzVMNetworkInterface -Id $nic.Id |
        Set-AzVMOSDisk -CreateOption FromImage -StorageAccountType StandardSSD_LRS

    $vmConfig = Set-AzVMIdentity -VM $vmConfig -IdentityType SystemAssigned

    New-AzVM -ResourceGroupName $ResourceGroupName -Location $Location -VM $vmConfig | Out-Null
    Write-Success "VM '$VMName' created successfully"

    $pip = Get-AzPublicIpAddress -Name "pip-banking-vm" -ResourceGroupName $ResourceGroupName
    Write-Success "VM Public IP: $($pip.IpAddress)"
}

# ============================================================
# STEP 5 — Managed Identity + Key Vault Role Assignment
# ============================================================

Write-Step "STEP 5 — Assigning Managed Identity to Key Vault"

$vm         = Get-AzVM -Name $VMName -ResourceGroupName $ResourceGroupName
$identityId = $vm.Identity.PrincipalId
$kvScope    = (Get-AzKeyVault -VaultName $KeyVaultName -ResourceGroupName $ResourceGroupName).ResourceId

if (-not $identityId) {
    Write-Fail "VM does not have a System-Assigned Managed Identity. Enable it in the Azure Portal first."
} else {
    Write-Success "Managed Identity Principal ID: $identityId"

    $existingRole = Get-AzRoleAssignment `
        -ObjectId $identityId `
        -RoleDefinitionName "Key Vault Secrets User" `
        -Scope $kvScope `
        -ErrorAction SilentlyContinue

    if ($existingRole) {
        Write-Success "Key Vault Secrets User role already assigned to VM identity"
    } else {
        Write-Info "Assigning Key Vault Secrets User role to VM Managed Identity..."
        New-AzRoleAssignment `
            -ObjectId $identityId `
            -RoleDefinitionName "Key Vault Secrets User" `
            -Scope $kvScope | Out-Null
        Write-Success "Role assigned successfully"
    }
}

# ============================================================
# STEP 6 — Azure Static Web App
# ============================================================

Write-Step "STEP 6 — Creating Azure Static Web App"

try {
    $swa = Get-AzStaticWebApp -Name $StaticWebAppName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if ($swa) {
        Write-Success "Static Web App '$StaticWebAppName' already exists — skipping"
    } else {
        Write-Info "Creating Static Web App '$StaticWebAppName'..."
        New-AzStaticWebApp `
            -Name $StaticWebAppName `
            -ResourceGroupName $ResourceGroupName `
            -Location $Location `
            -SkuName "Free" | Out-Null
        Write-Success "Static Web App created"
        Write-Info "NOTE: Link to your GitHub repo manually in the Azure Portal"
    }
} catch {
    Write-Info "Static Web App cmdlet not available — create manually in the Azure Portal"
}

# ============================================================
# STEP 7 — Azure SQL Database Check
# ============================================================

Write-Step "STEP 7 — Checking Azure SQL"

$sqlServer = Get-AzSqlServer -ResourceGroupName $ResourceGroupName -ServerName $SqlServerName -ErrorAction SilentlyContinue
if ($sqlServer) {
    Write-Success "SQL Server '$SqlServerName' exists"
} else {
    Write-Info "SQL Server '$SqlServerName' not found — create it in the Azure Portal"
    Write-Info "Then update the SqlConnectionString secret in Key Vault"
}

# ============================================================
# STEP 8 — API Management Check
# ============================================================

Write-Step "STEP 8 — Checking API Management"

$apim = Get-AzApiManagement -ResourceGroupName $ResourceGroupName -Name $ApimName -ErrorAction SilentlyContinue
if ($apim) {
    Write-Success "API Management '$ApimName' exists"
    Write-Success "Gateway URL: https://$ApimName.azure-api.net"
} else {
    Write-Info "API Management '$ApimName' not found"
    Write-Info "Create it in Azure Portal — choose Standard v2 or Consumption tier"
}

# ============================================================
# STEP 9 — Final Summary
# ============================================================

Write-Step "PROVISIONING COMPLETE — Summary"

Write-Host ""
Write-Host "Resource Group   : $ResourceGroupName"  -ForegroundColor White
Write-Host "Location         : $Location"           -ForegroundColor White
Write-Host "Key Vault        : $KeyVaultName"       -ForegroundColor White
Write-Host "VM Name          : $VMName"             -ForegroundColor White
Write-Host "Static Web App   : $StaticWebAppName"   -ForegroundColor White
Write-Host "SQL Server       : $SqlServerName"      -ForegroundColor White
Write-Host "SQL Database     : $SqlDatabaseName"    -ForegroundColor White
Write-Host "API Management   : $ApimName"           -ForegroundColor White
Write-Host "Tenant ID        : $TenantId"           -ForegroundColor White
Write-Host "Subscription ID  : $SubscriptionId"     -ForegroundColor White

try {
    $pip = Get-AzPublicIpAddress -Name "pip-banking-vm" -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if ($pip) { Write-Host "VM Public IP     : $($pip.IpAddress)" -ForegroundColor White }
} catch {}

Write-Host ""
Write-Host "Post-provisioning steps:" -ForegroundColor Yellow
Write-Host "  1. RDP into VM and install Node.js, PM2, IIS ARR"         -ForegroundColor Gray
Write-Host "  2. Deploy API: copy server.js to C:\banking-api\"          -ForegroundColor Gray
Write-Host "  3. Link Static Web App to GitHub repo in Azure Portal"     -ForegroundColor Gray
Write-Host "  4. Update SqlConnectionString secret with real password"   -ForegroundColor Gray
Write-Host "  5. Update AllowedOrigins secret with Static Web App URL"   -ForegroundColor Gray
Write-Host "  6. Configure APIM with banking API operations"             -ForegroundColor Gray
Write-Host "  7. Run: pm2 start server.js --name banking-api && pm2 save" -ForegroundColor Gray
Write-Host ""
Write-Success "Script completed successfully"
