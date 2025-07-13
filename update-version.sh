#!/bin/bash

online_version_file="./xray_shell_versions.json"

# 定义测试版本
declare -A tested_versions=(
    ["shell"]="2.5.9"
    ["xray"]="25.6.8"
    ["nginx"]="1.28.0"
    ["openssl"]="3.5.1"
    ["jemalloc"]="5.3.0"
    ["nginx_build"]="2025.07.01"
)

# 获取在线版本
declare -A online_versions

online_versions["shell"]=$(curl -L -s https://raw.githubusercontent.com/hello-yunshu/Xray_bash_onekey/main/install.sh | grep "shell_version=" | head -1 | awk -F '=|"' '{print $3}')
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
    if [[ ${current_value} != ${new_value} ]]; then
        update_required=true
        if [[ $key == "shell" ]]; then
            shell_upgrade_details=$(curl -s https://api.github.com/repos/hello-yunshu/Xray_bash_onekey/commits | jq '.[] | select(.author.login == "hello-yunshu") | .commit.message' -r | head -n 1)
            # 使用 jq 对 shell_upgrade_details 进行转义
            shell_upgrade_details=$(echo "$shell_upgrade_details" | jq -Rsa @json | tr -d '"')
            new_json=$(echo "$new_json" | jq --arg details "$shell_upgrade_details" '. * {"shell_upgrade_details": $details}')
        fi
    else
        if [[ $key == "shell" ]]; then
            existing_upgrade_details=$(echo "$current_versions" | jq -r ".shell_upgrade_details")
            new_json=$(echo "$new_json" | jq --arg details "$existing_upgrade_details" '. * {"shell_upgrade_details": $details}')
        fi
    fi
done

# 如果需要更新，则执行更新操作
if $update_required; then
    echo "$new_json" >${online_version_file}
    
    git config --global user.name "github-actions[bot]"
    git config --global user.email "41898282+github-actions[bot]@users.noreply.github.com"
    git add ./xray_shell_versions.json
    git commit -m "Auto Update" -a
    
    echo -e "更新版本完成"
else
    echo -e "无需更新版本"
    exit 3
fi