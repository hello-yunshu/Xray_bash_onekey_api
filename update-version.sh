#!/bin/bash

online_version_file="./xray_shell_versions.json"
tested_versions_file="./tested_versions.json"
shell_repo="hello-yunshu/Xray_bash_onekey"
shell_raw_base="https://raw.githubusercontent.com/${shell_repo}"
shell_install_url="${shell_raw_base}/main/install.sh"

# 检查是否需要强制重新生成
force_regen=false
if [[ "$1" == "--force" ]]; then
  force_regen=true
fi

# 读取 tested_versions 文件
declare -A tested_versions
while IFS='=' read -r key value; do
    tested_versions["$key"]=$value
done < <(jq -r 'to_entries[] | "\(.key)=\(.value)"' "$tested_versions_file")

get_shell_version_from_content() {
    grep "shell_version=" | head -1 | awk -F '=|"' '{print $3}'
}

get_shell_upgrade_details() {
    local target_version="$1"
    local commits_json sha version_at_sha matched_message message source_at_sha page shas

    page=1
    while true; do
        commits_json=$(curl -fsSL "https://api.github.com/repos/${shell_repo}/commits?path=install.sh&per_page=100&page=${page}")
        shas=$(printf '%s\n' "$commits_json" | jq -r '.[].sha')

        [[ -z "$shas" ]] && break

        while IFS= read -r sha; do
            [[ -z "$sha" ]] && continue

            source_at_sha=$(curl -fsSL "${shell_raw_base}/${sha}/install.sh")
            version_at_sha=$(printf '%s\n' "$source_at_sha" | get_shell_version_from_content)

            if [[ "$version_at_sha" == "$target_version" ]]; then
                message=$(printf '%s\n' "$commits_json" | jq -r --arg sha "$sha" '.[] | select(.sha == $sha) | .commit.message | split("\n")[0]')
                matched_message="$message"
                continue
            fi

            if [[ -n "$matched_message" ]]; then
                printf '%s\n' "$matched_message"
                return 0
            fi
        done < <(printf '%s\n' "$shas")

        page=$((page + 1))
    done

    if [[ -n "$matched_message" ]]; then
        printf '%s\n' "$matched_message"
        return 0
    fi

    echo "无法找到 shell_version ${target_version} 对应的 install.sh 提交" >&2
    return 1
}

# 获取在线版本
declare -A online_versions

shell_install_source=$(curl -fsSL "$shell_install_url")
online_versions["shell"]=$(printf '%s\n' "$shell_install_source" | get_shell_version_from_content)
online_versions["xray"]=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r .tag_name | sed 's/v//g')
online_versions["nginx"]=$(curl -s https://api.github.com/repos/nginx/nginx/tags | jq -r .[].name | sed 's/release-//g' | grep "1\.[0-9][02468]\.*" | head -1)
online_versions["openssl"]=$(curl -s https://api.github.com/repos/openssl/openssl/tags | jq -r .[].name | grep "3\.[0-9]\.[0-9]" | grep -v "3\.[0-9]\.[0-9]-" | awk -F '-' '{print $2}' | head -1)
online_versions["jemalloc"]=$(curl -s https://api.github.com/repos/jemalloc/jemalloc/releases/latest | jq -r .tag_name | head -1)
online_versions["nginx_build"]=$(curl -s https://api.github.com/repos/hello-yunshu/Xray_bash_onekey_Nginx/releases/latest | jq -r '.tag_name' | sed 's/v//g')

# 检查是否所有在线版本都已成功获取
for key in "${!online_versions[@]}"; do
    if [[ ${online_versions[$key]} == '' ]]; then
        echo -e "无法获取 ${key} 的在线版本"
        exit 1
    fi
done

# 加载现有版本文件
current_versions=$(cat ${online_version_file})

# 初始化更新标志和 JSON 数据
update_required=false
new_json=$(echo "{}")

# 添加更新日期
new_json=$(echo "$new_json" | jq --arg date "$(date '+%Y-%m-%d %H:%M')" '. * {"update_date": $date}')

# 检查每个组件的版本
for key in "${!tested_versions[@]}"; do
    current_value=$(echo "$current_versions" | jq -r ".${key}_online_version")
    new_value=${online_versions[$key]}
    
    # 更新 JSON 数据
    new_json=$(echo "$new_json" | jq --arg key "$key" --arg value "$new_value" '. * {"\($key)_online_version": $value}')
    new_json=$(echo "$new_json" | jq --arg key "$key" --arg value "${tested_versions[$key]}" '. * {"\($key)_tested_version": $value}')
    
    # 检查是否需要更新
    if [[ ${current_value} != ${new_value} || $force_regen == true ]]; then
        update_required=true
        if [[ $key == "shell" ]]; then
            if ! shell_upgrade_details=$(get_shell_upgrade_details "$new_value"); then
                exit 1
            fi
            new_json=$(echo "$new_json" | jq --arg details "$shell_upgrade_details" '. * {"shell_upgrade_details": $details}')
        fi
    else
        if [[ $key == "shell" ]]; then
            existing_upgrade_details=$(echo "$current_versions" | jq -r ".shell_upgrade_details")
            new_json=$(echo "$new_json" | jq --arg details "$existing_upgrade_details" '. * {"shell_upgrade_details": $details}')
        fi
    fi
done

# 记录更新检查时间
check_time=$(date '+%Y-%m-%d %H:%M:%S')

# 收集更新信息
if $update_required; then
    # 记录需要更新的组件
    updated_components=""
    for key in "${!tested_versions[@]}"; do
        current_value=$(echo "$current_versions" | jq -r ".${key}_online_version")
        new_value=${online_versions[$key]}
        if [[ ${current_value} != ${new_value} ]]; then
            updated_components+="${key}: ${current_value} → ${new_value}\\n"
        fi
    done
    
    # 执行更新操作
    echo "$new_json" >${online_version_file}
    
    git config --global user.name "github-actions[bot]"
    git config --global user.email "41898282+github-actions[bot]@users.noreply.github.com"
    git add ./xray_shell_versions.json
    git commit -m "Auto Update" -a
    
    # 输出详细的更新信息到Annotations
    echo -e "::notice title=Auto Update::[${check_time}] 更新完成\n\n更新的组件：\n${updated_components}"
else
    # 输出详细的无需更新信息到Annotations
    echo -e "::notice title=Auto Update::[${check_time}] 无需更新版本\n\n所有组件版本已为最新状态"
    exit 0
fi
