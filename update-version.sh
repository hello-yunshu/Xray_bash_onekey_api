online_version_file="./xray_shell_versions.json"

xray_tested_version="1.8.13"
nginx_tested_version="1.26.1"
openssl_tested_version="3.3.1"
jemalloc_tested_version="5.3.0"

shell_online_version=$(curl -L -s https://raw.githubusercontent.com/hello-yunshu/Xray_bash_onekey/main/install.sh | grep "shell_version=" | head -1 | awk -F '=|"' '{print $3}')
xray_online_version=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r .tag_name | head -1 | sed 's/v//g')
xray_online_pre_version=$(curl -s "https://api.github.com/repos/XTLS/Xray-core/releases?per_page=1" | jq -r .[].tag_name | head -1 | sed 's/v//g')
nginx_online_version=$(curl -s https://api.github.com/repos/nginx/nginx/tags | jq -r .[].name | sed 's/release-//g' | grep "1\.[0-9][02468]\.*" | head -1)
#openssl_online_version=$(curl -s https://www.openssl.org/news/newslog.html | awk -F " " '/OpenSSL 1.1.1/{print $4}' | head -1)
openssl_online_version=$(curl -s https://api.github.com/repos/openssl/openssl/tags | jq -r .[].name | grep "3\.[0-9]\.[0-9]" | grep -v "3\.[0-9]\.[0-9]-" | awk -F '-' '{print $2}' | head -1)
jemalloc_online_version=$(curl -s https://api.github.com/repos/jemalloc/jemalloc/releases/latest | jq -r .tag_name | head -1)

if [[ ${shell_online_version} != '' ]] && [[ ${xray_online_version} != '' ]] && [[ ${nginx_online_version} != '' ]] && [[ ${openssl_online_version} != '' ]] && [[ ${jemalloc_online_version} != '' ]]; then
    if [[ $(jq -r .shell_online_version ${online_version_file}) != ${shell_online_version} ]] || [[ $(jq -r .xray_online_version ${online_version_file}) != ${xray_online_version} ]] || [[ $(jq -r .nginx_online_version ${online_version_file}) != ${nginx_online_version} ]] || [[ $(jq -r .openssl_online_version ${online_version_file}) != ${openssl_online_version} ]] || [[ $(jq -r .jemalloc_online_version ${online_version_file}) != ${jemalloc_online_version} ]]; then
        update_date=$(date '+%Y-%m-%d %H:%M')
        update_version=$(jq -r ".update_date = \"${update_date}\"|.shell_online_version = \"${shell_online_version}\"|.xray_tested_version = \"${xray_tested_version}\"|.nginx_tested_version = \"${nginx_tested_version}\"|.openssl_tested_version = \"${openssl_tested_version}\"|.jemalloc_tested_version = \"${jemalloc_tested_version}\"|.xray_online_version = \"${xray_online_version}\"|.xray_online_pre_version = \"${xray_online_pre_version}\"|.nginx_online_version = \"${nginx_online_version}\"|.openssl_online_version = \"${openssl_online_version}\"|.jemalloc_online_version = \"${jemalloc_online_version}\"" ${online_version_file})
        echo "${update_version}" | jq . >${online_version_file}
        git config --global user.name "github-actions[bot]  "
        git config --global user.email "41898282+github-actions[bot]@users.noreply.github.com"
        git add ./xray_shell_versions.json
        git commit -m "Auto Update" -a
        echo -e "更新版本完成"
    else
        echo -e "无需更新版本"
        exit 1
    fi
else
    echo -e "无法更新版本"
    exit 1
fi