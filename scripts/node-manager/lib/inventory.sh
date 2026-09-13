# shellcheck shell=bash

# ──────────────────────────────────────────────
# JSON / output parsers (deterministic, read-only)
# ──────────────────────────────────────────────

parse_global_package_names() {
    local json_path="$1"
    ruby -rjson -e '
        data = JSON.parse(File.read(ARGV[0]))
        deps = data["dependencies"] || {}
        puts deps.keys.sort
    ' "$json_path" 2>/dev/null
}

parse_global_package_versions() {
    local json_path="$1"
    ruby -rjson -e '
        data = JSON.parse(File.read(ARGV[0]))
        deps = data["dependencies"] || {}
        deps.keys.sort.each do |name|
          ver = deps[name]["version"] rescue "?"
          puts "#{name}|#{ver}"
        end
    ' "$json_path" 2>/dev/null
}

parse_global_package_versions_stdin() {
    ruby -rjson -e '
        data = JSON.parse(STDIN.read)
        deps = data["dependencies"] || {}
        deps.keys.sort.each do |name|
          ver = deps[name]["version"] rescue "?"
          puts "#{name}|#{ver}"
        end
    ' 2>/dev/null
}

parse_outdated_package_rows() {
    local json_path="$1"
    ruby -rjson -e '
        data = JSON.parse(File.read(ARGV[0]))
        data.keys.sort.each do |name|
          row = data[name] || {}
          puts [name, row["current"], row["wanted"], row["latest"]].join("|")
        end
    ' "$json_path" 2>/dev/null
}

parse_scope_registry_lines() {
    local file_path="$1"
    sed -e 's/[[:space:]]#.*$//' \
        -e 's/^[[:space:]]*//' \
        -e 's/[[:space:]]*$//' "$file_path" \
        | sed -n 's/^\(@[A-Za-z0-9._-][A-Za-z0-9._-]*:registry\)[[:space:]]*=[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}$/\1=\2/p'
}

parse_outdated_package_rows_stdin() {
    ruby -rjson -e '
        data = JSON.parse(STDIN.read)
        data.keys.sort.each do |name|
          row = data[name] || {}
          puts [name, row["current"], row["wanted"], row["latest"]].join("|")
        end
    ' 2>/dev/null
}

# ──────────────────────────────────────────────
# npm global package inventory (read-only)
# ──────────────────────────────────────────────

load_global_package_inventory_json() {
    npm ls -g --depth=0 --json 2>/dev/null
}

get_global_package_names() {
    local json=""
    json="$(load_global_package_inventory_json)" || true
    if [ -n "$json" ]; then
        printf '%s' "$json" | ruby -rjson -e '
            data = JSON.parse(STDIN.read)
            deps = data["dependencies"] || {}
            puts deps.keys.sort
        ' 2>/dev/null
    fi
}

get_global_package_versions() {
    local json=""
    json="$(load_global_package_inventory_json)" || true
    if [ -n "$json" ]; then
        printf '%s' "$json" | ruby -rjson -e '
            data = JSON.parse(STDIN.read)
            deps = data["dependencies"] || {}
            deps.keys.sort.each do |name|
              ver = deps[name]["version"] rescue "?"
              puts "#{name}|#{ver}"
            end
        ' 2>/dev/null
    fi
}

get_package_bin_commands() {
    local package_name="$1"
    local global_root=""
    global_root="$(npm root -g 2>/dev/null || true)"
    local pkg_json="$global_root/$package_name/package.json"

    if [ -f "$pkg_json" ]; then
        parse_package_bin_names "$pkg_json"
    fi
}

parse_package_bin_names() {
    local pkg_json="$1"
    ruby -rjson -e '
        data = JSON.parse(File.read(ARGV[0]))
        name = data["name"].to_s
        bin = data["bin"]
        case bin
        when Hash
          puts bin.keys.sort
        when String
          # A global bin symlink cannot contain "/", so npm links a
          # string-form bin under the unscoped short name for scoped
          # packages (e.g. "@scope/pkg" -> "pkg"), not the full spec.
          short_name = name.include?("/") ? name.split("/").last.to_s : name
          puts short_name unless short_name.empty?
        end
    ' "$pkg_json" 2>/dev/null
}

summarize_package_metadata() {
    local pkg_json="$1"
    [ -f "$pkg_json" ] || return 1

    ruby -rjson -e '
        data = JSON.parse(File.read(ARGV[0]))
        deps = data["dependencies"] || {}
        dev_deps = data["devDependencies"] || {}
        peer_deps = data["peerDependencies"] || {}
        puts "      package.json name: #{data["name"] || "<unknown>"}"
        puts "      package.json version: #{data["version"] || "<unknown>"}"
        puts "      dependencies: #{deps.length}"
        puts "      devDependencies: #{dev_deps.length}"
        puts "      peerDependencies: #{peer_deps.length}"
    ' "$pkg_json" 2>/dev/null
}

resolve_existing_path() {
    local path="$1"
    local dir=""
    local base=""

    dir="$(dirname "$path")"
    base="$(basename "$path")"
    [ -d "$dir" ] || return 1
    printf '%s/%s\n' "$(cd "$dir" 2>/dev/null && pwd -P)" "$base"
}

is_path_within_dir() {
    local path="$1"
    local dir="$2"
    local real_path=""
    local real_dir=""

    real_path="$(resolve_existing_path "$path")" || return 1
    real_dir="$(cd "$dir" 2>/dev/null && pwd -P)" || return 1

    case "$real_path" in
        "$real_dir"/*) return 0 ;;
        *) return 1 ;;
    esac
}

is_safe_removable_child_dir() {
    local path="$1"
    local parent_dir="$2"
    local real_path=""
    local real_parent=""

    [ -d "$path" ] || return 1
    [ -d "$parent_dir" ] || return 1
    real_path="$(cd "$path" 2>/dev/null && pwd -P)" || return 1
    real_parent="$(cd "$parent_dir" 2>/dev/null && pwd -P)" || return 1
    [ "$real_path" != "$real_parent" ] || return 1

    case "$real_path" in
        "$real_parent"/*) return 0 ;;
        *) return 1 ;;
    esac
}

resolve_safe_user_cache_delete_path() {
    local path="$1"
    local resolved_path=""

    [ -n "$path" ] || return 1
    [ -d "$path" ] || return 1

    resolved_path="$(cd "$path" 2>/dev/null && pwd -P)" || return 1

    case "$resolved_path" in
        "$HOME"|"/"|"/tmp"|"/private/tmp")
            return 1
            ;;
        "$HOME"/*|"/tmp"/*|"/private/tmp"/*)
            printf '%s\n' "$resolved_path"
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

is_owned_symlink() {
    local symlink_path="$1"
    local package_dir="$2"
    local target=""

    [ -L "$symlink_path" ] || return 1
    target="$(readlink "$symlink_path" 2>/dev/null)" || return 1
    case "$target" in
        /*) ;;
        *) target="$(dirname "$symlink_path")/$target" ;;
    esac

    is_path_within_dir "$target" "$package_dir"
}

resolve_symlink_target_path() {
    local symlink_path="$1"
    local target=""

    [ -L "$symlink_path" ] || return 1
    target="$(readlink "$symlink_path" 2>/dev/null)" || return 1
    case "$target" in
        /*) ;;
        *) target="$(dirname "$symlink_path")/$target" ;;
    esac
    resolve_existing_path "$target"
}

capture_symlink_snapshot() {
    local symlink_path="$1"
    local package_dir="$2"
    local target=""

    [ -L "$symlink_path" ] || return 1
    target="$(resolve_symlink_target_path "$symlink_path")" || return 1
    is_path_within_dir "$target" "$package_dir" || return 1
    printf '%s|%s|%s\n' "$symlink_path" "$target" "$package_dir"
}

verify_symlink_snapshot_current() {
    local snapshot="$1"
    local symlink_path=""
    local expected_target=""
    local package_dir=""
    local actual_target=""

    IFS='|' read -r symlink_path expected_target package_dir <<< "$snapshot"
    [ -n "$symlink_path" ] && [ -n "$expected_target" ] && [ -n "$package_dir" ] || return 1
    [ -L "$symlink_path" ] || return 1
    actual_target="$(resolve_symlink_target_path "$symlink_path")" || return 1
    [ "$actual_target" = "$expected_target" ] || return 1
    is_path_within_dir "$actual_target" "$package_dir"
}

capture_directory_snapshot() {
    local dir_path="$1"
    local parent_dir="$2"
    local real_dir=""
    local inode=""
    local mtime=""

    is_safe_removable_child_dir "$dir_path" "$parent_dir" || return 1
    real_dir="$(cd "$dir_path" 2>/dev/null && pwd -P)" || return 1
    inode="$(stat -f '%i' "$real_dir" 2>/dev/null || stat -c '%i' "$real_dir" 2>/dev/null || true)"
    mtime="$(stat -f '%m' "$real_dir" 2>/dev/null || stat -c '%Y' "$real_dir" 2>/dev/null || true)"
    [ -n "$inode" ] || return 1
    printf '%s|%s|%s|%s\n' "$real_dir" "$parent_dir" "$inode" "$mtime"
}

verify_directory_snapshot_current() {
    local snapshot="$1"
    local dir_path=""
    local parent_dir=""
    local expected_inode=""
    local expected_mtime=""
    local actual_inode=""
    local actual_mtime=""

    IFS='|' read -r dir_path parent_dir expected_inode expected_mtime <<< "$snapshot"
    [ -n "$dir_path" ] && [ -n "$parent_dir" ] && [ -n "$expected_inode" ] || return 1
    is_safe_removable_child_dir "$dir_path" "$parent_dir" || return 1
    actual_inode="$(stat -f '%i' "$dir_path" 2>/dev/null || stat -c '%i' "$dir_path" 2>/dev/null || true)"
    actual_mtime="$(stat -f '%m' "$dir_path" 2>/dev/null || stat -c '%Y' "$dir_path" 2>/dev/null || true)"
    [ "$actual_inode" = "$expected_inode" ] || return 1
    [ -z "$expected_mtime" ] || [ "$actual_mtime" = "$expected_mtime" ]
}

# Looser than verify_directory_snapshot_current: only confirms the directory
# is still the same one that was snapshotted (via inode) and still safely
# contained under its expected parent. Used to decide whether a directory
# qualifies as a residue *candidate* after an uninstall. mtime is deliberately
# not checked here — a partial `npm uninstall -g` that removes some but not
# all files inside the directory legitimately changes its mtime, and that
# must not disqualify genuine residue from being offered for cleanup.
# verify_directory_snapshot_current (mtime included) remains the right check
# immediately before actually deleting, to catch changes since the candidate
# was shown to the user.
directory_snapshot_inode_matches() {
    local snapshot="$1"
    local dir_path=""
    local parent_dir=""
    local expected_inode=""
    local expected_mtime=""
    local actual_inode=""

    IFS='|' read -r dir_path parent_dir expected_inode expected_mtime <<< "$snapshot"
    [ -n "$dir_path" ] && [ -n "$parent_dir" ] && [ -n "$expected_inode" ] || return 1
    is_safe_removable_child_dir "$dir_path" "$parent_dir" || return 1
    actual_inode="$(stat -f '%i' "$dir_path" 2>/dev/null || stat -c '%i' "$dir_path" 2>/dev/null || true)"
    [ "$actual_inode" = "$expected_inode" ]
}

remove_owned_symlink_residue() {
    local symlink_path="$1"
    local package_dir="$2"

    is_owned_symlink "$symlink_path" "$package_dir" || return 1
    rm -f "$symlink_path" 2>/dev/null || return 1
    [ ! -e "$symlink_path" ] && [ ! -L "$symlink_path" ]
}

remove_snapshot_symlink_residue() {
    local snapshot="$1"
    local symlink_path=""

    verify_symlink_snapshot_current "$snapshot" || return 1
    symlink_path="${snapshot%%|*}"
    rm -f "$symlink_path" 2>/dev/null || return 1
    [ ! -e "$symlink_path" ] && [ ! -L "$symlink_path" ]
}

nvm_version_user_package_count() {
    local version_dir="$1"
    local npm_path="$version_dir/bin/npm"
    local package_json=""

    [ -x "$npm_path" ] || return 2
    package_json="$("$npm_path" ls -g --depth=0 --json 2>/dev/null)" || return 2
    [ -n "$package_json" ] || return 2
    printf '%s' "$package_json" | count_user_global_packages_from_json
}

nvm_version_package_summary() {
    local version_dir="$1"
    local npm_path="$version_dir/bin/npm"
    local package_json=""

    [ -x "$npm_path" ] || return 2
    package_json="$("$npm_path" ls -g --depth=0 --json 2>/dev/null)" || return 2
    [ -n "$package_json" ] || return 2
    printf '%s' "$package_json" | ruby -rjson -e '
        data = JSON.parse(STDIN.read)
        protected = ["npm", "corepack"]
        deps = data["dependencies"] || {}
        user = deps.keys.reject { |name| protected.include?(name) }
        prot = deps.keys.select { |name| protected.include?(name) }
        puts "user=#{user.length}|protected=#{prot.length}|total=#{deps.length}|packages=#{deps.keys.sort.join(",")}"
    ' 2>/dev/null
}

get_package_directory_size() {
    local package_name="$1"
    local global_root=""
    global_root="$(npm root -g 2>/dev/null || true)"
    local pkg_dir="$global_root/$package_name"

    if [ -d "$pkg_dir" ]; then
        du -sh "$pkg_dir" 2>/dev/null | awk '{print $1}'
    fi
}

get_global_bin_dir() {
    local prefix=""
    prefix="$(npm prefix -g 2>/dev/null || true)"
    if [ -z "$prefix" ]; then
        return 1
    fi
    printf '%s/bin' "$prefix"
}

check_bin_entries() {
    local package_name="$1"
    local global_bin_dir="$2"
    local mode="${3:-list}" # list or residue

    local bin_cmds=""
    bin_cmds="$(get_package_bin_commands "$package_name" 2>/dev/null || true)"
    [ -n "$bin_cmds" ] || return 0
    [ -d "$global_bin_dir" ] || return 0

    # Use here-string to avoid pipe subshell issues and ensure trailing newline
    # read -r handles the last line correctly with <<< even without trailing \n
    while IFS= read -r cmd; do
        [ -n "$cmd" ] || continue
        local bin_path="$global_bin_dir/$cmd"
        if [ -e "$bin_path" ] || [ -L "$bin_path" ]; then
            if [ "$mode" = "residue" ]; then
                printf "%s " "$cmd"
            else
                local bin_type="file"
                [ -L "$bin_path" ] && bin_type="symlink"
                printf "    %s %s\n" "$bin_path" "$bin_type"
            fi
        fi
    done <<< "$bin_cmds"
}

get_installed_global_package_version() {
    local package_name="$1"
    local json=""
    json="$(npm ls -g "$package_name" --depth=0 --json 2>/dev/null || true)"
    if [ -n "$json" ]; then
        printf '%s' "$json" | ruby -rjson -e '
            d = JSON.parse(STDIN.read)
            v = d.dig("dependencies",ARGV[0],"version")
            puts v || ""
        ' "$package_name" 2>/dev/null || true
    fi
}

validate_json_text() {
    command_exists ruby || return 2
    ruby -rjson -e 'JSON.parse(STDIN.read)' >/dev/null 2>&1
}

count_user_global_packages_from_json() {
    command_exists ruby || return 2
    ruby -rjson -e '
        data = JSON.parse(STDIN.read)
        protected = ["npm", "corepack"]
        deps = data["dependencies"] || {}
        puts deps.keys.reject { |name| protected.include?(name) }.length
    ' 2>/dev/null
}

detect_node_gyp_cache_dir() {
    detect_node_gyp_cache_dirs | sed -n '1s/|.*$//p'
}

detect_node_gyp_cache_dirs() {
    local devdir="${npm_config_devdir:-}"
    if [ -n "$devdir" ]; then
        printf '%s|npm_config_devdir\n' "$devdir"
    fi

    if command_exists npm; then
        devdir="$(npm config get devdir 2>/dev/null || true)"
        case "$devdir" in
            ""|"undefined"|"null") ;;
            *) printf '%s|npm-config-devdir\n' "$devdir" ;;
        esac
    fi

    printf '%s|legacy-home\n' "$HOME/.node-gyp"
    printf '%s|macos-cache\n' "$HOME/Library/Caches/node-gyp"
    if command_exists npm; then
        local npm_cache=""
        npm_cache="$(npm config get cache 2>/dev/null || true)"
        case "$npm_cache" in
            ""|"undefined"|"null") ;;
            *) printf '%s|npm-cache-derived\n' "$npm_cache/node-gyp" ;;
        esac
    fi
}
