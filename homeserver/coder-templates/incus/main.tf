terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = "~>2"
    }
    incus = {
      source  = "lxc/incus"
      version = "~>1.0"
    }
  }
}

data "coder_provisioner" "me" {}

provider "incus" {}

data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

data "coder_parameter" "image" {
  name         = "image"
  display_name = "Image"
  description  = "The container image to use. Must have cloud-init installed."
  default      = "images:debian/12/cloud"
  icon         = "/icon/image.svg"
  mutable      = false

  option {
    name  = "Debian 13 (Trixie)"
    value = "images:debian/13/cloud"
  }
  option {
    name  = "Debian 12 (Bookworm)"
    value = "images:debian/12/cloud"
  }
  option {
    name  = "Ubuntu 24.04 (Noble)"
    value = "images:ubuntu/24.04/cloud"
  }
  option {
    name  = "Ubuntu 22.04 (Jammy)"
    value = "images:ubuntu/22.04/cloud"
  }

}

data "coder_parameter" "cpu" {
  name         = "cpu"
  display_name = "CPU"
  description  = "The number of CPUs to allocate to the workspace (1-8)"
  type         = "number"
  default      = "1"
  icon         = "https://raw.githubusercontent.com/matifali/logos/main/cpu-3.svg"
  mutable      = true
  validation {
    min = 1
    max = 8
  }
}

data "coder_parameter" "memory" {
  name         = "memory"
  display_name = "Memory"
  description  = "The amount of memory to allocate to the workspace in GB (up to 16GB)"
  type         = "number"
  default      = "2"
  icon         = "/icon/memory.svg"
  mutable      = true
  validation {
    min = 1
    max = 16
  }
}

data "coder_parameter" "git_repo" {
  type        = "string"
  name        = "Git repository"
  default     = ""
  description = "Clone a git repo inside the workspace"
  mutable     = true
}

data "coder_parameter" "pool" {
  type         = "string"
  name         = "pool"
  display_name = "Storage pool"
  default      = "coder"
  description  = "Incus storage pool name"
  mutable      = false
}

resource "coder_agent" "main" {
  count = data.coder_workspace.me.start_count
  arch  = data.coder_provisioner.me.arch
  os    = "linux"
  dir   = "/home/${local.workspace_user}"
  env = {
    CODER_WORKSPACE_ID  = data.coder_workspace.me.id
    CODER_SESSION_TOKEN = data.coder_workspace_owner.me.session_token
    CODER_URL           = data.coder_workspace.me.access_url
  }

  metadata {
    display_name = "CPU Usage"
    key          = "0_cpu_usage"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "RAM Usage"
    key          = "1_ram_usage"
    script       = "coder stat mem"
    interval     = 10
    timeout      = 1
  }
}

resource "incus_storage_volume" "home" {
  name = "coder-${data.coder_workspace.me.id}-home"
  pool = local.pool
}

resource "incus_instance" "dev" {
  running = data.coder_workspace.me.start_count == 1
  name    = "coder-${lower(data.coder_workspace_owner.me.name)}-${lower(data.coder_workspace.me.name)}"
  image   = data.coder_parameter.image.value

  config = {
    "limits.cpu"     = data.coder_parameter.cpu.value
    "limits.memory"  = "${data.coder_parameter.memory.value}GiB"
    "boot.autostart" = true

    # Pass the agent token and URL via Incus user config keys.
    # These are readable from inside the container via the guest API at
    # /dev/incus/sock, which removes the need for bind-mounting files from
    # the host. This decouples the provisioner from the Incus host. They
    # no longer need to share a filesystem. The token is refreshed by
    # Terraform on every workspace start; Incus updates the config on the
    # instance even while it is stopped, so the new value is available
    # immediately when the container boots.
    "user.coder_agent_token" = local.agent_token
    "user.coder_agent_url"   = data.coder_workspace.me.access_url

    "cloud-init.user-data" = <<EOF
#cloud-config
hostname: ${lower(data.coder_workspace.me.name)}
users:
  - name: ${local.workspace_user}
    uid: 1000
    groups: sudo
    shell: /bin/bash
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
write_files:
  # Pre-start script that reads the agent token and URL from the Incus guest
  # API (/dev/incus/sock) and writes them to an env file. This runs as a
  # separate oneshot unit (coder-agent-config.service) before the agent starts,
  # ensuring the env file is always fresh. This approach:
  #  - Eliminates host filesystem coupling (no bind mounts for token or binary)
  #  - Allows the provisioner to run on a different host than Incus
  #  - Delivers a fresh agent token on every start without cloud-init re-runs
  - path: /opt/coder/fetch-config.sh
    permissions: "0755"
    content: |
      #!/bin/bash
      set -euo pipefail

      INCUS_SOCK="/dev/incus/sock"

      # Read agent config from Incus guest API.
      CODER_AGENT_TOKEN=$(curl -sf --unix-socket "$INCUS_SOCK" http://localhost/1.0/config/user.coder_agent_token)
      CODER_AGENT_URL=$(curl -sf --unix-socket "$INCUS_SOCK" http://localhost/1.0/config/user.coder_agent_url)

      # Write env file for the systemd service.
      printf 'CODER_AGENT_TOKEN=%s\nCODER_AGENT_URL=%s\n' "$CODER_AGENT_TOKEN" "$CODER_AGENT_URL" > /opt/coder/init.env
  # The standard Coder agent init script, provided by coder_agent.init_script.
  # This handles downloading the correct agent binary and running it.
  - path: /opt/coder/coder-init.sh
    permissions: "0755"
    encoding: b64
    content: ${base64encode(local.agent_init_script)}
  - path: /etc/systemd/system/coder-agent-config.service
    permissions: "0644"
    content: |
      [Unit]
      Description=Fetch Coder Agent Config from Incus Guest API
      After=network-online.target
      Wants=network-online.target

      [Service]
      Type=oneshot
      ExecStart=/opt/coder/fetch-config.sh
  # Watcher script that listens for config changes via the Incus guest API
  # events endpoint. The Incus Terraform provider starts the instance before
  # updating config keys, so on a stop->start cycle the agent initially boots
  # with a stale token. This watcher detects when user.coder_agent_token is
  # updated, re-fetches the config, and restarts the agent with the new token.
  - path: /opt/coder/watch-config.sh
    permissions: "0755"
    content: |
      #!/bin/bash
      INCUS_SOCK="/dev/incus/sock"
      curl -sfN --unix-socket "$INCUS_SOCK" http://localhost/1.0/events?type=config | \
        while read -r event; do
          key=$(echo "$event" | sed -n 's/.*"key":"\([^"]*\)".*/\1/p')
          if [ "$key" = "user.coder_agent_token" ]; then
            /opt/coder/fetch-config.sh
            systemctl restart coder-agent.service
          fi
        done
  - path: /etc/systemd/system/coder-agent-watcher.service
    permissions: "0644"
    content: |
      [Unit]
      Description=Watch for Coder Agent config changes via Incus Guest API
      After=network-online.target
      Wants=network-online.target

      [Service]
      ExecStart=/opt/coder/watch-config.sh
      Restart=always
      RestartSec=5

      [Install]
      WantedBy=multi-user.target
  - path: /etc/systemd/system/coder-agent.service
    permissions: "0644"
    content: |
      [Unit]
      Description=Coder Agent
      After=network-online.target coder-agent-config.service
      Wants=network-online.target
      Requires=coder-agent-config.service

      [Service]
      User=${local.workspace_user}
      EnvironmentFile=/opt/coder/init.env
      ExecStart=/opt/coder/coder-init.sh
      Restart=always
      RestartSec=10
      TimeoutStopSec=90
      KillMode=process
      OOMScoreAdjust=-900
      SyslogIdentifier=coder-agent

      [Install]
      WantedBy=multi-user.target
runcmd:
  - chown -R ${local.workspace_user}:${local.workspace_user} /home/${local.workspace_user}
  # Install package dependencies before starting the agent.
  - apt-get update && apt-get install -y curl git zsh tmux fzf zoxide stow
  - usermod -s /usr/bin/zsh ${local.workspace_user}
  - systemctl daemon-reload
  - systemctl enable coder-agent.service coder-agent-watcher.service
  - systemctl start coder-agent.service coder-agent-watcher.service
EOF
  }

  device {
    name = "home"
    type = "disk"
    properties = {
      path   = "/home/${local.workspace_user}"
      pool   = local.pool
      source = incus_storage_volume.home.name
    }
  }

  device {
    name = "root"
    type = "disk"
    properties = {
      path = "/"
      pool = local.pool
    }
  }
}

locals {
  workspace_user = lower(data.coder_workspace_owner.me.name)
  pool           = data.coder_parameter.pool.value
  sn_web_repo = contains([
    "git@github.com:BeSecondNature/sn-web.git",
    "git@github.com:BeSecondNature/sn-web",
    "https://github.com/BeSecondNature/sn-web.git",
    "https://github.com/BeSecondNature/sn-web",
  ], data.coder_parameter.git_repo.value)
  # Workaround for the LXC provider stripping empty string config values, causing unexpected new values.
  agent_token       = data.coder_workspace.me.start_count == 1 ? coder_agent.main[0].token : "no-token"
  agent_init_script = data.coder_workspace.me.start_count == 1 ? coder_agent.main[0].init_script : "#!/bin/sh\nexit 0"
}

resource "coder_metadata" "info" {
  count       = data.coder_workspace.me.start_count
  resource_id = coder_agent.main[0].id
  item {
    key   = "memory"
    value = incus_instance.dev.config["limits.memory"]
  }
  item {
    key   = "cpus"
    value = incus_instance.dev.config["limits.cpu"]
  }
  item {
    key   = "instance"
    value = incus_instance.dev.name
  }
  item {
    key   = "image"
    value = data.coder_parameter.image.value
  }
}

module "code-server" {
  source                = "registry.coder.com/coder/code-server/coder"
  version               = "~> 1.0"
  agent_id              = coder_agent.main[0].id
  count                 = data.coder_workspace.me.start_count
  folder                = local.sn_web_repo ? "/home/${local.workspace_user}/sn-web" : ""
  extensions            = local.sn_web_repo ? ["oxc.oxc-vscode", "dbaeumer.vscode-eslint", "bradlc.vscode-tailwindcss"] : []
  use_cached_extensions = true
}

module "git-clone" {
  count             = data.coder_workspace.me.start_count == 1 && data.coder_parameter.git_repo.value != "" ? 1 : 0
  source            = "registry.coder.com/coder/git-clone/coder"
  version           = "~> 2.0"
  agent_id          = coder_agent.main[0].id
  url               = data.coder_parameter.git_repo.value
  base_dir          = "/home/${local.workspace_user}"
  post_clone_script = local.sn_web_repo ? file("${path.module}/sn-web-setup.sh") : null
}
