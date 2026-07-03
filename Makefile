SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

ANSIBLE_INVENTORY ?= ansible/inventory.ini
SNAPSHOT ?= clean
SSH_USER ?= dev

.PHONY: help doctor host-bootstrap import-xray up transparent-enable host-transparent-enable host-transparent-status host-transparent-disable kali-transparent-enable ssh ssh-agent vnc-enable host-vnc-expose host-vnc-status host-vnc-unexpose egress-check snapshot restore destroy check

help: ## Show available targets
	@awk 'BEGIN {FS = ":.*##"; printf "Targets:\n"} /^[a-zA-Z0-9_-]+:.*##/ {printf "  %-16s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

doctor: ## Check local config and remote host prerequisites without changing state
	@bash scripts/doctor.sh

host-bootstrap: ## Install host dependencies with Ansible; copy inventory.example.ini first
	@test -f "$(ANSIBLE_INVENTORY)" || { echo "missing $(ANSIBLE_INVENTORY); copy ansible/inventory.example.ini first" >&2; exit 2; }
	@ansible-playbook -i "$(ANSIBLE_INVENTORY)" ansible/host-bootstrap.yml

import-xray: ## Convert local Xray 10811 outbound chain into ignored sing-box outbounds
	@python3 scripts/import_xray_outbounds.py

up: ## Create/update the single Kali dev VM on the remote KVM host
	@bash scripts/up.sh

transparent-enable: ## Enable host-scoped transparent proxy for Kali and remove VM proxy env
	@bash scripts/transparent-enable.sh

host-transparent-enable: ## Install/restart host-scoped sing-box TProxy gateway only
	@bash scripts/host-transparent-enable.sh

host-transparent-status: ## Show host-scoped transparent gateway status
	@bash scripts/host-transparent-status.sh

host-transparent-disable: ## Disable host-scoped transparent gateway without changing host default egress
	@bash scripts/host-transparent-disable.sh

kali-transparent-enable: ## Configure Kali route/DNS for host transparent gateway only
	@bash scripts/kali-transparent-enable.sh

ssh: ## SSH into Kali dev VM through the remote host; override with SSH_USER=agent
	@SSH_USER="$(SSH_USER)" bash scripts/ssh.sh

ssh-agent: ## SSH into the unprivileged agent user inside Kali
	@SSH_USER=agent bash scripts/ssh.sh

vnc-enable: ## Install/start TigerVNC desktop inside Kali
	@bash scripts/vnc-enable.sh

host-vnc-expose: ## Expose Kali VNC on remote host LAN IP; defaults to CHANGE_ME_HOST:5900
	@bash scripts/host-vnc-expose.sh

host-vnc-status: ## Show remote host VNC proxy status
	@bash scripts/host-vnc-status.sh

host-vnc-unexpose: ## Remove remote host VNC proxy
	@bash scripts/host-vnc-unexpose.sh

egress-check: ## Run isolation, DNS, egress and timezone checks from inside Kali
	@bash scripts/egress-check.sh

snapshot: ## Create libvirt snapshot for the Kali VM; override with SNAPSHOT=name
	@bash scripts/snapshot.sh "$(SNAPSHOT)"

restore: ## Restore the Kali VM to SNAPSHOT=name
	@test -n "$(SNAPSHOT)" || { echo "set SNAPSHOT=name" >&2; exit 2; }
	@bash scripts/restore.sh "$(SNAPSHOT)"

destroy: ## Destroy VMs/network and generated runtime state; use PURGE=1 to remove images
	@bash scripts/destroy.sh

check: ## Static validation for shell, Python and JSON examples
	@bash scripts/check.sh
