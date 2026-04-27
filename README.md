# ss-multiip-installer

单独仓库版：优先使用系统源快速安装 `shadowsocks-libev + simple-obfs`，你手动输入端口/密码/加密/插件参数；如果系统源不可用，可回退到原来的 `1660667086/123` 安装脚本。安装完成后，再自动按服务器多 IP 生成同端口节点。

默认配置：

```text
端口: 80
密码: 1
加密: aes-256-gcm
插件: obfs-server
插件参数: obfs=http
```

## 一键安装

仓库创建后，把命令里的仓库名替换成真实仓库名：

```bash
cd /root
rm -rf /root/ss-multiip-installer
rm -f install-ss-multiip.sh
curl -fL -o install-ss-multiip.sh https://raw.githubusercontent.com/1660667086/ss-multiip-installer/master/install-ss-multiip.sh
chmod +x install-ss-multiip.sh
sudo ./install-ss-multiip.sh
```

如果仓库默认分支是 `main`，把 URL 里的 `master` 改成 `main`。

## 自定义参数

```bash
sudo PORT=443 PASSWORD='your-password' METHOD='aes-256-gcm' ./install-ss-multiip.sh
```

强制使用原安装脚本：

```bash
sudo FORCE_UPSTREAM=1 ./install-ss-multiip.sh
```

## 后续新增 IP

安装完成后会生成命令：

```bash
ss-multiip
```

服务器新增或删除 IP 后，重新运行：

```bash
sudo ss-multiip
```

脚本会自动：

```text
检测本机 IPv4 网卡地址
检测每个网卡对应的公网出口 IP
生成 /etc/shadowsocks/config-ipN.json
生成 /etc/systemd/system/ss-ipN.service
停掉旧 ss-ip*.service
停掉原 shadowsocks-libev.service，避免占用 0.0.0.0:端口
启动新的多 IP 服务并设置开机自启
```

## 说明

这个仓库不修改 `1660667086/123`。默认优先走系统源快速安装，避免源码编译拖慢小机器；如果选择不用快速安装，脚本会拉取并运行原安装脚本。已有 `/etc/shadowsocks/config.json` 时，脚本只改监听端口和绑定方式，保留原密码、加密方式和插件参数。

脚本会预先设置非交互安装环境，并预配置 `iptables-persistent`，减少安装时卡在保存防火墙规则、`needrestart` 或未完成 `dpkg` 配置阶段的概率。
