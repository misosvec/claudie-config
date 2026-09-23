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
{{- $wireguardPort   := index $networking (printf "claudie_wireguard_port_%s" $resourceSuffix) }}
{{- $bootstrapScript := index $networking (printf "vastai_bootstrap_script_%s" $resourceSuffix) }}
{{- $firewallScript  := index $networking (printf "vastai_firewall_script_%s" $resourceSuffix) }}
{{- if not $claudieSshPort }}{{ template "node.tpl: missing output 'claudie_ssh_port_<specName>_<fingerprint>' from the networking stage in .Networking.All" }}{{ end }}
{{- if not $wireguardPort }}{{ template "node.tpl: missing output 'claudie_wireguard_port_<specName>_<fingerprint>' from the networking stage in .Networking.All" }}{{ end }}
{{- if not $bootstrapScript }}{{ template "node.tpl: missing output 'vastai_bootstrap_script_<specName>_<fingerprint>' from the networking stage in .Networking.All" }}{{ end }}
{{- if not $firewallScript }}{{ template "node.tpl: missing output 'vastai_firewall_script_<specName>_<fingerprint>' from the networking stage in .Networking.All" }}{{ end }}

# Instances are rented with the team API key when one is configured, otherwise with the personal key.
# SSH keys are always created with the personal API key.
# Vast.ai does not support SSH keys on a team accountKeys are held per user, and a key registered
# by a team member applies to the instances rented under that team.
{{- $account := "personal" }}
{{- if $nodepool.Details.Provider.GetVastai.GetTeamApiKey }}{{ $account = "team" }}{{ end }}
{{- $teamOrPersonalAlias := printf "vastai.nodepool_%s_%s" $resourceSuffix $account }}
{{- $personalAlias := printf "vastai.nodepool_%s_personal" $resourceSuffix }}

{{- $sshKeyResourceName := printf "key_%s_%s" $nodepool.Name $resourceSuffix }}
resource "vastai_ssh_key" "{{ $sshKeyResourceName }}" {
  provider   = {{ $personalAlias }}
  public_key = file("./{{ $nodepool.Name }}")
}

# This template is generated separately for each nodepool, and the resulting Terraform runs execute in parallel.
# Because of this, multiple runs may select the same cheapest offers at the same time, causing a race condition
# when renting the machines. A delay is added to reduce the likelihood of this happening. If a conflict still
# occurs, it can be resolved by retrying the Terraform run.
resource "random_integer" "delay_slot_{{ $resourceSuffix }}" {
  min = 0
  max = 5
}

# Waits 0 to 35 seconds in 7 second steps. Two nodepools that draw the same
# slot can still collide, in which case the tofu apply retry picks a new offer.
resource "time_sleep" "delay_{{ $resourceSuffix }}" {
  depends_on      = [vastai_ssh_key.{{ $sshKeyResourceName }}]
  create_duration = "${random_integer.delay_slot_{{ $resourceSuffix }}.result * 7}s"
}


# Offers are one machine slot each, so every node needs its own. Request a few
# more than the nodepool size so a slot taken between search and rent does not
# starve the last nodes.
{{- $nodeCount    := len $nodepool.Nodes }}
{{- $offerLimit   := add $nodeCount 5 }}
{{- $offersData   := printf "vm_offers_%s" $resourceSuffix }}
{{- $offersLocal  := printf "local.vm_offers_%s" $resourceSuffix }}

# Depending on the sleep defers this read from plan time to apply time, so the
# list is fetched right before renting, after this nodepool's turn has come.
data "http" "{{ $offersData }}" {
  depends_on = [time_sleep.delay_{{ $resourceSuffix }}]

  url    = "https://console.vast.ai/api/v0/bundles/"
  method = "POST"

  request_headers = {
    Authorization  = "Bearer ${trimspace(file("{{ $specName }}"))}"
    "Content-Type" = "application/json"
  }

# often getting empty offers when datacenter = { eq = true }
  request_body = jsonencode({
    type        	= "ondemand"
    verified    	= { eq = true }
    rentable    	= { eq = true }
    rented      	= { eq = false }
    reliability 	= { gte = 0.98 }
    vms_enabled 	= { eq = true }
    static_ip		= { eq = true }
    num_gpus    	= { eq = {{ $nodepool.Details.MachineSpec.NvidiaGpuCount }} }
    gpu_name    	= { eq = "{{ $nodepool.Details.MachineSpec.NvidiaGpuType }}"}
    gpu_total_ram   = { gte = {{ $nodepool.Details.MachineSpec.Memory }} }
    cpu_cores 		= { gte = {{ $nodepool.Details.MachineSpec.CpuCount }} }
    disk_space 		= { gte = {{ $nodepool.Details.StorageDiskSize }} }
    geolocation 	= { in = local.geolocations }
    duration    	= { gte = 2592000 }
    inet_down   	= { gte = 300 }
    limit       	= {{ $offerLimit }}
    order       	= [["dph_total", "asc"]]
  })

  lifecycle {
    # Without this an auth or API error decodes to an empty offer list and is
    # reported as "no offers available".
    postcondition {
      condition     = self.status_code == 200
      error_message = "Vast.ai offers query failed with HTTP ${self.status_code}: ${self.response_body}"
    }

    # A 200 with too few offers means nothing on the marketplace matches the
    # filters right now. Fail here, once, and say which filters were applied.
    postcondition {
      condition     = length(try(jsondecode(self.response_body).offers, [])) >= {{ $nodeCount }}
      error_message = <<-EOT
        Vast.ai returned ${length(try(jsondecode(self.response_body).offers, []))} VM offers, but nodepool {{ $nodepool.Name }} has {{ $nodeCount }} node(s) and needs one offer per node.
        Filters: on-demand, verified, datacenter, static IP, reliability >= 0.98, VMs enabled,
          {{ $nodepool.Details.MachineSpec.NvidiaGpuCount }}x "{{ $nodepool.Details.MachineSpec.NvidiaGpuType }}", GPU RAM >= {{ $nodepool.Details.MachineSpec.Memory }}, CPU cores >= {{ $nodepool.Details.MachineSpec.CpuCount }},
          disk >= {{ $nodepool.Details.StorageDiskSize }} GB, geolocation in ${jsonencode(local.geolocations)}, duration >= 30 days, download >= 300 Mbps.
        Relax machineSpec, storageDiskSize or region in the InputManifest, or retry later.
      EOT
    }
  }
}

locals {
  vm_offers_{{ $resourceSuffix }} = try(jsondecode(data.http.{{ $offersData }}.response_body).offers, [])
  geolocations = [
     for r in split(",", "{{ $nodepool.Details.Region }}") :
     upper(trimspace(r)) if trimspace(r) != ""
   ]
}

{{- range $i, $node := $nodepool.Nodes }}

{{- $serverResourceName := printf "%s_%s" $node.Name $resourceSuffix }}

# Node i takes the i-th cheapest offer, so nodes of one nodepool never pick
# the same machine slot.
resource "vastai_instance" "{{ $serverResourceName }}" {
  depends_on     = [vastai_ssh_key.{{ $sshKeyResourceName }}]
  provider       = {{ $teamOrPersonalAlias }}
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
  env            = "-p {{ $claudieSshPort }}:{{ $claudieSshPort }} -p {{ $wireguardPort }}:{{ $wireguardPort }}/udp"
  onstart        = <<-EOF
#!/bin/bash
{{ $bootstrapScript }}

{{ $firewallScript }}

{{- if $isKubernetesCluster }}
# Longhorn data directory on the OS disk. Vast.ai exposes no separate volume
# to attach to a VM here, so data shares the OS disk sized by storageDiskSize.
mkdir -p /opt/claudie/data
{{- end }}{{/* if $isKubernetesCluster */}}
EOF

  lifecycle {
    # The offer id only matters when the instance is created. The search above
    # re-runs on every plan and the cheapest offers change constantly, so
    # without this every reconcile would see a different id and replace the VM.
    ignore_changes = [id]
  }
}

{{- end }}{{/* range $nodepool.Nodes */}}

# Output: [public_ip, ssh_port, wireguard_port] per node.
#
# Vast.ai VMs sit behind the host's NAT on a shared public IP. `ports` maps each
# published in-VM port ("<port>/<proto>") to the host port it is reachable on, so
# SSH is the host port mapped to <claudie_ssh_port>/tcp and WireGuard the host
# port mapped to <claudie_wireguard_port>/udp. If a mapping is missing the in-VM
# port is used as-is.
output "{{ $nodepool.Name }}_{{ $specName }}_{{ $uniqueFingerPrint }}" {
  value = {
    {{- range $node := $nodepool.Nodes }}
    {{- $serverResourceName := printf "%s_%s" $node.Name $resourceSuffix }}
    "{{ $node.Name }}" = [
      vastai_instance.{{ $serverResourceName }}.public_ipaddr,
      tostring(try(vastai_instance.{{ $serverResourceName }}.ports["{{ $claudieSshPort }}/tcp"], {{ $claudieSshPort }})),
      tostring(try(vastai_instance.{{ $serverResourceName }}.ports["{{ $wireguardPort }}/udp"], {{ $wireguardPort }})),
    ]
    {{- end }}
  }
}
