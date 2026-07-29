@{
    RootModule        = 'Kanban.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '7b976e4f-53df-487d-ab4c-1bd36d42699e'
    Author            = 'my_template_repo'
    Description       = 'AFK kanban orchestrator: refine -> architecture -> implement -> review -> merge. Run parameters flow via the KANBAN_* env transport and Get-KanbanContext (ADR-013).'
    PowerShellVersion = '7.0'

    # Export functions only; never variables (the $Kanban* run state stays private
    # so it cannot leak into a caller's scope — see ADR-013).
    FunctionsToExport = '*'
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
