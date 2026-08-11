# IDC User Bulk Creation

在 AWS IAM Identity Center 中批量创建用户并将其添加到指定 Group 的脚本。

## 前置条件

1. 已安装 [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
2. 已配置 AWS CLI 凭证（具有 `identitystore` 和 `sso-admin` 权限）
3. 已启用 IAM Identity Center
4. macOS 或 Linux 环境

## 快速开始

```bash
# 1. 克隆仓库
git clone https://github.com/kakaspire/IDCUserBulkCreation.git
cd IDCUserBulkCreation

# 2. 赋予执行权限
chmod +x create_idc_user.sh

# 3. 创建单个用户并加入指定 Group
./create_idc_user.sh -e john.doe@example.com -g QuickReaderPro-Professional

# 4. 指定姓名
./create_idc_user.sh -e jane.smith@example.com -g QuickReaderPro-Professional -f Jane -l Smith
```

## 参数说明

| 参数 | 必填 | 说明 |
|------|------|------|
| `-e` | 是 | 用户邮箱（同时作为用户名） |
| `-g` | 是 | IAM Identity Center 中的 Group 名称 |
| `-f` | 否 | 名（默认从邮箱前缀提取） |
| `-l` | 否 | 姓（默认从邮箱前缀提取或设为 "User"） |
| `-h` | 否 | 显示帮助信息 |

## 批量创建示例

如果需要批量创建多个用户，可以结合循环使用：

```bash
# 从文件批量创建（文件格式：每行一个 "邮箱,组名"）
while IFS=',' read -r email group; do
    ./create_idc_user.sh -e "$email" -g "$group"
done < users.csv
```

`users.csv` 示例：

```
alice@example.com,QuickReaderPro-Professional
bob@example.com,QuickReaderPro-Professional
charlie@example.com,QuickReaderPro-Professional
```

## 脚本执行流程

1. 获取 IAM Identity Center 实例信息（Identity Store ID）
2. 检查用户是否已存在，避免重复创建
3. 创建用户（用户名 = 邮箱地址）
4. 查找指定的 Group，如不存在则列出所有可用 Group
5. 将用户添加到 Group
6. 自动打开 IAM Identity Center 控制台，引导管理员发送密码重置邮件

## 用户首次登录

脚本完成后，管理员需要在 IAM Identity Center 控制台为用户发送密码设置邮件：

1. 在已打开的控制台页面中找到新创建的用户
2. 点击用户名进入详情页
3. 点击 **Reset password**
4. 选择 **Send an email to the user with instructions to reset the password**
5. 用户收到邮件后设置密码，即可通过 AWS access portal 登录
