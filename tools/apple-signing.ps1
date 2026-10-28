param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('CreateCSR', 'ExportCertificate', 'UploadSecrets')]
    [string]$Action,
    [string]$SigningDirectory = (Join-Path $env:LOCALAPPDATA 'FrigateHorizon\Signing'),
    [string]$CertificatePath,
    [string]$ProfilePath,
    [string]$ApiKeyPath,
    [string]$KeyId,
    [string]$IssuerId,
    [string]$TeamId,
    [string]$BundleId = 'com.errantactions.frigatehorizon',
    [string]$Repository = 'ErrantActions/frigate-horizon-iphone'
)

$ErrorActionPreference = 'Stop'
$openssl = Join-Path $env:ProgramFiles 'Git\usr\bin\openssl.exe'
if (-not (Test-Path -LiteralPath $openssl)) {
    $opensslCommand = Get-Command openssl -ErrorAction SilentlyContinue
    if (-not $opensslCommand) { throw 'Install OpenSSL or Git for Windows first.' }
    $openssl = $opensslCommand.Source
}

$privateKey = Join-Path $SigningDirectory 'distribution-private.pem'
$csr = Join-Path $SigningDirectory 'distribution.csr'
$certificate = Join-Path $SigningDirectory 'distribution-certificate.pem'
$p12 = Join-Path $SigningDirectory 'distribution.p12'

function Read-SigningPassword {
    param([string]$Prompt)
    $secure = Read-Host $Prompt -AsSecureString
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
        if ([string]::IsNullOrWhiteSpace($plain)) { throw 'A signing password is required.' }
        return $plain
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
        $secure.Dispose()
    }
}

function Invoke-OpenSSL {
    param([string[]]$Arguments)
    & $openssl @Arguments
    if ($LASTEXITCODE -ne 0) { throw "OpenSSL failed during $Action (exit $LASTEXITCODE)." }
}

function Get-RequiredFile {
    param([string]$Path, [string]$Prompt)
    if ([string]::IsNullOrWhiteSpace($Path)) { $Path = Read-Host $Prompt }
    $Path = $Path.Trim().Trim('"')
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "File not found: $Path" }
    return (Get-Item -LiteralPath $Path).FullName
}

function Set-SigningSecret {
    param([string]$Name, [string]$Value)
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $script:gh
    $start.Arguments = "secret set $Name --repo $Repository --env app-store"
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw "Could not start GitHub CLI for $Name." }
        $output = $process.StandardOutput.ReadToEndAsync()
        $errors = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write($Value)
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(120000)) {
            $process.Kill()
            throw "Timed out uploading $Name."
        }
        if ($process.ExitCode -ne 0) {
            throw "GitHub rejected secret $Name`: $($errors.GetAwaiter().GetResult())"
        }
        $null = $output.GetAwaiter().GetResult()
        Write-Host "Uploaded encrypted secret: $Name"
    } finally {
        $process.Dispose()
    }
}

try {
    if ($Action -eq 'CreateCSR') {
        if ((Test-Path -LiteralPath $privateKey) -or (Test-Path -LiteralPath $csr)) {
            throw 'Signing files already exist. Reuse them or choose a new -SigningDirectory; keys are never overwritten.'
        }
        $null = New-Item -ItemType Directory -Path $SigningDirectory -Force
        $acl = Get-Acl -LiteralPath $SigningDirectory
        $acl.SetAccessRuleProtection($true, $false)
        $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $system = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
        foreach ($identity in @($currentUser, $system)) {
            $rule = New-Object Security.AccessControl.FileSystemAccessRule(
                $identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'
            )
            $acl.AddAccessRule($rule)
        }
        Set-Acl -LiteralPath $SigningDirectory -AclObject $acl
        $email = Read-Host 'Certificate contact email (entered locally, not in chat)'
        if ($email -notmatch '^[^@\s/\\=]+@[^@\s/\\=]+\.[^@\s/\\=]+$') {
            throw 'Enter a valid contact email without slash, backslash, or equals characters.'
        }
        $email = $email.Replace('+', '\+')
        $password = Read-SigningPassword 'Choose a password for the encrypted private key and distribution certificate'
        $confirm = Read-SigningPassword 'Confirm the signing password'
        if ($password -cne $confirm) { throw 'Signing passwords do not match.' }
        $confirm = $null
        $env:HORIZON_SIGNING_PASSWORD = $password
        Invoke-OpenSSL @('genpkey', '-algorithm', 'RSA', '-pkeyopt', 'rsa_keygen_bits:2048',
            '-aes-256-cbc', '-pass', 'env:HORIZON_SIGNING_PASSWORD', '-out', $privateKey)
        Invoke-OpenSSL @('req', '-new', '-sha256', '-key', $privateKey,
            '-passin', 'env:HORIZON_SIGNING_PASSWORD',
            '-subj', "/CN=Frigate Horizon Distribution/emailAddress=$email", '-out', $csr)
        Invoke-OpenSSL @('req', '-in', $csr, '-noout', '-verify')
        Write-Host "Upload only this public CSR to Apple: $csr"
        Write-Host 'Keep the encrypted private key and password. Never upload them to Apple or commit them to git.'
    } elseif ($Action -eq 'ExportCertificate') {
        if (-not (Test-Path -LiteralPath $privateKey)) { throw 'Create the CSR and private key first.' }
        if (Test-Path -LiteralPath $p12) { throw 'The distribution P12 already exists; it will not be overwritten.' }
        $CertificatePath = Get-RequiredFile $CertificatePath 'Path to the Apple Distribution .cer download'
        $password = Read-SigningPassword 'Enter the signing password chosen when creating the CSR'
        $env:HORIZON_SIGNING_PASSWORD = $password
        Invoke-OpenSSL @('x509', '-inform', 'DER', '-in', $CertificatePath, '-out', $certificate)
        $certPublicKey = Invoke-OpenSSL @('x509', '-in', $certificate, '-pubkey', '-noout')
        $privatePublicKey = Invoke-OpenSSL @('pkey', '-in', $privateKey,
            '-passin', 'env:HORIZON_SIGNING_PASSWORD', '-pubout')
        if (($certPublicKey -join "`n") -cne ($privatePublicKey -join "`n")) {
            throw 'The downloaded certificate does not match this private key.'
        }
        Invoke-OpenSSL @('pkcs12', '-export', '-inkey', $privateKey, '-in', $certificate,
            '-passin', 'env:HORIZON_SIGNING_PASSWORD', '-passout', 'env:HORIZON_SIGNING_PASSWORD',
            '-out', $p12)
        Write-Host "Encrypted distribution certificate ready: $p12"
    } else {
        if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw 'Invalid GitHub repository.' }
        if ($TeamId -notmatch '^[A-Z0-9]{10}$') { throw 'Supply the 10-character Apple team ID using -TeamId.' }
        if ($BundleId -notmatch '^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$') { throw 'Invalid bundle identifier.' }
        $ProfilePath = Get-RequiredFile $ProfilePath 'Path to the App Store provisioning profile'
        $ApiKeyPath = Get-RequiredFile $ApiKeyPath 'Path to the App Store Connect API .p8 file'
        $null = Get-RequiredFile $p12 'Path to the distribution P12'
        if ([string]::IsNullOrWhiteSpace($KeyId)) { $KeyId = Read-Host 'App Store Connect API key ID' }
        if ([string]::IsNullOrWhiteSpace($IssuerId)) { $IssuerId = Read-Host 'App Store Connect API issuer ID' }
        if ($KeyId -notmatch '^[A-Z0-9]+$' -or
            $IssuerId -notmatch '^[a-fA-F0-9]{8}(-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$') {
            throw 'The API key ID or issuer ID is invalid.'
        }
        $command = Get-Command gh -ErrorAction SilentlyContinue
        if ($command) { $script:gh = $command.Source }
        else {
            $install = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Programs') -Directory -Filter 'GitHubCLI-*' |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if (-not $install) { throw 'Install and authenticate the official GitHub CLI first.' }
            $script:gh = Join-Path $install.FullName 'bin\gh.exe'
        }
        & $script:gh auth status --hostname github.com
        if ($LASTEXITCODE -ne 0) { throw 'Authenticate GitHub CLI before uploading signing secrets.' }
        $password = Read-SigningPassword 'Enter the distribution P12 password'
        $env:HORIZON_SIGNING_PASSWORD = $password
        Invoke-OpenSSL @('pkcs12', '-in', $p12, '-passin', 'env:HORIZON_SIGNING_PASSWORD', '-noout')
        $environments = @(& $script:gh api "repos/$Repository/environments?per_page=100" --paginate --jq '.environments[].name')
        if ($LASTEXITCODE -ne 0) { throw 'Could not inspect deployment environments.' }
        if ($environments -notcontains 'app-store') {
            & $script:gh api --method PUT "repos/$Repository/environments/app-store" --silent
            if ($LASTEXITCODE -ne 0) { throw 'Could not create the app-store environment.' }
        }
        foreach ($variable in @{ APP_BUNDLE_ID = $BundleId; APPLE_TEAM_ID = $TeamId }.GetEnumerator()) {
            & $script:gh variable set $variable.Key --body $variable.Value --repo $Repository --env app-store
            if ($LASTEXITCODE -ne 0) { throw "Could not set $($variable.Key)." }
        }
        Set-SigningSecret 'DISTRIBUTION_CERTIFICATE_BASE64' ([Convert]::ToBase64String([IO.File]::ReadAllBytes($p12)))
        Set-SigningSecret 'DISTRIBUTION_CERTIFICATE_PASSWORD' $password
        Set-SigningSecret 'PROVISIONING_PROFILE_BASE64' ([Convert]::ToBase64String([IO.File]::ReadAllBytes($ProfilePath)))
        Set-SigningSecret 'APP_STORE_CONNECT_KEY_ID' $KeyId
        Set-SigningSecret 'APP_STORE_CONNECT_ISSUER_ID' $IssuerId
        Set-SigningSecret 'APP_STORE_CONNECT_PRIVATE_KEY' ([IO.File]::ReadAllText($ApiKeyPath))
        Write-Host 'Signing configuration uploaded. No TestFlight upload was triggered.'
    }
} finally {
    Remove-Item Env:HORIZON_SIGNING_PASSWORD -ErrorAction SilentlyContinue
    $password = $null
    $confirm = $null
}
