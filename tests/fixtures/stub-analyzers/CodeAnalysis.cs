// Stub of Microsoft.Dynamics.Nav.CodeAnalysis.dll for the Extract suite (docs/reference/scan-mechanics.md).
// Only the surface Get-AnalyzerDescriptor reflects over: the internal ErrorCode enum, DiagnosticSeverity,
// DiagnosticDescriptor and the abstract DiagnosticAnalyzer. No embedded resources, so AL titles are null.
using System.Collections.Immutable;

namespace Microsoft.Dynamics.Nav.CodeAnalysis
{
    public enum DiagnosticSeverity { Hidden = 0, Info = 1, Warning = 2, Error = 3 }

    internal enum ErrorCode
    {
        Void = 0,
        ERR_BelowHundred = 42,
        WRN_StubWarning = 200,
        ERR_StubError = 1003,
        INF_StubInfo = 1027,
        HDN_StubHidden = 1030
    }
}

namespace Microsoft.Dynamics.Nav.CodeAnalysis.Diagnostics
{
    public sealed class DiagnosticDescriptor
    {
        public DiagnosticDescriptor(string id, string title, string category, Microsoft.Dynamics.Nav.CodeAnalysis.DiagnosticSeverity defaultSeverity, bool isEnabledByDefault, string helpLinkUri = null, bool isDeprecated = false)
        {
            Id = id;
            Title = title;
            Category = category;
            DefaultSeverity = defaultSeverity;
            IsEnabledByDefault = isEnabledByDefault;
            HelpLinkUri = helpLinkUri;
            IsDeprecated = isDeprecated;
        }

        public string Id { get; }
        public string Title { get; }
        public string Category { get; }
        public Microsoft.Dynamics.Nav.CodeAnalysis.DiagnosticSeverity DefaultSeverity { get; }
        public bool IsEnabledByDefault { get; }
        public string HelpLinkUri { get; }
        public bool IsDeprecated { get; }
    }

    public abstract class DiagnosticAnalyzer
    {
        public abstract ImmutableArray<DiagnosticDescriptor> SupportedDiagnostics { get; }
    }
}
