# shellcheck shell=bash

render_dry_run_plan() {
    cat <<EOF
INFO
runtimeDir=$(manager_runtime_dir)
logDir=$(manager_log_dir)
tmpDir=$(manager_tmp_dir)
configDir=$CONFIG_DIR
behavior=Informational only; use JSON plan/execute/status/logs contracts for app wrappers.
supportedJsonCommands=summary,packages,outdated,config,package-plan,plan,execute,status,logs,logs-cleanup,operation-result
EOF
}

render_test_mode_status() {
    cat <<EOF
TEST MODE
runtimeDir=$(manager_runtime_dir)
logDir=$(manager_log_dir)
tmpDir=$(manager_tmp_dir)
platform=$(platform_uname)
EOF
}
