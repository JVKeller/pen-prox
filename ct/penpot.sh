#!/usr/bin/env bash
_cs_boot="${COMMUNITY_SCRIPTS_CORE_DIR:-$(dirname "${BASH_SOURCE[0]}")/../../core}/core/build.func"
source "$_cs_boot" 2>/dev/null || source <(curl -fsSL "${COMMUNITY_SCRIPTS_CORE_URL:-https://raw.githubusercontent.com/community-scripts/core/main}/core/build.func")
# Copyright (c) 2021-2026 community-scripts ORG
# Author: Jeff Keller (mahoutcomputer)
# License: MIT | https://github.com/community-scripts/ProxmoxVED/raw/main/LICENSE
# Source: https://penpot.app | https://github.com/penpot/penpot

APP="Penpot"
var_tags="${var_tags:-design;ui-ux}"
var_cpu="${var_cpu:-4}"
var_ram="${var_ram:-8192}"
var_disk="${var_disk:-40}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -d /opt/penpot ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi

  if check_for_gh_release "penpot" "penpot/penpot"; then
    msg_info "Stopping Services"
    systemctl stop penpot-mcp penpot-exporter penpot-backend
    msg_ok "Stopped Services"

    rm -rf /opt/penpot-src
    fetch_and_deploy_gh_release "penpot" "penpot/penpot" "tarball" "latest" "/opt/penpot-src"

    msg_info "Rebuilding ${APP} from source (30-90 min)"
    $STD /opt/penpot/build.sh "$(cat ~/.penpot 2>/dev/null || echo latest)"
    msg_ok "Rebuilt ${APP}"

    msg_info "Starting Services"
    systemctl start penpot-backend penpot-exporter penpot-mcp
    systemctl reload nginx
    msg_ok "Started Services"
    msg_ok "Updated successfully!"
  fi
  exit
}

start
build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Access it using the following URL:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}${CL}"
