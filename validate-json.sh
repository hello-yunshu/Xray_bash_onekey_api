#!/bin/bash

tested_versions_file="./tested_versions.json"
online_version_file="./xray_shell_versions.json"

# 检查文件是否存在
if [[ ! -f "$online_version_file" ]]; then
    echo "Error: $online_version_file does not exist"
    exit 1
fi

# 读取 tested_versions 文件
declare -A tested_versions
if [[ -f "$tested_versions_file" ]]; then
    while IFS='=' read -r key value; do
        if [[ -n "$key" && -n "$value" ]]; then
            tested_versions["$key"]=$value
        fi
    done < <(jq -r 'to_entries[] | "\(.key)=\(.value)"' "$tested_versions_file" 2>/dev/null)
else
    echo "Warning: $tested_versions_file does not exist, proceeding with basic validation"
fi

# 读取当前版本文件内容
current_versions=$(cat "$online_version_file")

# 验证JSON格式是否有效
if ! echo "$current_versions" | jq empty 2>/dev/null; then
    echo "Error: $online_version_file contains invalid JSON"
    exit 1
fi

# 检查整个JSON是否为空
json_size=$(echo "$current_versions" | jq 'if type == "object" then length elif type == "array" then length else 0 end')
if [[ $json_size -eq 0 ]]; then
    echo "Error: $online_version_file is empty or contains only an empty object/array"
    exit 1
fi

# 检查是否存在null值
null_count=$(echo "$current_versions" | jq 'walk(if type == "object" or type == "array" then . else . end) | .. | select(. == null) | length')
if [[ $null_count -gt 0 ]]; then
    echo "Error: $online_version_file contains $null_count null values"
    # 输出包含null值的路径以便调试
    echo "Null value paths:"
    echo "$current_versions" | jq -r 'paths(select(. == null)) | join(".")' 2>/dev/null || echo "Could not identify null paths"
    exit 1
fi

# 检查每个组件的版本（如果tested_versions文件存在）
if [[ ${#tested_versions[@]} -gt 0 ]]; then
    for key in "${!tested_versions[@]}"; do
        current_value=$(echo "$current_versions" | jq -r ".${key}_online_version")
        
        # 检查值是否为null、空或"null"字符串
        if [[ -z ${current_value} ]] || [[ ${current_value} == "null" ]]; then
            echo "Validation failed for ${key}: ${key}_online_version is missing, empty, or null"
            exit 1
        fi
        
        # 检查值是否为有效的字符串
        if [[ ${current_value} == "null" ]]; then
            echo "Validation failed for ${key}: ${key}_online_version is null"
            exit 1
        fi
    done
fi

# 检查 shell_upgrade_details 是否存在且有值
shell_upgrade_details=$(echo "$current_versions" | jq -r ".shell_upgrade_details")
if [[ -z ${shell_upgrade_details} ]] || [[ ${shell_upgrade_details} == "null" ]]; then
    echo "Validation failed: shell_upgrade_details is missing, empty, or null"
    exit 1
fi

# 额外检查：确保shell_upgrade_details本身不包含null值
shell_null_count=$(echo "$shell_upgrade_details" | jq 'if type == "object" or type == "array" then walk(if type == "object" or type == "array" then . else . end) | .. | select(. == null) | length else 0 end' 2>/dev/null)
if [[ $shell_null_count -gt 0 ]]; then
    echo "Validation failed: shell_upgrade_details contains $shell_null_count null values"
    exit 1
fi

# 检查是否有任何值为"undefined"字符串
undefined_count=$(echo "$current_versions" | jq 'walk(if type == "string" and . == "undefined" then empty else . end) | if type == "string" and . == "undefined" then 1 else 0 end' 2>/dev/null || echo 0)
if [[ $undefined_count -gt 0 ]]; then
    # 更精确地检查是否有"undefined"字符串值
    undefined_check=$(echo "$current_versions" | jq 'paths(select(type == "string" and . == "undefined")) | length' 2>/dev/null || echo 0)
    if [[ $undefined_check -gt 0 ]]; then
        echo "Validation failed: $online_version_file contains \"undefined\" values"
        exit 1
    fi
fi

echo "JSON validation successful."
exit 0
