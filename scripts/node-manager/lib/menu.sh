# shellcheck shell=bash

# ──────────────────────────────────────────────
# Menu rendering
# ──────────────────────────────────────────────

render_main_menu() {
    cat <<'EOF'
1) 安装项目
2) 卸载项目
3) 更新与升级
4) 源管理
5) 环境与依赖
q) 退出
EOF
}

render_install_menu() {
    cat <<'EOF'
1) 单独安装 global package
2) 批量安装内置清单
b) 返回上一级
EOF
}

render_uninstall_menu() {
    cat <<'EOF'
1) 卸载 global package
b) 返回上一级
EOF
}

render_update_menu() {
    cat <<'EOF'
1) 扫描并升级已安装 global package
2) 指定包升级到 latest
b) 返回上一级
EOF
}

render_source_menu() {
    cat <<'EOF'
1) 查看源配置
2) 切换 registry
3) 管理 scope registry
4) 删除用户级 registry
b) 返回上一级
EOF
}

render_environment_menu() {
    cat <<'EOF'
1) 环境总览
2) 安装 nvm
3) 安装 Node.js 版本
4) 更改全局 Node 版本
5) 卸载 Node.js 版本
6) 指定项目 Node 版本
7) 清理 npm 环境
b) 返回上一级
EOF
}

# ──────────────────────────────────────────────
# Menu dispatch helpers
# ──────────────────────────────────────────────

should_exit_menu() {
    local menu_name="$1"
    local choice="$2"

    if [ "$menu_name" = "main" ] && { [ "$choice" = "q" ] || [ "$choice" = "Q" ]; }; then
        echo "1"
        return 0
    fi

    echo "0"
}

dispatch_main_choice() {
    local choice="$1"

    case "$choice" in
        1) echo "install" ;;
        2) echo "uninstall" ;;
        3) echo "update" ;;
        4) echo "source-management" ;;
        5) echo "environment" ;;
        *) echo "invalid" ;;
    esac
}

dispatch_install_choice() {
    local choice="$1"

    case "$choice" in
        1) echo "single-install" ;;
        2) echo "batch-install" ;;
        b|B) echo "back" ;;
        *) echo "invalid" ;;
    esac
}

dispatch_uninstall_choice() {
    local choice="$1"

    case "$choice" in
        1) echo "uninstall-package" ;;
        b|B) echo "back" ;;
        *) echo "invalid" ;;
    esac
}

dispatch_update_choice() {
    local choice="$1"

    case "$choice" in
        1) echo "scan-upgrade" ;;
        2) echo "upgrade-latest" ;;
        b|B) echo "back" ;;
        *) echo "invalid" ;;
    esac
}

dispatch_source_choice() {
    local choice="$1"

    case "$choice" in
        1) echo "view-source" ;;
        2) echo "switch-registry" ;;
        3) echo "scope-registry" ;;
        4) echo "reset-registry" ;;
        b|B) echo "back" ;;
        *) echo "invalid" ;;
    esac
}

dispatch_environment_choice() {
    local choice="$1"

    case "$choice" in
        1) echo "overview" ;;
        2) echo "install-nvm" ;;
        3) echo "install-node" ;;
        4) echo "switch-node" ;;
        5) echo "uninstall-node" ;;
        6) echo "project-node" ;;
        7) echo "cleanup" ;;
        b|B) echo "back" ;;
        *) echo "invalid" ;;
    esac
}
