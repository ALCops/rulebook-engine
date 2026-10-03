@{
    Severity            = @('Error', 'Warning')
    IncludeDefaultRules = $true
    ExcludeRules        = @(
        # One justified exclusion per line, with the reason:
        'PSAvoidUsingWriteHost'   # tools/ and actions write console status; Write-Host keeps it out of the pipeline
    )
}
