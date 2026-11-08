$ErrorActionPreference = 'Stop'

function Assert-SourceEqual($Actual, $Expected, [string]$Because) {
    $actualJson = ConvertTo-Json -InputObject $Actual -Depth 100 -Compress
    $expectedJson = ConvertTo-Json -InputObject $Expected -Depth 100 -Compress
    if ($actualJson -cne $expectedJson) { throw "$Because. Expected $expectedJson; got $actualJson" }
}

function New-SourceTestCertificate([string]$Directory) {
    $rsa = [Security.Cryptography.RSA]::Create(2048)
    try {
        $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=localhost', $rsa, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $san = [Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
        $san.AddDnsName('localhost'); $san.AddIpAddress([Net.IPAddress]::Loopback)
        [void]$request.CertificateExtensions.Add($san.Build())
        [void]$request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($true,$false,0,$true))
        $certificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-1), [DateTimeOffset]::UtcNow.AddDays(1))
        [IO.File]::WriteAllText("$Directory/cert.pem", $certificate.ExportCertificatePem())
        [IO.File]::WriteAllText("$Directory/key.pem", $rsa.ExportPkcs8PrivateKeyPem())
        return $certificate
    } finally { $rsa.Dispose() }
}

function New-SourceTestClient($Certificate) {
    $handler = [Net.Http.SocketsHttpHandler]::new()
    $handler.UseProxy = $false
    if ($Certificate) {
        $policy = [Security.Cryptography.X509Certificates.X509ChainPolicy]::new()
        $policy.TrustMode = [Security.Cryptography.X509Certificates.X509ChainTrustMode]::CustomRootTrust
        [void]$policy.CustomTrustStore.Add($Certificate)
        $policy.RevocationMode = [Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
        $handler.SslOptions.CertificateChainPolicy = $policy
    }
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(3)
    return $client
}

function Start-SourceTestProcess([string]$Script, [string[]]$Arguments, [string]$Directory, $Client, [string]$ReadyPath) {
    $info = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
    $info.UseShellExecute = $false; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    foreach ($argument in @('-NoLogo','-NoProfile','-File',$Script) + $Arguments + @('-Port','0')) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $info
    $null = $process.Start()
    $errorOutput = $process.StandardError.ReadToEndAsync()
    try {
        $lineTask = $process.StandardOutput.ReadLineAsync()
        $line = $lineTask.WaitAsync([TimeSpan]::FromSeconds(20)).GetAwaiter().GetResult()
        if ($line -notmatch 'https://127\.0\.0\.1:(\d+)') { throw "Server did not announce a port: $line" }
        $url = "https://127.0.0.1:$($Matches[1])"
        $response = $Client.GetAsync($url + $ReadyPath).GetAwaiter().GetResult()
        try { if ([int]$response.StatusCode -ne 200) { throw "Server readiness failed: $($response.StatusCode)" } } finally { $response.Dispose() }
        return @{Process=$process;Url=$url;ErrorOutput=$errorOutput}
    } catch {
        if (!$process.HasExited) { $process.Kill($true) }; $process.WaitForExit()
        $errors = $errorOutput.GetAwaiter().GetResult(); $process.Dispose()
        throw "Source startup failed: $_`n$errors"
    }
}

function Stop-SourceTestProcess($Server) {
    if ($Server) {
        if (!$Server.Process.HasExited) { $Server.Process.Kill($true) }
        $Server.Process.WaitForExit()
        $errors = $Server.ErrorOutput.GetAwaiter().GetResult()
        $Server.Process.Dispose()
        if ($errors) { Write-Verbose $errors }
    }
}

function Invoke-SourceTestRequest($Client, [string]$Url, [string]$Path, $Payload = $null, [string]$Method = 'GET', [int]$Status = 200) {
    $message = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method), $Url+$Path)
    if ($null -ne $Payload) {
        $message.Content = [Net.Http.StringContent]::new(($Payload | ConvertTo-Json -Depth 100 -Compress), [Text.Encoding]::UTF8, 'application/json')
    }
    try {
        $response = $Client.SendAsync($message).GetAwaiter().GetResult()
        try {
            $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            Assert-SourceEqual ([int]$response.StatusCode) $Status "$Method $Path status ($body)"
            return @{Body=$body;Length=$response.Content.Headers.ContentLength;ContentType=$response.Content.Headers.ContentType.MediaType}
        } finally { $response.Dispose() }
    } finally { $message.Dispose() }
}
