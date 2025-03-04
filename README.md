# Ubuntu 系统初始化脚本

专为Ubuntu系统设计的自动化初始化配置脚本，提供国内优化配置。

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

3. **错误处理机制**
   - 错误日志记录 (error.log)
   - 网络错误自动重试
   - 操作步骤失败汇总
   - 关键配置自动备份

## 系统要求

- Ubuntu 18.04 或更高版本
- Root权限
- 网络连接

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

## 安全特性

- 关键操作前自动备份配置文件
- 移除潜在不安全的Snap服务
- 使用HTTPS镜像源
- 严格校验时区输入

## 错误处理

- 所有错误记录到脚本同目录的error.log
- 网络操作失败自动重试3次
- 失败步骤会显示最终汇总
- APT源更新失败自动回滚

## 注意事项

1. **数据备份**
   - 脚本会自动备份原始APT源配置
   - 建议在执行前备份重要数据

2. **系统限制**
   - 仅适用于Ubuntu系统
   - WSL环境会自动跳过硬件时钟同步
   - 选择镜像源后会自动验证可用性

3. **Snap移除**
   - 会彻底删除所有Snap软件包
   - 自动阻止apt安装snapd
   - 需要用户明确确认才会执行

4. **网络依赖**
   - 时区检测需要访问ip-api.com
   - 镜像源配置需要网络连通性

## 更新日志

### 2024-03-20
- 增加WSL环境检测
- 优化APT镜像源验证流程
- 添加硬件时钟同步错误处理
- 改进时区选择交互界面