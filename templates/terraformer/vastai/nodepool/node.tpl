{{- $clusterName           := .Data.ClusterData.ClusterName}}
{{- $clusterHash           := .Data.ClusterData.ClusterHash}}
{{- $uniqueFingerPrint     := .Fingerprint }}
{{- $isKubernetesCluster   := eq .Data.ClusterData.ClusterType "K8s" }}
{{- $isLoadbalancerCluster := eq .Data.ClusterData.ClusterType "LB" }}


{{- $nodepool        := .Data.NodePool }}
{{- $specName        := $nodepool.Details.Provider.SpecName }}
{{- $resourceSuffix  := printf "%s_%s" $specName $uniqueFingerPrint }}
{{- $networking      := .Data.Networking.All }}
{{- $claudieSshPort  := index $networking (printf "claudie_ssh_port_%s" $resourceSuffix) }}
{{- $bootstrapScript := index $networking (printf "vastai_bootstrap_script_%s" $resourceSuffix) }}
{{- $firewallScript  := index $networking (printf "vastai_firewall_script_%s" $resourceSuffix) }}

{{- if not $claudieSshPort }}{{ template "node.tpl: missing output 'claudie_ssh_port_<specName>_<fingerprint>' from the networking stage in .Networking.All" }}{{ end }}
{{- if not $bootstrapScript }}{{ template "node.tpl: missing output 'vastai_bootstrap_script_<specName>_<fingerprint>' from the networking stage in .Networking.All" }}{{ end }}
{{- if not $firewallScript }}{{ template "node.tpl: missing output 'vastai_firewall_script_<specName>_<fingerprint>' from the networking stage in .Networking.All" }}{{ end }}

{{/*
  Instances are rented with the team API key when one is configured, otherwise
  with the personal key. The SSH key has to live on the same account, as Vast.ai
  requires a key on the renting account before a VM can be created.
*/}}
{{- $account := "personal" }}
{{- if $nodepool.Details.Provider.GetVastai.GetTeamApiKey }}{{ $account = "team" }}{{ end }}
{{- $providerAlias := printf "vastai.nodepool_%s_%s" $resourceSuffix $account }}

{{/*
  Offers are one machine slot each, so every node needs its own. Request a few
  more than the nodepool size so a slot taken between search and rent does not
  starve the last nodes.
*/}}
{{- $nodeCount    := len $nodepool.Nodes }}
{{- $offerLimit   := add $nodeCount 3 }}
{{- $offersData   := printf "vm_offers_%s" $resourceSuffix }}
{{- $offersLocal  := printf "local.vm_offers_%s" $resourceSuffix }}

data "http" "{{ $offersData }}" {
  url    = "https://console.vast.ai/api/v0/bundles/"
  method = "POST"

  request_headers = {
    Authorization  = "Bearer ${trimspace(file("{{ $specName }}"))}"
    "Content-Type" = "application/json"
  }

  request_body = jsonencode({
    type        = "ondemand"
    verified    = { eq = true }
#   datacenter  = { eq = true }
    rentable    = { eq = true }
    rented      = { eq = false }
    reliability = { gte = 0.92 }
    vms_enabled = { eq = true }
    num_gpus    = { eq = 1 }
#   duration    = { gte = 2592000 }
#   inet_down   = { gte = 300 }
    disk_space  = { gte = {{ $nodepool.Details.StorageDiskSize }} }
    limit       = {{ $offerLimit }}
    order       = [["dph_total", "asc"]]
  })
}

locals {
  # Cheapest first, as ordered by the query above.
  vm_offers_{{ $resourceSuffix }} = try(jsondecode(data.http.{{ $offersData }}.response_body).offers, [])
}

{{- $sshKeyResourceName := printf "key_%s_%s" $nodepool.Name $resourceSuffix }}

resource "vastai_ssh_key" "{{ $sshKeyResourceName }}" {
  provider   = {{ $providerAlias }}
  public_key = file("./{{ $nodepool.Name }}")
}

{{- range $i, $node := $nodepool.Nodes }}

{{- $serverResourceName := printf "%s_%s" $node.Name $resourceSuffix }}

resource "vastai_instance" "{{ $serverResourceName }}" {
  provider       = {{ $providerAlias }}
  depends_on     = [vastai_ssh_key.{{ $sshKeyResourceName }}]
  # Node {{ $i }} takes the {{ $i }}-th cheapest offer. The offer id only matters at
  # creation: the search re-runs on every plan and the cheapest offers change
  # constantly, so without ignore_changes every reconcile would replace the VM.
  id             = try({{ $offersLocal }}[{{ $i }}].id, null)
  label          = "{{ $serverResourceName }}"
  image          = "{{ $nodepool.Details.Image }}"
  disk           = {{ $nodepool.Details.StorageDiskSize }}
  cancel_unavail = true
  vm             = true
  runtype        = "ssh"
  # Publish the Claudie SSH port and WireGuard on the host so the node is
  # reachable through Vast.ai's NAT; the mapped host ports are read back from
  # `ports` in the output below.
  env            = "-p {{ $claudieSshPort }}:{{ $claudieSshPort }} -p 51820:51820/udp"
  onstart        = <<-EOF
#!/bin/bash
{{ $bootstrapScript }}

# Configure iptables firewall (not UFW, KubeOne disables UFW)
{{ $firewallScript }}

{{- if $isKubernetesCluster }}
# Longhorn data directory on the OS disk. Vast.ai exposes no separate volume
# to attach to a VM here, so data shares the OS disk sized by storageDiskSize.
mkdir -p /opt/claudie/data
{{- end }}{{/* if $isKubernetesCluster */}}
EOF

  lifecycle {
    ignore_changes = [id]
    precondition {
      condition     = length({{ $offersLocal }}) > {{ $i }}
      error_message = "Vast.ai returned ${length({{ $offersLocal }})} matching VM offers, but nodepool {{ $nodepool.Name }} needs at least {{ add $i 1 }} (requested {{ $offerLimit }}) to place node {{ $node.Name }}."
    }
  }
}

{{- end }}{{/* range $nodepool.Nodes */}}

# Output: [public_ip, ssh_port, wireguard_port] per node.
#
# Vast.ai VMs sit behind the host's NAT on a shared public IP. `ports` maps each
# published in-VM port ("<port>/<proto>") to the host port it is reachable on, so
# SSH is the host port mapped to <claudie_ssh_port>/tcp and WireGuard the host
# port mapped to 51820/udp. If a mapping is missing the in-VM port is used as-is.
output "{{ $nodepool.Name }}_{{ $specName }}_{{ $uniqueFingerPrint }}" {
  value = {
    {{- range $node := $nodepool.Nodes }}
    {{- $serverResourceName := printf "%s_%s" $node.Name $resourceSuffix }}
    "{{ $node.Name }}" = [
      vastai_instance.{{ $serverResourceName }}.public_ipaddr,
      tostring(try(vastai_instance.{{ $serverResourceName }}.ports["{{ $claudieSshPort }}/tcp"], {{ $claudieSshPort }})),
      tostring(try(vastai_instance.{{ $serverResourceName }}.ports["51820/udp"], 51820)),
    ]
    {{- end }}
  }
}
