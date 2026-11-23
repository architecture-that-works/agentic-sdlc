#Requires -Version 7.0
<#
    Decision table — check-token-scope.ps1: no secret sits in afk.yml's workflow-level
    env, and no installer step runs after a checkout that stored credentials in the same
    job, or with a secret in its own env. Each row writes one afk.yml, runs the check,
    and asserts the exit code and the violation it names.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '../journeys/Journey.ps1')
    $script:Check = 'check-token-scope.ps1'

    function New-Workflow {
        param([string]$Env = "  LOG: info`n", [string]$Steps)
        return "name: afk`non: push`nenv:`n$Env" + "jobs:`n  build:`n    runs-on: ubuntu-latest`n    steps:`n$Steps"
    }
    $script:Install  = "      - name: Install`n        run: uv sync`n"
    $script:Checkout = "      - uses: actions/checkout@v4`n"
    $script:Clean    = "      - uses: actions/checkout@v4`n        with:`n          persist-credentials: false`n"
}

Describe 'Decision: check-token-scope' {
    AfterEach { Remove-CheckRepo $script:root }

    It '<Case> — exit <Exit>' -ForEach @(
        @{ Case = 'the installer runs before the checkout'; Exit = 0; Shape = 'install,checkout' }
        @{ Case = 'the installer runs after a checkout without credentials'; Exit = 0; Shape = 'clean,install' }
        @{ Case = 'the installer runs after a credentialed checkout'; Exit = 1; Shape = 'checkout,install'
           Line = "job 'build': installer step (index 1) appears after credentialed checkout (index 0)" }
        @{ Case = 'GH_TOKEN in the workflow-level env'; Exit = 1; Shape = 'install,checkout'; Env = "  GH_TOKEN: x`n"
           Line = "workflow-level env contains 'GH_TOKEN'" }
        @{ Case = 'CLAUDE_CODE_OAUTH_TOKEN in the workflow-level env'; Exit = 1; Shape = 'install,checkout'; Env = "  CLAUDE_CODE_OAUTH_TOKEN: x`n"
           Line = "workflow-level env contains 'CLAUDE_CODE_OAUTH_TOKEN'" }
        @{ Case = 'an installer step with a secret in its env'; Exit = 1; Shape = 'secret-install,checkout'
           Line = "installer step (index 0) has secret 'GH_TOKEN' in its env" }
    ) {
        $steps = @($Shape -split ',' | ForEach-Object {
            switch ($_) {
                'install'        { $script:Install }
                'checkout'       { $script:Checkout }
                'clean'          { $script:Clean }
                'secret-install' { "      - name: Install`n        env:`n          GH_TOKEN: x`n        run: uv sync`n" }
            }
        }) -join ''
        $workflow = if ($Env) { New-Workflow -Env $Env -Steps $steps } else { New-Workflow -Steps $steps }
        $script:root = New-CheckRepo -Check $script:Check -Files @{ '.github/workflows/afk.yml' = $workflow }

        $run = Invoke-CheckScript -Root $script:root -Check $script:Check

        $run.Exit | Should -Be $Exit -Because $run.Output
        if ($Line) { $run.Output | Should -Match ([regex]::Escape($Line)) }
    }

    It 'stops, naming the file, when afk.yml is missing' {
        $script:root = New-CheckRepo -Check $script:Check

        $run = Invoke-CheckScript -Root $script:root -Check $script:Check

        $run.Exit | Should -Be 1
        $run.Output | Should -Match 'afk\.yml not found'
    }
}
