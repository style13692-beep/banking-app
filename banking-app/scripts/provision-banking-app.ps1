# ============================================================
# SecureBank Azure Provisioning Script
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
    [string]$AppRegistrationName = "BankingApp"
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

# Grant current user Key Vault Administrator role so we can write secrets
Write-Info "Granting current user Key Vault Administrator role..."
$currentUser = (Get-AzContext).Account.Id
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
$JwtSigningKey  = [System.Convert]::ToBase64String((1..48 | ForEach-Object { [byte](Get-Random -Max 256) }))
$EncryptionKey  = [System.Convert]::ToBase64String((1..32 | ForEach-Object { [byte](Get-Random -Max 256) }))

$secrets = @{
    "JwtSigningKey"       = $JwtSigningKey
    "SqlConnectionString" = "Server=localhost;Database=BankingDB;Trusted_Connection=True;"
    "AadTenantId"         = $TenantId
    "AadClientId"         = "placeholder-client-id"
    "AadClientSecret"     = "placeholder-client-secret"
    "JwtExpiryHours"      = "24"
    "AllowedOrigins"      = "https://placeholder.azurestaticapps.net"
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

    # NIC and networking
    Write-Info "Creating virtual network and subnet..."
    $subnet = New-AzVirtualNetworkSubnetConfig -Name "banking-subnet" -AddressPrefix "10.0.1.0/24"
    $vnet   = New-AzVirtualNetwork `
        -Name "vnet-banking" `
        -ResourceGroupName $ResourceGroupName `
        -Location $Location `
        -AddressPrefix "10.0.0.0/16" `
        -Subnet $subnet

    Write-Info "Creating public IP..."
    $pip = New-AzPublicIpAddress `
        -Name "pip-banking-vm" `
        -ResourceGroupName $ResourceGroupName `
        -Location $Location `
        -AllocationMethod Static `
        -Sku Standard

    Write-Info "Creating Network Security Group with required inbound rules..."
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

    Write-Info "Creating VM (this may take 3-5 minutes)..."
    $vmConfig = New-AzVMConfig -VMName $VMName -VMSize "Standard_B2s" |
        Set-AzVMOperatingSystem -Windows -ComputerName $VMName -Credential $VMCredential -ProvisionVMAgent |
        Set-AzVMSourceImage -PublisherName "MicrosoftWindowsServer" -Offer "WindowsServer" -Skus "2022-Datacenter" -Version "latest" |
        Add-AzVMNetworkInterface -Id $nic.Id |
        Set-AzVMOSDisk -CreateOption FromImage -StorageAccountType StandardSSD_LRS

    # Enable System-Assigned Managed Identity
    $vmConfig = Set-AzVMIdentity -VM $vmConfig -IdentityType SystemAssigned

    New-AzVM -ResourceGroupName $ResourceGroupName -Location $Location -VM $vmConfig | Out-Null
    Write-Success "VM '$VMName' created successfully"

    # Get the VM's public IP
    $pip = Get-AzPublicIpAddress -Name "pip-banking-vm" -ResourceGroupName $ResourceGroupName
    Write-Success "VM Public IP: $($pip.IpAddress)"
}

# ============================================================
# STEP 5 — Managed Identity + Key Vault Role Assignment
# ============================================================

Write-Step "STEP 5 — Assigning Managed Identity to Key Vault"

$vm           = Get-AzVM -Name $VMName -ResourceGroupName $ResourceGroupName
$identityId   = $vm.Identity.PrincipalId
$kvResourceId = (Get-AzKeyVault -VaultName $KeyVaultName -ResourceGroupName $ResourceGroupName).ResourceId

if (-not $identityId) {
    Write-Fail "VM does not have a System-Assigned Managed Identity. Enable it in the portal first."
} else {
    Write-Success "Managed Identity Principal ID: $identityId"

    $existingRole = Get-AzRoleAssignment `
        -ObjectId $identityId `
        -RoleDefinitionName "Key Vault Secrets User" `
        -Scope $kvResourceId `
        -ErrorAction SilentlyContinue

    if ($existingRole) {
        Write-Success "Key Vault Secrets User role already assigned to VM identity"
    } else {
        Write-Info "Assigning Key Vault Secrets User role to VM Managed Identity..."
        New-AzRoleAssignment `
            -ObjectId $identityId `
            -RoleDefinitionName "Key Vault Secrets User" `
            -Scope $kvResourceId | Out-Null
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
        Write-Info "NOTE: Link this to your GitHub repo manually in the Azure Portal"
    }
} catch {
    Write-Info "Static Web App cmdlet may not be available — skipping (create manually in portal)"
    Write-Info "Error: $_"
}

# ============================================================
# STEP 7 — Summary
# ============================================================

Write-Step "PROVISIONING COMPLETE — Summary"

Write-Host ""
Write-Host "Resource Group  : $ResourceGroupName" -ForegroundColor White
Write-Host "Location        : $Location"           -ForegroundColor White
Write-Host "Key Vault       : $KeyVaultName"       -ForegroundColor White
Write-Host "VM Name         : $VMName"             -ForegroundColor White
Write-Host "Static Web App  : $StaticWebAppName"   -ForegroundColor White
Write-Host "Tenant ID       : $TenantId"           -ForegroundColor White

try {
    $pip = Get-AzPublicIpAddress -Name "pip-banking-vm" -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if ($pip) { Write-Host "VM Public IP    : $($pip.IpAddress)" -ForegroundColor White }
} catch {}

Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. RDP into the VM and install Node.js, PM2, and deploy the API" -ForegroundColor Gray
Write-Host "  2. Link the Static Web App to your GitHub repo in the Azure Portal" -ForegroundColor Gray
Write-Host "  3. Update the AllowedOrigins secret with your Static Web App URL" -ForegroundColor Gray
Write-Host "  4. Update AadClientId and AadClientSecret secrets with real values" -ForegroundColor Gray
Write-Host ""
Write-Success "Script completed successfully"