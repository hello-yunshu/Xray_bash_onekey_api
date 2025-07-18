#!/bin/bash

tested_versions_file="./tested_versions.json"
online_version_file="./xray_shell_versions.json"

# 读取 tested_versions 文件
declare -A tested_versions
while IFS='=' read -r key value; do
    tested_versions["$key"]=$value
done < <(jq -r 'to_entries[] | "\(.key)=\(.value)"' "$tested_versions_file")

# 加载现有版本文件
current_versions=$(cat ${online_version_file})

# 检查每个组件的版本
for key in "${!tested_versions[@]}"; do
    current_value=$(echo "$current_versions" | jq -r ".${key}_online_version")
    
    if [[ -z ${current_value} ]]; then
        echo "Validation failed for ${key}: ${key}_online_version is missing or empty"
        exit 1
    fi
done

# 检查 shell_upgrade_details 是否存在且有值
shell_upgrade_details=$(echo "$current_versions" | jq -r ".shell_upgrade_details")
if [[ -z ${shell_upgrade_details} ]]; then
    echo "Validation failed: shell_upgrade_details is missing or empty"
    exit 1
fi

echo "JSON validation successful."
exit 0