@{
    # Microsoft.Graph.Authentication is the only external dependency: it is sufficient for
    # app-only Connect-MgGraph -Identity and Invoke-MgGraphRequest calls used by the shared
    # remediation module. The full Microsoft.Graph meta-module is intentionally NOT used to
    # keep cold start time and memory footprint low on Flex Consumption.
    'Microsoft.Graph.Authentication' = '2.*'
}
