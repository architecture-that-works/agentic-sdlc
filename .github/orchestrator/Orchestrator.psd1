@{
    RootModule        = 'Orchestrator.psm1'
    ModuleVersion     = '2.0.0'
    GUID              = '7b976e4f-53df-487d-ab4c-1bd36d42699e'
    Author            = 'my_template_repo'
    Description       = 'Agentic pipeline orchestrator: refine -> architect -> plan -> implement -> review -> ship. Run parameters flow via the KANBAN_* env transport and Get-OrchestratorContext (ADR-013, ADR-015).'
    PowerShellVersion = '7.0'

    # The public API. This is the ONLY place it is declared — a manifest is data,
    # whereas Export-ModuleMember would be logic running at import (ADR-015).
    #
    # Listed explicitly, never '*': with an explicit list PowerShell resolves which
    # module provides a command from this file alone, without loading or executing
    # the module. A wildcard forces a full load to answer the same question, and
    # exported all 78 functions the module defines when only these are called from
    # outside it.
    #
    # Anything absent here is private to the module automatically. No underscore
    # convention and no internal/ directory are needed — this list is the boundary.
    # checks/check-module-api.ps1 asserts it stays true (added in PR 3).
    FunctionsToExport = @(
        # Run context
        'Get-OrchestratorContext'

        # The conductor
        'Invoke-Orchestration'

        # Stages invoked directly (by tasks/ and the workflows)
        'Invoke-Ship'

        # Issue + board state
        'Set-AgentState'
        'Move-ToLane'
        'Add-Comment'
        'Resolve-PR'
        'Reset-AttemptCount'

        # Carrier read + label primitive — task retry resumes from failed_at
        'Get-IssueState'
        'Set-IssueLabel'

        # Self-grill subagent (refine stage; also driven standalone by the
        # refine skill's grill.ps1 probe)
        'Invoke-Grill'

        # Shared helpers used by the task scripts
        'Write-Log'
        'Set-EnvVar'
        'Get-ResolvedOwner'
    )

    # Never variables: the $Kanban* run state stays private so it cannot leak into
    # a caller's scope — the scope leak that once ran the pipeline against issue #0
    # (ADR-013).
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
