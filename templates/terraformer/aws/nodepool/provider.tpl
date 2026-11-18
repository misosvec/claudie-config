{{- $nodepool          := .Data.NodePool }}
{{- $specName          := $nodepool.Details.Provider.SpecName }}
{{- $uniqueFingerPrint := .Fingerprint }}
{{- $region            := $nodepool.Details.Region }}
{{- $resourceSuffix    := printf "%s_%s_%s" $region $specName $uniqueFingerPrint }}

provider "aws" {
  access_key = "{{ $nodepool.Details.Provider.GetAws.AccessKey }}"
  secret_key = file("{{ $specName }}")
  region     = "{{ $region }}"
  alias      = "nodepool_{{ $resourceSuffix }}"
  # max_retries is the total number of attempts: 1 = no retries. 0 is ignored
  max_retries = 1
  endpoints {
     ec2 = "http://127.0.0.1:1"  # nothing listens here, so every call fails with a retryable error
  }
  default_tags {
    tags = {
      Managed-by = "Claudie"
    }
  }
}
