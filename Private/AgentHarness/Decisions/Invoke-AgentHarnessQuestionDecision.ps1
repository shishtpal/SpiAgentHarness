function Invoke-AgentHarnessQuestionDecision {
    param([hashtable]$Arguments, [hashtable]$Context, [Collections.IDictionary]$Definition)

    $result = & $Context.DecisionState.Invoke $Definition $Arguments.state $Arguments.questions $Arguments.attachments $Context.Root
    $result | Select-Object Answers, Summary, RequestedModel, Model, Provider, ServedBy, Id, Usage, ElapsedMilliseconds
}