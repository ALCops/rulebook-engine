@{
    Severity            = @('Error', 'Warning')
    IncludeDefaultRules = $true
    ExcludeRules        = @(
        # One justified exclusion per line, with the reason, for example:
        # 'PSAvoidUsingWriteHost'   # CLI tool: Write-Host is the intended user-facing output
    )
}
