# REA: Examples

```bash
$prompt = "Inspect `C:\Users\ssp\AppData\Local\Programs\Typora` with REA"
Invoke-AgentHarness -Provider Kilo -Pick -McpServer bs -YOLO -MaxSubAgents 4 -McpServer 'rea' -Skill 'reverse-engineer-anything' -MaxToolOutputChars 32768
```