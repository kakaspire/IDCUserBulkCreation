#!/bin/zsh
#
# create_idc_user.sh
# 在 AWS IAM Identity Center 中创建用户并将其添加到指定 Group
#
# 用法:
#   ./create_idc_user.sh -e <邮箱> -g <组名称> [-f <名>] [-l <姓>]
#
# 参数:
#   -e  用户邮箱（同时作为用户名）
#   -g  IAM Identity Center 中的 Group 名称
#   -f  名（可选，默认从邮箱前缀提取）
#   -l  姓（可选，默认设为 "User"）
#   -h  显示帮助信息
#
# 前置条件:
#   1. 已安装并配置 AWS CLI v2
#   2. 已启用 IAM Identity Center
#   3. 当前 CLI 凭证具有 identitystore 相关权限
#

set -euo pipefail

# ========== 颜色输出 ==========
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

info()  { echo "${GREEN}[INFO]${NC} $1"; }
warn()  { echo "${YELLOW}[WARN]${NC} $1"; }
error() { echo "${RED}[ERROR]${NC} $1" >&2; }

# ========== 帮助信息 ==========
SCRIPT_NAME="${0:t}"

usage() {
    cat <<EOF
用法: $SCRIPT_NAME -e <邮箱> -g <组名称> [-f <名>] [-l <姓>]

参数:
  -e  用户邮箱（同时作为用户名）
  -g  IAM Identity Center 中的 Group 名称
  -f  名（可选，默认从邮箱前缀提取）
  -l  姓（可选，默认设为 "User"）
  -h  显示帮助信息

示例:
  $SCRIPT_NAME -e john.doe@example.com -g Admins
  $SCRIPT_NAME -e jane@example.com -g Developers -f Jane -l Smith
EOF
    exit 0
}

# ========== 参数解析 ==========
EMAIL=""
GROUP_NAME=""
FIRST_NAME=""
LAST_NAME=""

while getopts "e:g:f:l:h" opt; do
    case $opt in
        e) EMAIL="$OPTARG" ;;
        g) GROUP_NAME="$OPTARG" ;;
        f) FIRST_NAME="$OPTARG" ;;
        l) LAST_NAME="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

# ========== 参数校验 ==========
if [[ -z "$EMAIL" ]]; then
    error "必须指定用户邮箱 (-e)"
    usage
fi

if [[ -z "$GROUP_NAME" ]]; then
    error "必须指定 Group 名称 (-g)"
    usage
fi

# 验证邮箱格式
if [[ ! "$EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    error "邮箱格式无效: $EMAIL"
    exit 1
fi

# 从邮箱提取默认姓名
if [[ -z "$FIRST_NAME" ]]; then
    FIRST_NAME=$(echo "$EMAIL" | cut -d'@' -f1 | cut -d'.' -f1)
    FIRST_NAME="$(echo "${FIRST_NAME:0:1}" | tr '[:lower:]' '[:upper:]')${FIRST_NAME:1}"
fi

if [[ -z "$LAST_NAME" ]]; then
    local_part=$(echo "$EMAIL" | cut -d'@' -f1)
    if [[ "$local_part" == *"."* ]]; then
        LAST_NAME=$(echo "$local_part" | cut -d'.' -f2)
        LAST_NAME="$(echo "${LAST_NAME:0:1}" | tr '[:lower:]' '[:upper:]')${LAST_NAME:1}"
    else
        LAST_NAME="User"
    fi
fi

IDC_USERNAME="$EMAIL"
DISPLAY_NAME="$FIRST_NAME $LAST_NAME"

# ========== 检查 AWS CLI ==========
if ! command -v aws &> /dev/null; then
    error "未找到 AWS CLI，请先安装: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    exit 1
fi

info "开始创建 IAM Identity Center 用户..."
info "用户名: $IDC_USERNAME"
info "邮箱: $EMAIL"
info "显示名称: $DISPLAY_NAME"
info "目标组: $GROUP_NAME"

# ========== 获取 Identity Store ID ==========
info "获取 IAM Identity Center 实例信息..."

SSO_INSTANCE=$(aws sso-admin list-instances --output json 2>/dev/null)

if [[ -z "$SSO_INSTANCE" ]] || [[ $(echo "$SSO_INSTANCE" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('Instances',[])))" 2>/dev/null) -eq 0 ]]; then
    error "未找到 IAM Identity Center 实例，请确认已启用 IAM Identity Center"
    exit 1
fi

IDENTITY_STORE_ID=$(echo "$SSO_INSTANCE" | python3 -c "import sys,json; print(json.load(sys.stdin)['Instances'][0]['IdentityStoreId'])")

info "Identity Store ID: $IDENTITY_STORE_ID"

# ========== 检查用户是否已存在 ==========
info "检查用户是否已存在..."

EXISTING_USER=$(aws identitystore list-users \
    --identity-store-id "$IDENTITY_STORE_ID" \
    --filters "AttributePath=UserName,AttributeValue=$IDC_USERNAME" \
    --output json 2>/dev/null)

EXISTING_USER_COUNT=$(echo "$EXISTING_USER" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('Users',[])))" 2>/dev/null)

if [[ "$EXISTING_USER_COUNT" -gt 0 ]]; then
    USER_ID=$(echo "$EXISTING_USER" | python3 -c "import sys,json; print(json.load(sys.stdin)['Users'][0]['UserId'])")
    warn "用户 $IDC_USERNAME 已存在 (UserId: $USER_ID)，跳过创建步骤"
else
    # ========== 创建用户 ==========
    info "正在创建用户..."

    CREATE_RESULT=$(aws identitystore create-user \
        --identity-store-id "$IDENTITY_STORE_ID" \
        --user-name "$IDC_USERNAME" \
        --name "{\"GivenName\":\"$FIRST_NAME\",\"FamilyName\":\"$LAST_NAME\"}" \
        --display-name "$DISPLAY_NAME" \
        --emails "[{\"Value\":\"$EMAIL\",\"Type\":\"work\",\"Primary\":true}]" \
        --output json 2>&1)

    if [[ $? -ne 0 ]]; then
        error "创建用户失败: $CREATE_RESULT"
        exit 1
    fi

    USER_ID=$(echo "$CREATE_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['UserId'])")
    info "用户创建成功! UserId: $USER_ID"
fi

# ========== 查找 Group ==========
info "查找 Group: $GROUP_NAME ..."

GROUP_RESULT=$(aws identitystore list-groups \
    --identity-store-id "$IDENTITY_STORE_ID" \
    --filters "AttributePath=DisplayName,AttributeValue=$GROUP_NAME" \
    --output json 2>/dev/null)

GROUP_COUNT=$(echo "$GROUP_RESULT" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('Groups',[])))" 2>/dev/null)

if [[ "$GROUP_COUNT" -eq 0 ]]; then
    error "未找到名为 '$GROUP_NAME' 的 Group。请检查组名是否正确。"
    info "列出可用的 Groups..."
    ALL_GROUPS=$(aws identitystore list-groups \
        --identity-store-id "$IDENTITY_STORE_ID" \
        --output json 2>/dev/null)
    echo "$ALL_GROUPS" | python3 -c "
import sys, json
data = json.load(sys.stdin)
groups = data.get('Groups', [])
if groups:
    print('  可用的 Groups:')
    for g in groups:
        print(f\"  - {g['DisplayName']}\")
else:
    print('  (未找到任何 Group)')
" 2>/dev/null
    exit 1
fi

GROUP_ID=$(echo "$GROUP_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['Groups'][0]['GroupId'])")
info "找到 Group: $GROUP_NAME (GroupId: $GROUP_ID)"

# ========== 检查用户是否已在 Group 中 ==========
info "检查用户是否已在 Group '$GROUP_NAME' 中..."

MEMBERSHIP_CHECK=$(aws identitystore is-member-in-groups \
    --identity-store-id "$IDENTITY_STORE_ID" \
    --member-id "UserId=$USER_ID" \
    --group-ids "$GROUP_ID" \
    --output json 2>/dev/null)

IS_MEMBER=$(echo "$MEMBERSHIP_CHECK" | python3 -c "
import sys, json
data = json.load(sys.stdin)
results = data.get('Results', [])
if results and results[0].get('MembershipExists', False):
    print('true')
else:
    print('false')
" 2>/dev/null)

if [[ "$IS_MEMBER" == "true" ]]; then
    warn "用户 '$IDC_USERNAME' 已经是 Group '$GROUP_NAME' 的成员，无需重复添加"
else
    # ========== 将用户添加到 Group ==========
    info "正在将用户添加到 Group '$GROUP_NAME'..."

    ADD_RESULT=$(aws identitystore create-group-membership \
        --identity-store-id "$IDENTITY_STORE_ID" \
        --group-id "$GROUP_ID" \
        --member-id "UserId=$USER_ID" \
        --output json 2>&1)

    if [[ $? -ne 0 ]]; then
        if echo "$ADD_RESULT" | grep -q "ConflictException"; then
            warn "用户已是该 Group 成员"
        else
            error "添加用户到 Group 失败: $ADD_RESULT"
            exit 1
        fi
    else
        MEMBERSHIP_ID=$(echo "$ADD_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('MembershipId',''))" 2>/dev/null)
        info "用户已成功添加到 Group! MembershipId: $MEMBERSHIP_ID"
    fi
fi

# ========== 获取 AWS Access Portal URL ==========
START_URL=$(echo "$SSO_INSTANCE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
inst = data['Instances'][0]
# 尝试获取 StartUrl (v2) 或 IdentityStoreId 构造 URL
url = inst.get('StartUrl', '')
if not url:
    iid = inst.get('InstanceId', '') or inst.get('IdentityStoreId', '')
    if iid:
        url = f'https://{iid}.awsapps.com/start'
print(url)
" 2>/dev/null)

# ========== 发送密码重置邮件 ==========
# AWS 不提供 CLI/API 直接发送验证邮件
# 通过控制台为用户执行 Reset password -> Send email
info "正在打开 IAM Identity Center 控制台以发送密码重置邮件..."

SSO_REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")
CONSOLE_URL="https://${SSO_REGION}.console.aws.amazon.com/singlesignon/home?region=${SSO_REGION}#!/instances/users"

# macOS 下自动打开浏览器
if command -v open &> /dev/null; then
    open "$CONSOLE_URL"
fi

# ========== 完成 ==========
echo ""
info "=========================================="
info "操作完成!"
info "=========================================="
echo ""
echo "  用户名:       $IDC_USERNAME"
echo "  邮箱:         $EMAIL"
echo "  显示名称:     $DISPLAY_NAME"
echo "  所属组:       $GROUP_NAME"
echo "  User ID:      $USER_ID"
echo "  Group ID:     $GROUP_ID"
if [[ -n "$START_URL" ]]; then
echo "  登录地址:     $START_URL"
fi
echo ""
info "下一步操作（在已打开的控制台页面中）:"
info "  1. 找到用户 '$IDC_USERNAME' 并点击进入"
info "  2. 点击 'Reset password'"
info "  3. 选择 'Send an email to the user with instructions to reset the password'"
info "  4. 点击 'Reset password' 确认"
echo ""
info "用户将收到密码设置邮件，完成后可通过以下地址登录:"
if [[ -n "$START_URL" ]]; then
info "  $START_URL"
else
info "  (请在 IAM Identity Center Settings 中查看 AWS access portal URL)"
fi
echo ""
