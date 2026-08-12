# Azure Functions PowerShell worker profile.
#
# Runs once per worker cold start, before any function invocation. Kept minimal and free of
# managed-identity sign-in: each function's run.ps1 establishes its own Microsoft Graph context
# (Connect-MgGraph -Identity) so unit-of-work behavior stays identical to the Automation runbook.
# No Az PowerShell module is loaded here -- this app only depends on Microsoft.Graph.Authentication
# (see requirements.psd1) to keep cold start time and memory footprint low on Flex Consumption.

$ErrorActionPreference = 'Stop'
