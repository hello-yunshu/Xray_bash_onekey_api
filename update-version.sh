#!/bin/bash

online_version_file="./xray_shell_versions.json"
tested_versions_file="./tested_versions.json"

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

# 前置校验：两个 tested 文件必须一致且 JSON 合法。
# 自动更新绝不能“修复” tested 漂移，漂移时直接 fail closed。
if ! bash validate-json.sh >/dev/null 2>&1; then
    echo "ERROR: validate-json.sh 失败 — tested 元数据不一致或 JSON 非法。" >&2
    echo "ERROR: 拒绝执行自动更新，请人工解决 tested 漂移后再运行。" >&2
    exit 1
fi

# 获取在线版本
declare -A online_versions

# Shell is Release-owned. This scheduled updater must not discover or publish
# shell versions from a mutable branch; Release Xray updates the paired fields.
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
# Start from the current file so auto-update ONLY touches online fields and
# update_date. tested_version / *_tested_at / *_tested_note and any other
# existing metadata are preserved (auto-flow must never modify tested).
new_json="$current_versions"

# 添加更新日期
new_json=$(echo "$new_json" | jq --arg date "$(date '+%Y-%m-%d %H:%M')" '. * {"update_date": $date}')

# 检查每个组件的版本
for key in "${!tested_versions[@]}"; do
    [[ "$key" == "shell" || "$key" == "xray" ]] && continue
    current_value=$(echo "$current_versions" | jq -r ".${key}_online_version")
    new_value=${online_versions[$key]}

    # 自动更新只能修改 *_online_version / update_date / shell_upgrade_details。
    # *_tested_version / *_tested_at / *_tested_note / tested_versions.json
    # 由人工 promotion 维护，自动流程绝不写入。
    new_json=$(echo "$new_json" | jq --arg key "$key" --arg value "$new_value" '. * {"\($key)_online_version": $value}')

    # 检查是否需要更新
    if [[ ${current_value} != ${new_value} || $force_regen == true ]]; then
        update_required=true
        :
    fi
done

# 记录更新检查时间
check_time=$(date '+%Y-%m-%d %H:%M:%S')

# 收集更新信息
if $update_required; then
    # 记录需要更新的组件
    updated_components=""
    for key in "${!tested_versions[@]}"; do
        [[ "$key" == "shell" || "$key" == "xray" ]] && continue
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
