# Ubuntu 系统初始化脚本

专为Ubuntu系统设计的自动化初始化配置脚本，提供国内优化配置和Docker环境部署。

## 主要功能

1. **系统配置**
   - 交互式时区设置（支持IP自动检测）
   - APT镜像源选择（USTC/清华/阿里云）
   - 系统更新升级
   - 禁用休眠模式

2. **包管理优化**
   - 完全移除Snap及其相关组件
   - 配置国内APT镜像源
   - 阻止Snap自动安装

3. **Docker环境部署**
   - 交互式安装确认
   - 双镜像源支持 (USTC/Aliyun)
   - 自动清理旧版本组件
   - 安装后验证（服务状态/版本/测试容器）

4. **错误处理机制**
   - 错误日志记录 (error.log)
   - 网络错误自动重试
   - Docker安装失败自动回退
   - 关键配置自动备份

## 系统要求

- Ubuntu 20.04 LTS 或更高版本
- Root权限
- 网络连接
- 1GB 可用磁盘空间
- 内核版本 5.10+

## 使用说明

1. 下载脚本：
   ```bash
   wget https://raw.githubusercontent.com/gtzjh/myserver/main/init.sh
   ```

2. 添加执行权限：
   ```bash
   chmod +x init.sh
   ```

3. 以root权限运行：
   ```bash
   sudo ./init.sh
   ```

## 交互配置项

脚本运行时会提示：
1. 时区配置选项（保持当前/自动检测/手动选择）
2. APT镜像源选择（USTC/清华/阿里云/保持默认）
3. 确认是否移除Snap
4. 是否安装Docker运行时

## 安全特性

- GPG签名验证所有镜像源
- Docker安装使用HTTPS加密
- 自动清理临时密钥文件
- 敏感操作前创建系统快照

## 错误处理

- 网络安装失败自动重试3次
- APT源更新失败自动回滚
- Docker服务异常时输出日志
- 关键步骤失败中止后续流程

## 注意事项

1. **Docker相关**
   - 安装后需手动注销重新登录才能使用非root权限
   - 测试容器需要访问docker.io
   - 阿里云镜像需要公网访问权限

2. **系统限制**
   - 仅适用于Ubuntu系统
   - WSL环境自动跳过硬件时钟同步
   - 低内存设备可能无法运行测试容器

## 更新日志

### 2024-03-25
- 新增Docker自动化安装功能
- 支持双镜像源故障转移
- 添加容器运行时验证
- 优化错误日志输出格式

### 2024-03-20
- 增加WSL环境检测
- 优化APT镜像源验证流程