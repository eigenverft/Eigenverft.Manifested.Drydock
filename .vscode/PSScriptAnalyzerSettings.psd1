@{
  Severity     = @('Warning','Error')
  ExcludeRules=@(
    'PSAvoidUsingWriteHost',
    'PSUseShouldProcessForStateChangingFunctions',
    'PSUseSingularNouns',
    'PSAvoidUsingEmptyCatchBlock',
    'PSAvoidGlobalVars',
    'PSAvoidUsingPositionalParameters',
    'PSUseOutputTypeCorrectly',
    'PSAvoidTrailingWhitespace',
    'PSReviewUnusedParameter'
    )
  Rules = @{
    PSUseCompatibleSyntax = @{
      TargetVersions = @('5.1')
      Enable         = $true
    }
  }
}
