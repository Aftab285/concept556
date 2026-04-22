param(
  [Parameter(Mandatory = $true)]
  [string]$Root,
  [int]$Port = 8000
)

$ErrorActionPreference = "Stop"

function Get-ContentType {
  param([string]$Path)
  switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
    ".html" { return "text/html; charset=utf-8" }
    ".css" { return "text/css; charset=utf-8" }
    ".js" { return "application/javascript; charset=utf-8" }
    ".json" { return "application/json; charset=utf-8" }
    ".png" { return "image/png" }
    ".jpg" { return "image/jpeg" }
    ".jpeg" { return "image/jpeg" }
    ".webp" { return "image/webp" }
    ".svg" { return "image/svg+xml" }
    ".gif" { return "image/gif" }
    ".ico" { return "image/x-icon" }
    ".woff" { return "font/woff" }
    ".woff2" { return "font/woff2" }
    default { return "application/octet-stream" }
  }
}

$rootResolved = [System.IO.Path]::GetFullPath($Root)
$encoding = [System.Text.Encoding]::UTF8
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
$listener.Start()

function Send-Response {
  param(
    [System.Net.Sockets.NetworkStream]$Stream,
    [int]$StatusCode,
    [string]$Reason,
    [byte[]]$BodyBytes,
    [string]$ContentType
  )

  $header =
    "HTTP/1.1 $StatusCode $Reason`r`n" +
    "Content-Type: $ContentType`r`n" +
    "Content-Length: $($BodyBytes.Length)`r`n" +
    "Connection: close`r`n`r`n"

  $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
  $Stream.Write($headerBytes, 0, $headerBytes.Length)
  if ($BodyBytes.Length -gt 0) {
    $Stream.Write($BodyBytes, 0, $BodyBytes.Length)
  }
}

try {
  while ($true) {
    $client = $listener.AcceptTcpClient()
    try {
      $stream = $client.GetStream()
      $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::ASCII, $false, 1024, $true)

      $requestLine = $reader.ReadLine()
      if ([string]::IsNullOrWhiteSpace($requestLine)) {
        $emptyBody = $encoding.GetBytes("Bad Request")
        Send-Response -Stream $stream -StatusCode 400 -Reason "Bad Request" -BodyBytes $emptyBody -ContentType "text/plain; charset=utf-8"
        continue
      }

      # Read and ignore headers.
      while ($true) {
        $line = $reader.ReadLine()
        if ([string]::IsNullOrEmpty($line)) { break }
      }

      $parts = $requestLine.Split(" ")
      if ($parts.Length -lt 2) {
        $badBody = $encoding.GetBytes("Bad Request")
        Send-Response -Stream $stream -StatusCode 400 -Reason "Bad Request" -BodyBytes $badBody -ContentType "text/plain; charset=utf-8"
        continue
      }

      $method = $parts[0].ToUpperInvariant()
      $rawPath = $parts[1]

      if ($method -ne "GET" -and $method -ne "HEAD") {
        $methodBody = $encoding.GetBytes("Method Not Allowed")
        Send-Response -Stream $stream -StatusCode 405 -Reason "Method Not Allowed" -BodyBytes $methodBody -ContentType "text/plain; charset=utf-8"
        continue
      }

      $pathNoQuery = $rawPath.Split("?")[0]
      $requestPath = [System.Uri]::UnescapeDataString($pathNoQuery.TrimStart("/"))
      if ([string]::IsNullOrWhiteSpace($requestPath)) {
        $requestPath = "index.html"
      }

      $safeRelativePath = $requestPath -replace "/", [System.IO.Path]::DirectorySeparatorChar
      $fullPath = [System.IO.Path]::GetFullPath((Join-Path $rootResolved $safeRelativePath))

      if (-not $fullPath.StartsWith($rootResolved, [System.StringComparison]::OrdinalIgnoreCase)) {
        $forbiddenBody = $encoding.GetBytes("Forbidden")
        Send-Response -Stream $stream -StatusCode 403 -Reason "Forbidden" -BodyBytes $forbiddenBody -ContentType "text/plain; charset=utf-8"
        continue
      }

      if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        $notFoundBody = $encoding.GetBytes("Not Found")
        Send-Response -Stream $stream -StatusCode 404 -Reason "Not Found" -BodyBytes $notFoundBody -ContentType "text/plain; charset=utf-8"
        continue
      }

      $contentType = Get-ContentType -Path $fullPath
      if ($method -eq "HEAD") {
        Send-Response -Stream $stream -StatusCode 200 -Reason "OK" -BodyBytes @() -ContentType $contentType
      }
      else {
        $fileBytes = [System.IO.File]::ReadAllBytes($fullPath)
        Send-Response -Stream $stream -StatusCode 200 -Reason "OK" -BodyBytes $fileBytes -ContentType $contentType
      }
    }
    catch {
      try {
        if ($stream) {
          $errorBody = $encoding.GetBytes("Server Error")
          Send-Response -Stream $stream -StatusCode 500 -Reason "Internal Server Error" -BodyBytes $errorBody -ContentType "text/plain; charset=utf-8"
        }
      }
      catch { }
    }
    finally {
      if ($reader) { $reader.Dispose() }
      if ($stream) { $stream.Dispose() }
      if ($client) { $client.Close() }
    }
  }
}
finally {
  $listener.Stop()
}
