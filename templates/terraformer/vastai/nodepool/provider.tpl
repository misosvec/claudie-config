{{- $nodepool          := .Data.NodePool }}
{{- $specName          := $nodepool.Details.Provider.SpecName }}
{{- $uniqueFingerPrint := .Fingerprint }}
{{- $resourceSuffix    := printf "%s_%s" $specName $uniqueFingerPrint }}

provider "vastai" {
  api_key = file("{{ $specName }}")
  alias = "nodepool_{{ $resourceSuffix }}_personal"
}

{{- if $nodepool.Details.Provider.GetVastai.TeamApiKey }}
provider "vastai" {
  api_key = "{{ $nodepool.Details.Provider.GetVastai.TeamApiKey }}"
  alias = "nodepool_{{ $resourceSuffix }}_team"
}
{{- end }}
