Describe 'Administrator documentation' {
    BeforeAll {
        $repoRoot = Resolve-Path "$PSScriptRoot\.."
        $readme = Get-Content "$repoRoot\README.md" -Raw
        $catalog = Get-Content "$repoRoot\.azd\catalog.json" -Raw | ConvertFrom-Json
    }

    It 'keeps the root quickstart to init and up' {
        (Get-Content "$repoRoot\README.md").Count | Should -BeLessOrEqual 150
        $readme | Should -Match 'azd init --template nathanmcnulty/azd-emergency-access\s+azd up'
        @($catalog.quickstartCommands) | Should -Be @(
            'azd init --template nathanmcnulty/azd-emergency-access',
            'azd up'
        )
    }

    It 'links every focused administrator guide' {
        foreach ($path in @(
            'docs/deployment-modes.md',
            'docs/identity-and-authentication.md',
            'docs/conditional-access-remediation.md',
            'docs/alerting-and-notifications.md',
            'docs/configuration.md',
            'docs/operations.md',
            'docs/development.md'
        )) {
            $readme | Should -Match ([regex]::Escape("($path)"))
            Test-Path "$repoRoot\$($path.Replace('/', '\'))" | Should -BeTrue
        }
    }

    It 'contains no broken relative Markdown links' {
        $markdownFiles = Get-ChildItem $repoRoot -Recurse -Filter *.md -File |
            Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' }
        foreach ($file in $markdownFiles) {
            $content = Get-Content $file.FullName -Raw
            foreach ($match in [regex]::Matches($content, '\[[^\]]+\]\(([^)]+)\)')) {
                $target = $match.Groups[1].Value
                if ($target -match '^(https?://|mailto:|#)') {
                    continue
                }
                $relativePath = ($target -split '#', 2)[0]
                $resolved = Join-Path $file.DirectoryName ([uri]::UnescapeDataString($relativePath))
                Test-Path $resolved | Should -BeTrue -Because "$($file.FullName) links to $target"
            }
        }
    }
}
