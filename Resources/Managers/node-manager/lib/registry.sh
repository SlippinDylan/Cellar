# shellcheck shell=bash

# ──────────────────────────────────────────────
# Protected package logic
# ──────────────────────────────────────────────

is_protected_global_package() {
    local package_name="$1"
    local item=""
    for item in "${PROTECTED_GLOBAL_PACKAGES[@]}"; do
        [ "$item" = "$package_name" ] && return 0
    done
    return 1
}

# ──────────────────────────────────────────────
# Registry helpers (read-only)
# ──────────────────────────────────────────────

get_current_registry() {
    npm config get registry 2>/dev/null || true
}

npm_config_get_layer() {
    local key="$1"
    local location="$2"
    local config_file=""
    local value=""
    local value_exit=0

    if [ "$location" = "effective" ]; then
        npm config get "$key" 2>/dev/null
        return $?
    fi

    config_file="$(npm_config_file_for_layer "$location")" || {
        printf '<unavailable>\n'
        return 1
    }
    if [ ! -f "$config_file" ]; then
        printf 'undefined\n'
        return 0
    fi
    value="$(npmrc_explicit_value "$config_file" "$key")" || value_exit=$?
    case "$value_exit" in
        0) printf '%s\n' "$value" ;;
        1) printf 'undefined\n' ;;
        *)
            printf '<unavailable>\n'
            return 2
            ;;
    esac
}

npm_config_file_for_layer() {
    local location="$1"
    local prefix=""

    case "$location" in
        user)
            npm config get userconfig 2>/dev/null
            ;;
        global)
            npm config get globalconfig 2>/dev/null
            ;;
        project)
            prefix="$(npm prefix 2>/dev/null)" || return 1
            [ -n "$prefix" ] || return 1
            printf '%s/.npmrc\n' "$prefix"
            ;;
        *)
            return 1
            ;;
    esac
}

npmrc_explicit_value() {
    local config_file="$1"
    local key="$2"

    ruby -e '
      config_file, wanted = ARGV
      found = nil
      begin
        File.foreach(config_file) do |line|
          stripped = line.strip
          next if stripped.empty? || stripped.start_with?("#", ";")
          name, value = line.split("=", 2)
          next unless value && name.strip == wanted
          value = value.strip
          quote = value[0]
          if value.length >= 2 && quote == value[-1] && ["\"", 39.chr].include?(quote)
            value = value[1...-1]
          end
          found = value
        end
      rescue SystemCallError, ArgumentError
        exit 2
      end
      exit 1 if found.nil?
      puts found
    ' "$config_file" "$key" 2>/dev/null
}

load_explicit_scope_registry_lines() {
    local location="$1"
    local config_file=""

    config_file="$(npm_config_file_for_layer "$location")" || return 1
    [ -f "$config_file" ] || return 0
    parse_scope_registry_lines "$config_file"
}

load_effective_scope_registry_lines() {
    local config_text=""

    config_text="$(npm config list -l 2>/dev/null)" || return 1
    printf '%s\n' "$config_text" \
        | grep -E '^@[^:]+:registry[[:space:]]*=' \
        | sed -n 's/^\(@[A-Za-z0-9._-][A-Za-z0-9._-]*:registry\)[[:space:]]*=[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}$/\1=\2/p' \
        || true
}

normalize_npm_config_value() {
    local value="${1:-}"
    case "$value" in
        ""|"undefined"|"null") printf '<unset>\n' ;;
        *) printf '%s\n' "$value" ;;
    esac
}

print_scope_registry_layers() {
    local scope_name="$1"
    validate_scope_name "$scope_name" || return 1

    printf "%s:registry\n" "$scope_name"
    printf "  effective: %s\n" "$(normalize_npm_config_value "$(npm config get "${scope_name}:registry" 2>/dev/null || true)")"
    printf "  user (--location=user): %s\n" "$(normalize_npm_config_value "$(npm_config_get_layer "${scope_name}:registry" user)")"
    printf "  project (--location=project): %s\n" "$(normalize_npm_config_value "$(npm_config_get_layer "${scope_name}:registry" project)")"
    printf "  global (--location=global): %s\n" "$(normalize_npm_config_value "$(npm_config_get_layer "${scope_name}:registry" global)")"
}

get_npm_cache_path() {
    local cache_path=""

    cache_path="$(npm config get cache 2>/dev/null)" || return 1
    case "$cache_path" in
        ""|undefined|null) return 1 ;;
    esac
    printf '%s\n' "$cache_path"
}

# ──────────────────────────────────────────────
# Registry mutation helpers (with verification)
# ──────────────────────────────────────────────

set_registry_value() {
    local registry_url="$1"
    local expected_user_value="${2-__unchecked__}"
    local before_user_value=""
    local user_value=""
    local effective_value=""

    command_exists ruby || return 127
    validate_registry_url "$registry_url" || return 1
    acquire_runtime_lock "npm-mutation" || return 1
    if [ "$expected_user_value" != "__unchecked__" ]; then
        before_user_value="$(npm_config_get_layer registry user)" || {
            release_runtime_lock "npm-mutation"
            return 1
        }
        if [ "$before_user_value" != "$expected_user_value" ]; then
            release_runtime_lock "npm-mutation"
            printf 'state-changed\n'
            return 3
        fi
    fi
    npm config set registry "$registry_url" --location=user || {
        release_runtime_lock "npm-mutation"
        return 1
    }
    user_value="$(npm_config_get_layer registry user)" || {
        release_runtime_lock "npm-mutation"
        return 1
    }
    effective_value="$(npm config get registry 2>/dev/null || true)"
    release_runtime_lock "npm-mutation"
    [ "$user_value" = "$registry_url" ] || return 1

    if [ "$effective_value" = "$registry_url" ]; then
        printf 'effective-ok\n'
    else
        printf 'effective-mismatch:%s\n' "${effective_value:-<unavailable>}"
    fi
    return 0
}

delete_registry_value() {
    local expected_user_value="${1-__unchecked__}"
    local before_user_value=""
    local value=""

    command_exists ruby || return 127
    acquire_runtime_lock "npm-mutation" || return 1
    if [ "$expected_user_value" != "__unchecked__" ]; then
        before_user_value="$(npm_config_get_layer registry user)" || {
            release_runtime_lock "npm-mutation"
            return 1
        }
        if [ "$before_user_value" != "$expected_user_value" ]; then
            release_runtime_lock "npm-mutation"
            printf 'state-changed\n'
            return 3
        fi
    fi
    npm config delete registry --location=user || {
        release_runtime_lock "npm-mutation"
        return 1
    }
    value="$(npm_config_get_layer registry user)" || {
        release_runtime_lock "npm-mutation"
        return 1
    }
    release_runtime_lock "npm-mutation"
    [ -z "$value" ] || [ "$value" = "undefined" ] || [ "$value" = "null" ]
}

set_scope_registry_value() {
    local scope_name="$1"
    local registry_url="$2"
    local expected_user_value="${3-__unchecked__}"
    local before_user_value=""
    local user_value=""
    local effective_value=""

    command_exists ruby || return 127
    validate_scope_name "$scope_name" || return 1
    validate_registry_url "$registry_url" || return 1
    acquire_runtime_lock "npm-mutation" || return 1
    if [ "$expected_user_value" != "__unchecked__" ]; then
        before_user_value="$(npm_config_get_layer "${scope_name}:registry" user)" || {
            release_runtime_lock "npm-mutation"
            return 1
        }
        if [ "$before_user_value" != "$expected_user_value" ]; then
            release_runtime_lock "npm-mutation"
            printf 'state-changed\n'
            return 3
        fi
    fi
    npm config set "${scope_name}:registry" "$registry_url" --location=user || {
        release_runtime_lock "npm-mutation"
        return 1
    }
    user_value="$(npm_config_get_layer "${scope_name}:registry" user)" || {
        release_runtime_lock "npm-mutation"
        return 1
    }
    effective_value="$(npm config get "${scope_name}:registry" 2>/dev/null || true)"
    release_runtime_lock "npm-mutation"
    [ "$user_value" = "$registry_url" ] || return 1

    if [ "$effective_value" = "$registry_url" ]; then
        printf 'effective-ok\n'
    else
        printf 'effective-mismatch:%s\n' "${effective_value:-<unavailable>}"
    fi
    return 0
}

delete_scope_registry_value() {
    local scope_name="$1"
    local expected_user_value="${2-__unchecked__}"
    local before_user_value=""
    local value=""

    command_exists ruby || return 127
    validate_scope_name "$scope_name" || return 1
    acquire_runtime_lock "npm-mutation" || return 1
    if [ "$expected_user_value" != "__unchecked__" ]; then
        before_user_value="$(npm_config_get_layer "${scope_name}:registry" user)" || {
            release_runtime_lock "npm-mutation"
            return 1
        }
        if [ "$before_user_value" != "$expected_user_value" ]; then
            release_runtime_lock "npm-mutation"
            printf 'state-changed\n'
            return 3
        fi
    fi
    npm config delete "${scope_name}:registry" --location=user || {
        release_runtime_lock "npm-mutation"
        return 1
    }
    value="$(npm_config_get_layer "${scope_name}:registry" user)" || {
        release_runtime_lock "npm-mutation"
        return 1
    }
    release_runtime_lock "npm-mutation"
    [ -z "$value" ] || [ "$value" = "undefined" ] || [ "$value" = "null" ]
}

verify_scope_registry_deleted_user_layer() {
    local scope_name="$1"
    local user_value=""
    local effective_value=""

    validate_scope_name "$scope_name" || return 1
    user_value="$(npm_config_get_layer "${scope_name}:registry" user)" || {
        print_status_message "fail" "无法读取用户级 scope registry 配置"
        return 1
    }
    if [ -n "$user_value" ] && [ "$user_value" != "undefined" ] && [ "$user_value" != "null" ]; then
        print_status_message "warn" "用户级 scope registry 删除后仍存在: $user_value"
        return 1
    fi

    if ! effective_value="$(npm_config_get_layer "${scope_name}:registry" effective)"; then
        print_status_message "ok" "用户级 scope registry 已删除"
        print_status_message "warn" "无法读取删除后的 effective scope registry"
        return 0
    fi
    if [ -n "$effective_value" ] && [ "$effective_value" != "undefined" ] && [ "$effective_value" != "null" ]; then
        print_status_message "ok" "用户级 scope registry 已删除"
        print_status_message "warn" "project/global/builtin 仍提供 effective scope registry: $effective_value"
        return 0
    fi

    print_status_message "ok" "scope registry 已删除"
    return 0
}

# ──────────────────────────────────────────────
# Flow: source management
# ──────────────────────────────────────────────

run_source_overview() {
    local registry=""
    local user_npmrc=""
    local project_npmrc=""

    print_page_title "查看源配置"

    user_npmrc="$(npm_config_file_for_layer user 2>/dev/null || true)"
    project_npmrc="$(npm_config_file_for_layer project 2>/dev/null || true)"
    registry="$(get_current_registry)"

    printf "当前 registry: %s\n" "${registry:-<unavailable>}"
    print_blank_line

    printf "用户级 .npmrc: %s\n" "${user_npmrc:-<unavailable>}"
    if [ -n "$user_npmrc" ] && [ -f "$user_npmrc" ]; then
        printf "  状态: 存在\n"
    else
        printf "  状态: 不存在\n"
    fi
    print_blank_line

    printf "项目级 .npmrc: %s\n" "${project_npmrc:-<unavailable>}"
    if [ -n "$project_npmrc" ] && [ -f "$project_npmrc" ]; then
        printf "  状态: 存在\n"
    else
        printf "  状态: 不存在\n"
    fi
    print_blank_line

    # Scope registries
    printf "Scope Registry 配置:\n"
    print_separator
    local scope_lines=""
    if [ -n "$user_npmrc" ] && [ -f "$user_npmrc" ]; then
        scope_lines="$(parse_scope_registry_lines "$user_npmrc")"
    fi

    # Also check npm config list for scope registries. `npm config list -l`
    # prints `@scope:registry = "url"` (spaces + quotes) while
    # parse_scope_registry_lines prints the canonical `@scope:registry=url`
    # (no spaces, no quotes) parsed straight from .npmrc. Normalize this
    # stream to the same canonical shape before combining, otherwise the
    # same scope shows up twice below (sort -u can't dedupe two different
    # textual representations of the same value).
    local config_scopes=""
    local config_scopes_available="yes"
    config_scopes="$(load_effective_scope_registry_lines)" || config_scopes_available="no"
    local combined_scope_lines=""
    combined_scope_lines="$({
        printf '%s\n' "$scope_lines"
        printf '%s\n' "$config_scopes"
    } | sed '/^$/d' | sort -u)"
    if [ -n "$combined_scope_lines" ]; then
        printf "%s\n" "$combined_scope_lines"
    fi

    if [ -z "$combined_scope_lines" ]; then
        if [ "$config_scopes_available" = "yes" ]; then
            printf "  <无>\n"
        else
            printf "  <effective npm config 无法读取>\n"
        fi
    else
        print_blank_line
        printf "Scope Registry 分层:\n"
        local scope_key=""
        local scope_name=""
        printf '%s\n' "$combined_scope_lines" | sed 's/:registry[[:space:]]*=.*$//' | sort -u | while IFS= read -r scope_key; do
            scope_name="$(trim_whitespace "$scope_key")"
            [ -n "$scope_name" ] || continue
            print_scope_registry_layers "$scope_name" || true
        done
    fi

    # npm config summary (key config items)
    print_blank_line
    printf "npm config 分层摘要:\n"
    print_separator
    local key=""
    for key in registry cache prefix; do
        printf "%s:\n" "$key"
        printf "  effective: %s\n" "$(normalize_npm_config_value "$(npm config get "$key" 2>/dev/null || true)")"
        printf "  user (--location=user): %s\n" "$(normalize_npm_config_value "$(npm_config_get_layer "$key" user)")"
        printf "  project (--location=project): %s\n" "$(normalize_npm_config_value "$(npm_config_get_layer "$key" project)")"
        printf "  global (--location=global): %s\n" "$(normalize_npm_config_value "$(npm_config_get_layer "$key" global)")"
    done

    print_blank_line
    printf "npmrc 文件路径:\n"
    printf "  userconfig: %s\n" "$(npm config get userconfig 2>/dev/null || true)"
    printf "  globalconfig: %s\n" "$(npm config get globalconfig 2>/dev/null || true)"

    pause_before_return
}

run_switch_registry_flow() {
    local choice=""
    local registry_url=""
    local current_registry=""
    local user_registry=""

    current_registry="$(get_current_registry)"
    if ! user_registry="$(npm_config_get_layer registry user)"; then
        print_status_message "fail" "无法读取用户级 registry 配置"
        pause_before_return
        return 1
    fi

    print_page_title "切换 registry"
    printf "当前 registry: %s\n" "${current_registry:-<unavailable>}"
    printf "用户级 registry: %s\n" "${user_registry:-undefined}"
    print_blank_line

    printf "1) npm 官方源 https://registry.npmjs.org/\n"
    printf "2) npmmirror 源 https://registry.npmmirror.com/\n"
    printf "3) 自定义 registry\n"
    printf "b) 返回\n"
    print_blank_line
    printf "请选择: "
    read -r choice || return 0

    case "$choice" in
        1) registry_url="https://registry.npmjs.org/" ;;
        2) registry_url="https://registry.npmmirror.com/" ;;
        3)
            printf "请输入自定义 registry URL: "
            read -r registry_url || return 0
            registry_url="$(trim_whitespace "$registry_url")"
            [ -n "$registry_url" ] || return 0
            registry_url="$(normalize_registry_url_trailing_slash "$registry_url")"
            ;;
        b|B) return 0 ;;
        *)
            print_status_message "warn" "输入无效。"
            pause_before_return
            return 0
            ;;
    esac

    if ! validate_registry_url "$registry_url"; then
        print_status_message "fail" "registry URL 格式不支持: $registry_url"
        printf "registry URL 必须使用 https:// 并以 / 结尾；本机调试仅允许 http://localhost:<port>/ 或 http://127.0.0.1:<port>/。\n"
        pause_before_return
        return 1
    fi

    print_blank_line
    printf "准备切换 registry 到: %s\n" "$registry_url"
    if ! prompt_yes_no "确认切换？" "y"; then
        return 0
    fi

    print_blank_line
    printf "执行切换...\n"
    print_separator
    local set_status=""
    if set_status="$(set_registry_value "$registry_url" "$user_registry")"; then
        local actual_registry=""
        actual_registry="$(get_current_registry)"
        print_blank_line
        print_status_message "ok" "用户级 registry 写入成功"
        printf "  切换前: %s\n" "$current_registry"
        printf "  切换后: %s\n" "$actual_registry"
        case "$set_status" in
            effective-ok)
                print_status_message "ok" "effective registry 已生效"
                ;;
            effective-mismatch:*)
                print_status_message "warn" "effective registry 被 project、环境变量或 CLI 等更高优先级配置覆盖"
                printf "  期望 effective: %s\n" "$registry_url"
                printf "  实际 effective: %s\n" "${set_status#effective-mismatch:}"
                ;;
            *)
                print_status_message "warn" "effective registry 状态未知"
                ;;
        esac
        if [ "$actual_registry" != "$registry_url" ]; then
            print_status_message "warn" "安装命令当前仍会使用: $actual_registry"
        fi
    else
        if [ "$set_status" = "state-changed" ]; then
            print_status_message "fail" "确认后用户级 registry 已变化，已取消覆盖"
        else
            print_status_message "fail" "registry 切换失败"
        fi
        printf "  当前 registry: %s\n" "$(get_current_registry)"
    fi

    pause_before_return
}

run_reset_registry_flow() {
    local current_registry=""
    local user_registry=""
    local effective_registry=""

    print_page_title "删除用户级 registry"

    current_registry="$(get_current_registry)"
    if ! user_registry="$(npm_config_get_layer registry user)"; then
        print_status_message "fail" "无法读取用户级 registry 配置，已取消删除"
        pause_before_return
        return 1
    fi

    printf "当前 effective registry: %s\n" "${current_registry:-<unavailable>}"
    printf "用户级 registry: %s\n" "${user_registry:-undefined}"
    case "$user_registry" in
        ""|undefined|null)
            printf "当前没有显式的用户级 registry 配置，无需删除。\n"
            pause_before_return
            return 0
            ;;
    esac
    print_blank_line
    printf "将只删除用户级 registry 配置，npm 会回退到项目级/global/builtin/effective 配置。\n"
    if ! prompt_yes_no "确认删除用户级 registry？" "n"; then
        return 0
    fi

    print_blank_line
    local delete_status=""
    if delete_status="$(delete_registry_value "$user_registry")"; then
        effective_registry="$(get_current_registry)"
        print_status_message "ok" "用户级 registry 已删除"
        printf "  当前 effective registry: %s\n" "${effective_registry:-<unavailable>}"
    else
        if [ "$delete_status" = "state-changed" ]; then
            print_status_message "fail" "确认后用户级 registry 已变化，已取消删除"
        else
            print_status_message "fail" "用户级 registry 删除失败"
        fi
        printf "  当前 user registry: %s\n" "$(npm_config_get_layer registry user 2>/dev/null || printf '<unavailable>')"
    fi

    pause_before_return
}

run_scope_registry_flow() {
    local choice=""
    local scope_name=""
    local registry_url=""
    local config_scopes=""

    while true; do
    print_page_title "管理 scope registry"

    printf "1) 添加 scope registry\n"
    printf "2) 删除 scope registry\n"
    printf "3) 查看所有 scope registry\n"
    printf "4) 查看指定 scope registry\n"
    printf "b) 返回\n"
    print_blank_line
    printf "请选择: "
    read -r choice || return 0

    case "$choice" in
        1)
            printf "请输入 scope 名称(例如 @company): "
            read -r scope_name || return 0
            scope_name="$(trim_whitespace "$scope_name")"
            [ -n "$scope_name" ] || return 0
            if ! validate_scope_name "$scope_name"; then
                print_status_message "fail" "scope 名称格式不支持: $scope_name"
                pause_before_return
                return 1
            fi

            printf "请输入 registry URL: "
            read -r registry_url || return 0
            registry_url="$(trim_whitespace "$registry_url")"
            [ -n "$registry_url" ] || return 0
            registry_url="$(normalize_registry_url_trailing_slash "$registry_url")"
            if ! validate_registry_url "$registry_url"; then
                print_status_message "fail" "registry URL 格式不支持: $registry_url"
                printf "registry URL 必须使用 https:// 并以 / 结尾；本机调试仅允许 http://localhost:<port>/ 或 http://127.0.0.1:<port>/。\n"
                pause_before_return
                return 1
            fi

            print_blank_line
            local existing_scope_registry=""
            local existing_user_scope_registry=""
            existing_scope_registry="$(npm config get "${scope_name}:registry" 2>/dev/null || true)"
            if ! existing_user_scope_registry="$(npm_config_get_layer "${scope_name}:registry" user)"; then
                print_status_message "fail" "无法读取用户级 scope registry 配置"
                pause_before_return
                return 1
            fi
            if [ -n "$existing_scope_registry" ] && [ "$existing_scope_registry" != "undefined" ] && [ "$existing_scope_registry" != "null" ]; then
                printf "当前 %s:registry = %s\n" "$scope_name" "$existing_scope_registry"
                printf "当前用户级值 = %s\n" "${existing_user_scope_registry:-undefined}"
                printf "准备覆盖为   %s:registry = %s\n" "$scope_name" "$registry_url"
            else
                printf "准备设置 %s:registry = %s\n" "$scope_name" "$registry_url"
            fi
            if ! prompt_yes_no "确认添加？" "y"; then
                return 0
            fi

            print_blank_line
            local set_status=""
            if set_status="$(set_scope_registry_value "$scope_name" "$registry_url" "$existing_user_scope_registry")"; then
                print_status_message "ok" "scope registry 已添加"
                printf "  %s:registry = %s\n" "$scope_name" "$(npm config get "${scope_name}:registry" 2>/dev/null || true)"
                case "$set_status" in
                    effective-ok)
                        print_status_message "ok" "effective scope registry 已生效"
                        ;;
                    effective-mismatch:*)
                        print_status_message "warn" "effective scope registry 被 project、环境变量或 CLI 等更高优先级配置覆盖"
                        printf "  期望 effective: %s\n" "$registry_url"
                        printf "  实际 effective: %s\n" "${set_status#effective-mismatch:}"
                        ;;
                esac
            else
                if [ "$set_status" = "state-changed" ]; then
                    print_status_message "fail" "确认后用户级 scope registry 已变化，已取消覆盖"
                else
                    print_status_message "fail" "scope registry 添加失败"
                fi
            fi
            pause_before_return
            ;;
        2)
            # Deletion is intentionally user-layer only, so do not offer
            # project/global values that this action cannot remove.
            if ! config_scopes="$(load_explicit_scope_registry_lines user)"; then
                print_status_message "fail" "无法读取用户级 scope registry 配置"
                pause_before_return
                return 1
            fi
            if [ -z "$config_scopes" ]; then
                printf "当前没有用户级 scope registry 配置。\n"
                pause_before_return
                return 0
            fi

            printf "当前用户级 scope registry:\n"
            printf "%s\n" "$config_scopes"
            print_blank_line

            printf "请输入要删除的 scope 名称(例如 @company): "
            read -r scope_name || return 0
            scope_name="$(trim_whitespace "$scope_name")"
            [ -n "$scope_name" ] || return 0
            if ! validate_scope_name "$scope_name"; then
                print_status_message "fail" "scope 名称格式不支持: $scope_name"
                pause_before_return
                return 1
            fi

            print_blank_line
            local deleting_user_scope_registry=""
            if ! deleting_user_scope_registry="$(npm_config_get_layer "${scope_name}:registry" user)"; then
                print_status_message "fail" "无法读取用户级 scope registry 配置"
                pause_before_return
                return 1
            fi
            case "$deleting_user_scope_registry" in
                ""|undefined|null)
                    printf "%s 没有显式的用户级 registry 配置，无需删除。\n" "$scope_name"
                    pause_before_return
                    continue
                    ;;
            esac
            printf "准备删除 %s:registry\n" "$scope_name"
            printf "  用户级值: %s\n" "$deleting_user_scope_registry"
            if ! prompt_yes_no "确认删除？" "n"; then
                return 0
            fi

            print_blank_line
            local delete_scope_status=""
            if delete_scope_status="$(delete_scope_registry_value "$scope_name" "$deleting_user_scope_registry")"; then
                verify_scope_registry_deleted_user_layer "$scope_name" || true
            else
                if [ "$delete_scope_status" = "state-changed" ]; then
                    print_status_message "fail" "确认后用户级 scope registry 已变化，已取消删除"
                else
                    print_status_message "fail" "用户级 scope registry 删除失败"
                fi
                printf "  user: %s\n" "$(npm_config_get_layer "${scope_name}:registry" user)"
            fi
            pause_before_return
            ;;
        3)
            print_page_title "查看 scope registry"
            if ! config_scopes="$(load_effective_scope_registry_lines)"; then
                print_status_message "fail" "无法读取 effective scope registry 配置"
                pause_before_return
                continue
            fi
            if [ -n "$config_scopes" ]; then
                printf "%s\n" "$config_scopes"
            else
                printf "当前没有 scope registry 配置。\n"
            fi
            pause_before_return
            ;;
        4)
            printf "请输入 scope 名称(例如 @company): "
            read -r scope_name || return 0
            scope_name="$(trim_whitespace "$scope_name")"
            [ -n "$scope_name" ] || return 0
            if ! validate_scope_name "$scope_name"; then
                print_status_message "fail" "scope 名称格式不支持: $scope_name"
                pause_before_return
                return 1
            fi

            print_blank_line
            local scope_value=""
            scope_value="$(npm config get "${scope_name}:registry" 2>/dev/null || true)"
            if [ -n "$scope_value" ] && [ "$scope_value" != "undefined" ]; then
                print_scope_registry_layers "$scope_name"
            else
                printf "%s 未配置 registry。\n" "$scope_name"
            fi
            pause_before_return
            ;;
        b|B) return 0 ;;
        *)
            print_status_message "warn" "输入无效。"
            pause_before_return
            ;;
    esac
    done
}

run_source_menu() {
    local choice=""
    local action=""

    while true; do
        print_page_title "源管理"
        render_source_menu
        print_blank_line
        printf "请输入序号: "
        if ! read -r choice; then
            return 0
        fi

        action="$(dispatch_source_choice "$choice")"
        case "$action" in
            view-source)
                require_capabilities npm ruby || continue
                run_source_overview
                ;;
            switch-registry)
                require_capabilities npm ruby || continue
                run_switch_registry_flow
                ;;
            scope-registry)
                require_capabilities npm ruby || continue
                run_scope_registry_flow
                ;;
            reset-registry)
                require_capabilities npm ruby || continue
                run_reset_registry_flow
                ;;
            back)
                return 0
                ;;
            *)
                print_status_message "warn" "输入无效，请输入 1、2、3、4 或 b。"
                pause_before_return
                ;;
        esac
    done
}
