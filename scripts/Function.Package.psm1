function New-FunctionPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $SourcePath,
        [Parameter(Mandatory)]
        [ValidateSet('function-scheduled', 'sentinel-function')]
        [string] $Mode,
        [Parameter(Mandatory)][string] $DestinationPath
    )

    $triggerName = if ($Mode -eq 'function-scheduled') {
        'TimerRemediation'
    }
    else {
        'HttpRemediation'
    }

    [void](New-Item -ItemType Directory -Path $DestinationPath -Force)
    foreach ($file in 'host.json', 'profile.ps1', 'requirements.psd1') {
        Copy-Item -LiteralPath (Join-Path $SourcePath $file) -Destination $DestinationPath
    }
    Copy-Item -LiteralPath (Join-Path $SourcePath 'shared') `
        -Destination (Join-Path $DestinationPath 'shared') -Recurse
    Copy-Item -LiteralPath (Join-Path $SourcePath $triggerName) `
        -Destination (Join-Path $DestinationPath $triggerName) -Recurse

    return $DestinationPath
}

Export-ModuleMember -Function New-FunctionPackage

