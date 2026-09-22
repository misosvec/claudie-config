{{- $specName          := .Data.Provider.SpecName }}
{{- $uniqueFingerPrint := .Fingerprint }}
{{- $resourceSuffix    := printf "%s_%s" $specName $uniqueFingerPrint }}

provider "vastai" {
  api_key = file("{{ $specName }}")
  alias = "networking_{{ $resourceSuffix }}_personal"
}

{{- if .Data.Provider.GetVastai.TeamApiKey }}
provider "vastai" {
  api_key = "{{ .Data.Provider.GetVastai.TeamApiKey }}"
  alias = "networking_{{ $resourceSuffix }}_team"
}
{{- end }}
